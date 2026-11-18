import Foundation

/// The program that started the relay, as the person is asked about it and as Bee remembers it.
///
/// A program is its path. An interpreter (node, python, a shell) runs anything, so its path says nothing:
/// what tells one program from another is then the script it was started with.
public struct AgentProgram: Equatable, Sendable {
    /// What the person is shown, and what is kept once they allow it.
    public var identity: String
    /// False when nothing tells this program from another one started the same way (a script given on the
    /// command line, options or a subcommand before the script, a helper that runs the code of others):
    /// allowing it then lasts until Bee quits.
    public var canBeRemembered: Bool
    /// True when the file the program was started from is gone from the disk.
    public var hasNoFile = false

    /// A program whose file is no longer on the disk, as when an update replaces a program that is running:
    /// the system cannot say where it came from. It is then this one process and no other, told by its
    /// number and the moment it started, and allowing it lasts as long as it runs at most.
    public init(name: String, process: Int32, started: Date) {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // With the offset from UTC: the hour that comes twice a year is then two different hours.
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        // The name is a file name, which may hold anything but a slash: it stays on one line.
        let shown = String(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        identity = "\(shown) (process \(process), started \(stamp.string(from: started)))"
        canBeRemembered = false
        hasNoFile = true
    }

    static let interpreters: Set<String> = [
        "node", "nodejs", "deno", "bun", "tsx", "npx", "python", "pythonw", "uv", "uvx", "ruby", "perl", "php", "lua",
        "java", "osascript", "pwsh", "env", "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
    ]

    /// - Parameter isFile: whether a path is a file, asked of the disk unless a test says otherwise.
    public init(
        path: String, arguments: [String], workingDirectory: String?, isFile: (String) -> Bool = AgentProgram.isFile
    ) {
        let name = Self.stem(path)
        // The helpers of an application built on a browser run the code of every extension it has.
        guard !name.contains("helper"), name != "electron" else {
            identity = path
            canBeRemembered = false
            return
        }
        guard Self.interpreters.contains(name) else {
            identity = path
            canBeRemembered = true
            return
        }
        // The script is the first argument, right after the interpreter's own name: anything else (an
        // option, a subcommand, arguments that do not start with the interpreter) tells nothing sure.
        guard arguments.count >= 2, Self.stem(arguments[0]) == name, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else {
            identity = path
            canBeRemembered = false
            return
        }
        var script = arguments[1]
        if !script.hasPrefix("/"), let workingDirectory {
            script = URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(script).standardizedFileURL.path
        }
        identity = "\(path) \(script)"
        canBeRemembered = script.hasPrefix("/") && isFile(script)
    }

    /// The last name of a path, lowercased and without its version: `python3.13` is `python`.
    private static func stem(_ path: String) -> String {
        String((path as NSString).lastPathComponent.lowercased().drop { $0 == "-" }.prefix { !$0.isNumber })
    }

    public static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// A few words for a list: the last name of each part.
    public static func shortName(of identity: String) -> String {
        identity.split(separator: " /").enumerated()
            .map { index, part in ((index == 0 ? String(part) : "/" + part) as NSString).lastPathComponent }
            .joined(separator: " ")
    }
}
