import Foundation

/// The folder where each collection has its file (see `CollectionFile`), kept in step with what Bee holds.
///
/// Bee writes a collection's file when the collection changes, and takes in a file that changed or
/// appeared. It never deletes a collection because its file is gone (the file is written again): a
/// collection is deleted in Bee, and its file then goes to the Trash.
///
/// Bee keeps each file as it last wrote or read it. That is what tells a change made in the file from a
/// change made in Bee that has not reached the file yet: only the first is taken in.
public actor CollectionFolder {
    /// A file that changed: what it says now, and what it said when Bee last wrote or read it.
    public struct Incoming: Sendable {
        public var file: Collection
        public var base: Collection?
    }

    public struct Reading: Sendable {
        /// The files that changed or appeared.
        public var incoming: [Incoming]
        /// The collections given to the reading with what the folder says merged in.
        public var collections: [Collection]
        /// True when `collections` differs from what was given.
        public var changed: Bool
        public var warnings: [String]
        /// True when a collection lost its file to another one and needs a file written.
        public var needsWriting: Bool

        /// What the folder says merged into the collections as they are now, which may no longer be the
        /// ones given to the reading: a change made meanwhile stays, unless the file changed the same part.
        public func applied(to collections: [Collection]) -> [Collection] {
            var result = collections
            for change in incoming {
                if let index = result.firstIndex(where: { $0.id == change.file.id }) {
                    result[index] = CollectionFile.merge(file: change.file, base: change.base, into: result[index])
                } else {
                    result.append(change.file)
                }
            }
            return result
        }
    }

    public nonisolated let folder: URL
    private let stateFile: URL
    /// Where Bee keeps each file as it last wrote or read it, outside the folder.
    private let knownDirectory: URL
    /// False in tests and throwaway runs, where the file of a deleted collection is simply removed.
    private let usesTrash: Bool
    /// The file of each collection, by name in the folder.
    private var names: [UUID: String] = [:]
    /// What Bee last wrote to or read from each file: a file that differs was changed by someone else, and
    /// this is what tells their changes from the ones made in Bee since.
    private var known: [String: Data] = [:]
    /// The files that cannot be read, as they were when Bee said so.
    private var unreadable: [String: Data] = [:]
    /// The files Bee read but could not put in its own form (a folder it cannot write), as they were then.
    /// Kept in memory only: such a file may still hold what its author wrote in it, secrets included.
    private var readAsIs: [String: Data] = [:]
    /// The collections whose file was named by a person: Bee keeps the name they gave it.
    private var keepsName: Set<UUID> = []
    /// The collections Bee has held since it started. Only their files are cleared when they are deleted: a
    /// file whose collection has not come in yet is not the file of a deleted collection.
    private var confirmed: Set<UUID> = []
    private var namesChanged = false

    /// - Parameter stateFile: where Bee remembers which file belongs to which collection, outside the folder.
    public init(folder: URL, stateFile: URL, usesTrash: Bool = true) {
        self.folder = folder
        self.stateFile = stateFile
        self.knownDirectory = stateFile.deletingPathExtension().appendingPathExtension("known")
        self.usesTrash = usesTrash
        // What Bee knows is about one folder: in another one the same names are other files.
        if let data = try? Data(contentsOf: stateFile),
           let stored = try? JSONDecoder().decode([String: String].self, from: data),
           stored[Self.folderKey] == folder.standardizedFileURL.path {
            for (key, name) in stored {
                if let id = UUID(uuidString: key) {
                    names[id] = name
                } else if key.hasPrefix(Self.keepsNamePrefix), let id = UUID(uuidString: String(key.dropFirst(Self.keepsNamePrefix.count))) {
                    keepsName.insert(id)
                }
            }
        }
        for name in Set(names.values) {
            known[name] = try? Data(contentsOf: knownDirectory.appendingPathComponent(name))
        }
        // Copies of files Bee no longer follows, or of another folder, say nothing any more.
        for stale in (try? FileManager.default.contentsOfDirectory(atPath: knownDirectory.path)) ?? [] where known[stale] == nil {
            try? FileManager.default.removeItem(at: knownDirectory.appendingPathComponent(stale))
        }
    }

    // MARK: Reading

    /// Takes in every file that changed since Bee last wrote or read it. A file Bee does not know adds a
    /// collection. A file is put in Bee's own form right away (identifiers added, secret values taken out),
    /// so the next reading finds the same requests.
    ///
    /// - Parameter reserved: identifiers held outside the collections (forks, one-off requests): a file
    ///   cannot give one of them to a request of its own.
    public func read(into local: [Collection], reserved: Set<UUID> = []) -> Reading {
        confirmed.formUnion(local.map(\.id))
        var incoming: [Incoming] = []
        var warnings: [String] = []
        var needsWriting = false
        namesChanged = false
        // The names as the folder spells them: on a volume that ignores case, asking whether a name
        // exists says yes for a file renamed to another case.
        let listed = files()
        let present = Set(listed.map(\.lastPathComponent))
        // An identifier names one folder or request in all of Bee: a file that repeats one of another
        // collection gets a new one.
        var held: [UUID: Set<UUID>] = [:]
        for collection in local {
            var ids: Set<UUID> = []
            func collect(_ nodes: [CollectionNode]) {
                for node in nodes {
                    ids.insert(node.id)
                    collect(node.children ?? [])
                }
            }
            collect(collection.items)
            held[collection.id] = ids
        }

        for url in listed {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url), unreadable[name] != data else { continue }
            let owner = names.first(where: { $0.value == name })?.key
            // As Bee left it, and its collection is here, or was deleted here: the next writing clears it.
            if known[name] == data || readAsIs[name] == data, let owner, confirmed.contains(owner) { continue }

            let file: Collection
            let document: JSONValue
            do {
                var read = try CollectionFile.document(in: data)
                var id = CollectionFile.identifier(of: read)
                // In a file of another tool, identifiers are that tool's: requests are told by name and place.
                let foreign = PostmanReader.guessesSecrets(in: read)
                let unknown = id.map { fileID in names[fileID] == nil && !local.contains { $0.id == fileID } } ?? true
                if let owner, id != owner, foreign, unknown,
                   id == nil || local.first(where: { $0.id == owner }).map({ CollectionFile.resembles(read, $0) }) == true {
                    // Written again by another tool over a file Bee follows, without Bee's identifier or
                    // with one of its own: still that collection.
                    id = owner
                } else if let other = id.flatMap({ names[$0] }), other != name, present.contains(other) {
                    // A copy of a file Bee already follows: another collection, with identifiers of its own.
                    read = CollectionFile.withFreshIdentifiers(read)
                    id = CollectionFile.identifier(of: read)
                }
                let resolved = id ?? UUID()
                let others = held.filter { $0.key != resolved }.values.reduce(into: reserved) { $0.formUnion($1) }
                document = CollectionFile.identified(
                    read, as: resolved, like: local.first { $0.id == resolved }, adoptsUnknown: foreign, reserved: others
                )
                file = try CollectionFile.collection(in: document)
                // What this file now holds is taken for the files read after it.
                var ids: Set<UUID> = []
                func collect(_ nodes: [CollectionNode]) {
                    for node in nodes {
                        ids.insert(node.id)
                        collect(node.children ?? [])
                    }
                }
                collect(file.items)
                held[file.id, default: []].formUnion(ids)
            } catch {
                // Left as it is, and said once: the person may be in the middle of editing it. What Bee knew
                // of the file stays, to tell what changed once it can be read again.
                unreadable[name] = data
                warnings.append("“\(name)” in the collections folder cannot be read as a collection. Bee leaves it as it is.")
                continue
            }
            unreadable[name] = nil

            if let previous = names[file.id], previous != name, known[name] == nil, let moved = known[previous] {
                // Renamed by someone: what Bee knew of the file goes with it.
                forget(previous)
                remember(moved, as: name)
            }
            let base = known[name].flatMap { try? CollectionFile.read($0) }
            incoming.append(Incoming(file: file, base: base?.id == file.id ? base : nil))

            // A file holds one collection: another that had this file gets a new one at the next writing.
            for (other, held) in names where held == name && other != file.id {
                names[other] = nil
                namesChanged = true
                needsWriting = true
            }
            if names[file.id] != name {
                names[file.id] = name
                if name != Self.fileName(for: file.name) { keepsName.insert(file.id) }
                namesChanged = true
            }
            // In Bee's own form from now on. A folder that cannot be written is read all the same; what
            // Bee keeps of the file is its own form either way, never what the file held in clear.
            readAsIs[name] = nil
            if let normalized = try? CollectionFile.data(for: file, document: document) {
                if normalized != data, (try? normalized.write(to: url, options: .atomic)) == nil { readAsIs[name] = data }
                remember(normalized, as: name)
            } else {
                readAsIs[name] = data
            }
        }
        if namesChanged { persistNames() }

        var reading = Reading(incoming: incoming, collections: local, changed: false, warnings: warnings, needsWriting: needsWriting)
        reading.collections = reading.applied(to: local)
        reading.changed = reading.collections != local
        return reading
    }

    // MARK: Writing

    /// Writes the file of each collection that changed, names one for a new collection, follows a rename,
    /// and moves to the Trash the file of a collection that no longer exists. A file someone else changed
    /// since Bee last looked is left for the next reading. A file that cannot be written does not keep the
    /// others from being written: the first failure is thrown once all are done.
    public func write(_ collections: [Collection]) throws {
        confirmed.formUnion(collections.map(\.id))
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        namesChanged = false
        var failure: (any Error)?

        for collection in collections {
            do {
                try write(collection)
            } catch {
                if failure == nil { failure = error }
            }
        }

        for (id, name) in names where confirmed.contains(id) && !collections.contains(where: { $0.id == id }) {
            let url = folder.appendingPathComponent(name)
            // Only the file as Bee left it: one changed since belongs to whoever changed it.
            if let onDisk = try? Data(contentsOf: url), onDisk == known[name] {
                if usesTrash {
                    try? files.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try? files.removeItem(at: url)
                }
            }
            names[id] = nil
            keepsName.remove(id)
            forget(name)
            namesChanged = true
        }
        if namesChanged { persistNames() }
        if let failure { throw failure }
    }

    private func write(_ collection: Collection) throws {
        let files = FileManager.default
        var name = names[collection.id]
        let wanted = Self.fileName(for: collection.name)
        if let current = name, known[current] != nil, !exists(current), let moved = fileHolding(collection.id) {
            // Renamed by someone since Bee last looked: Bee follows instead of writing the old name again.
            let was = known[current]
            forget(current)
            if known[moved] == nil, let was { remember(was, as: moved) }
            keepsName.insert(collection.id)
            name = moved
        } else if let current = name, current != wanted, !keepsName.contains(collection.id),
                  !exists(wanted), !names.values.contains(wanted) {
            // The collection was renamed: its file follows, when the name is free.
            if exists(current) {
                try files.moveItem(at: folder.appendingPathComponent(current), to: folder.appendingPathComponent(wanted))
            }
            let was = known[current]
            forget(current)
            if let was { remember(was, as: wanted) }
            name = wanted
        }
        let resolved = name ?? freeName(wanted)
        if names[collection.id] != resolved {
            names[collection.id] = resolved
            namesChanged = true
        }

        let url = folder.appendingPathComponent(resolved)
        let onDisk = try? Data(contentsOf: url)
        // Changed by someone else since Bee last looked: read it first. And a file that cannot be read is
        // someone's work in progress: it is never written over.
        if let onDisk, onDisk != known[resolved] || unreadable[resolved] != nil { return }
        // A file that is gone is written again with what Bee knew of it: what Bee does not model stays in it.
        let data = try CollectionFile.data(for: collection, previous: onDisk ?? known[resolved])
        if data != onDisk { try data.write(to: url, options: .atomic) }
        remember(data, as: resolved)
    }

    // MARK: Helpers

    private func files() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// The file no collection has that names this collection, when there is one.
    private func fileHolding(_ id: UUID) -> String? {
        let taken = Set(names.values)
        return files().map(\.lastPathComponent).first { name in
            !taken.contains(name) && (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap(Self.identifier(in:)) == id
        }
    }

    private func remember(_ data: Data, as name: String) {
        guard known[name] != data else { return }
        known[name] = data
        try? FileManager.default.createDirectory(at: knownDirectory, withIntermediateDirectories: true)
        try? data.write(to: knownDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func forget(_ name: String) {
        known[name] = nil
        unreadable[name] = nil
        readAsIs[name] = nil
        try? FileManager.default.removeItem(at: knownDirectory.appendingPathComponent(name))
    }

    private func freeName(_ wanted: String) -> String {
        let stem = (wanted as NSString).deletingPathExtension
        var name = wanted
        var number = 2
        while names.values.contains(name) || exists(name) {
            name = "\(stem) \(number).json"
            number += 1
        }
        return name
    }

    private func persistNames() {
        var stored = Dictionary(uniqueKeysWithValues: names.map { ($0.key.uuidString, $0.value) })
        for id in keepsName where names[id] != nil { stored[Self.keepsNamePrefix + id.uuidString] = "1" }
        stored[Self.folderKey] = folder.standardizedFileURL.path
        guard let data = try? StorageCoding.encoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    private static let keepsNamePrefix = "keeps-name:"
    private static let folderKey = "folder"

    /// The identifier a file gives its collection, when it gives one.
    static func identifier(in data: Data) -> UUID? {
        (try? CollectionFile.document(in: data)).flatMap(CollectionFile.identifier(of:))
    }

    /// `Name.json`, without what a file name cannot hold.
    static func fileName(for name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Untitled" : String(cleaned.prefix(120))
        return stem + ".json"
    }
}
