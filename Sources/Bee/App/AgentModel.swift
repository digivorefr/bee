import AppKit
import BeeCore
import Foundation
import Observation

/// The application's side of the MCP relay: listens on Bee's private socket, checks who is there, asks
/// the person before anything that matters, and carries the tools out. Agents never get a secret value.
@Observable
final class AgentModel {
    /// A question an agent's call raises, put to the person in Bee itself: the agent cannot answer it.
    struct Question: Identifiable {
        enum Answer { case deny, once, untilQuit }

        let id = UUID()
        var title: String
        var detail: String
        /// What is about to be sent that the person did not write, in full: the changes of a fork.
        var content: String?
        /// Offers "Allow until Bee quits" beside "Allow".
        var offersUntilQuit: Bool
        /// Who asks, and on which connection: a program that leaves takes its question with it.
        fileprivate let program: String
        fileprivate let connection: UUID
        /// `nil` when the person did not answer: the call was given up, or nobody was there.
        fileprivate let answer: (Answer?) -> Void
    }

    struct Activity: Identifiable {
        let id = UUID()
        let date = Date()
        var program: String
        var tool: String
        var outcome: String
    }

    /// A request a program may send without being asked again, with one environment: agreeing to a send
    /// with one says nothing of another. The environment is left out where it does not count (a response
    /// that was given).
    private struct Approval: Hashable {
        var program: String
        var request: UUID
        var environment: UUID?
    }

    private(set) var question: Question? {
        didSet { if question?.id != oldValue?.id { questionShownAt = Date() } }
    }
    private(set) var activity: [Activity] = []
    private(set) var isListening = false

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var listener: Int32 = -1
    @ObservationIgnored private var waiting: [Question] = []
    /// What the person allowed to be sent until Bee quits, each with the request as it was when they agreed:
    /// a request that changed since is asked about again.
    @ObservationIgnored private var sendsAllowed: [Approval: String] = [:]
    /// The response a program was last given for a request, by when it came: it reads it again without a
    /// question (the rest of a long body), and any other response is asked about.
    @ObservationIgnored private var responsesGiven: [Approval: Date] = [:]
    /// When each program last proposed: a proposal saves the workspace, and is not made in a loop.
    @ObservationIgnored private var proposals: [String: [Date]] = [:]
    /// Programs allowed for this run only: nothing tells them from another started the same way.
    @ObservationIgnored private var allowedUntilQuit: Set<String> = []
    /// Programs the person turned away: they are not asked about again until agents are turned off and on.
    @ObservationIgnored private var deniedPrograms: Set<String> = []
    /// Connections whose program left before the answer.
    @ObservationIgnored private var withdrawn: Set<UUID> = []
    @ObservationIgnored private var questionShownAt = Date()

    private static let questionsPerProgram = 3
    private static let questionsInAll = 6
    /// A question takes no answer before it has been on screen this long: a click meant for the question
    /// it replaced does not answer it.
    private static let questionSettling: TimeInterval = 0.8
    private static let questionLifetime: Duration = .seconds(600)
    private static let forksPerRequest = 10
    private static let proposalsPerMinute = 20
    private static let addressLimit = 2000
    private static let headerLimit = 4000
    private static let proposalLimit = 1024 * 1024

    /// The relay shipped in this copy of Bee: the only program the socket answers.
    static var relayPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bee-mcp").resolvingSymlinksInPath().path
    }

    private var socketPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BEE_AGENT_SOCKET"], !override.isEmpty { return override }
        #endif
        guard let model else { return "" }
        return LocalSocket.path(inDataDirectory: model.environment.dataDirectory)
    }

    // MARK: Listening

    /// Starts or stops listening as the settings say.
    func settingsChanged() {
        guard let model, model.isLoaded else { return }
        if model.settings.agentsEnabled, !isListening {
            let descriptor = LocalSocket.listen(at: socketPath) ?? -1
            guard descriptor >= 0 else {
                model.reportProblem("Bee could not open its connection for agents. Turn Settings › Agents off and on again.")
                return
            }
            listener = descriptor
            isListening = true
            let relay = Self.relayPath
            let owner = OwnerBox(self)
            Thread.detachNewThread {
                while let connection = LocalSocket.accept(on: descriptor) {
                    Thread.detachNewThread { Self.serve(connection, relay: relay, owner: owner) }
                }
            }
        } else if !model.settings.agentsEnabled, isListening {
            close(listener)
            unlink(socketPath)
            listener = -1
            isListening = false
            // Turned off, nothing an agent asked stays: neither a question nor what was allowed.
            let pending = (question.map { [$0] } ?? []) + waiting
            question = nil
            waiting = []
            pending.forEach { $0.answer(nil) }
            sendsAllowed = [:]
            responsesGiven = [:]
            allowedUntilQuit = []
            deniedPrograms = []
        }
        // What a program was allowed goes with it when it is removed.
        sendsAllowed = sendsAllowed.filter { isPaired($0.key.program) }
        responsesGiven = responsesGiven.filter { isPaired($0.key.program) }
    }

    /// One connection of the relay: who it is, then one call and its answer per line.
    private nonisolated static func serve(_ connection: Int32, relay: String, owner: OwnerBox) {
        defer { close(connection) }
        // Only this user, and only the relay that came with this copy of Bee.
        guard let peer = LocalSocket.peer(of: connection), peer.user == getuid(), let program = peer.program,
              URL(fileURLWithPath: program).resolvingSymlinksInPath().path == relay
        else { return }
        // The program that started the relay is the one the person is asked about.
        let host = host(of: peer.process)
        let token = UUID()

        while let line = LocalSocket.readLine(from: connection) {
            guard let call = try? JSONDecoder().decode(AgentCall.self, from: Data(line.utf8)) else { return }
            let box = ReplyBox()
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.reply = await owner.model?.answer(call, program: host, connection: token)
                    ?? AgentReply(id: call.id, text: "Bee is quitting.", isError: true)
                done.signal()
            }
            while done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                guard LocalSocket.isClosed(connection) else { continue }
                // The program gave up: its question leaves the screen and nothing is sent for it.
                Task { @MainActor in owner.model?.withdraw(token) }
                done.wait()
                return
            }
            guard let reply = box.reply, let data = try? JSONEncoder().encode(reply),
                  LocalSocket.writeLine(String(decoding: data, as: UTF8.self), to: connection) else { return }
        }
    }

    /// The program that started the relay. `nil` when the system does not say, or when the relay was left
    /// behind by a program that is gone: Bee then answers nothing rather than guess.
    private nonisolated static func host(of relay: pid_t) -> AgentProgram? {
        guard let parent = LocalSocket.parent(of: relay), parent > 1 else { return nil }
        guard let path = LocalSocket.programPath(of: parent) else {
            // Its file is gone from the disk (an update replaced it while it ran): it is that one process.
            return LocalSocket.birth(of: parent).map { AgentProgram(name: $0.name, process: parent, started: $0.started) }
        }
        return AgentProgram(
            path: path, arguments: LocalSocket.arguments(of: parent) ?? [], workingDirectory: LocalSocket.workingDirectory(of: parent)
        )
    }

    /// Carries the answer from the main actor back to the connection's thread.
    private nonisolated final class ReplyBox: @unchecked Sendable {
        var reply: AgentReply?
    }

    /// Lets the connection threads reach the model without keeping it alive. Read on the main actor only.
    private nonisolated final class OwnerBox: @unchecked Sendable {
        weak var model: AgentModel?

        init(_ model: AgentModel) {
            self.model = model
        }
    }

    // MARK: Answering

    private func isPaired(_ identity: String) -> Bool {
        allowedUntilQuit.contains(identity) || model?.settings.agentPrograms.contains(identity) == true
    }

    /// A request an agent may name: one of a collection opened to agents, or a fork of one. A fork stands
    /// in the collection where its original does, so what it inherits and where it leads read the same way.
    private struct Found {
        var item: RequestItem
        var collection: Collection
        /// The fork and its original, when the request is a fork.
        var fork: RequestFork?
        var original: RequestItem?
    }

    /// The request or the fork of this identifier, as it is now.
    private func openRequest(_ id: UUID?) -> Found? {
        guard let model, let id else { return nil }
        let open = Set(model.settings.agentCollections)
        let fork = model.workspace.fork(id: id)
        let place = fork?.originID ?? id
        // A fork belongs to one request: an identifier repeated in a collection opened to agents does not
        // open the forks of the request it repeats.
        guard fork == nil || model.holdsOnce(place) else { return nil }
        for collection in model.workspace.collections where open.contains(collection.id) {
            guard let original = collection.request(id: place) else { continue }
            guard let fork else { return Found(item: original, collection: collection) }
            return collection.placing(fork.item, at: place).map { Found(item: fork.item, collection: $0, fork: fork, original: original) }
        }
        return nil
    }

    /// The variables a fork takes a value from and its original does not, and those among them that are
    /// secret in any environment: a secret is the person's to place in a request.
    private func addedVariables(in item: RequestItem, since original: RequestItem, collection: Collection) -> (all: [String], secret: [String]) {
        guard let model else { return ([], []) }
        // A value may hold `{{names}}` itself: what counts is every variable the request ends up reading.
        let scopes = model.workspace.environments.flatMap(\.variables) + collection.variables + model.workspace.globals
        let before = AgentReader.variables(reachedFrom: AgentReader.variables(in: original), among: scopes)
        let added = AgentReader.variables(reachedFrom: AgentReader.variables(in: item), among: scopes).subtracting(before).sorted()
        let secret = Set(scopes.filter(\.isSecret).map(\.name))
        return (added, added.filter(secret.contains))
    }

    private static func named(_ variables: [String]) -> String {
        (variables.count == 1 ? "the variable " : "the variables ")
            + variables.map { "{{\(AgentReader.oneLine($0, limit: 80))}}" }.joined(separator: ", ")
    }

    /// A name someone else may have written (a request of an imported file, a fork an agent named), as it
    /// stands inside a sentence of Bee's.
    private static func quoted(_ name: String) -> String {
        "“\(AgentReader.oneLine(name, limit: 120))”"
    }

    /// The values of every variable a request of this collection may read, in any environment: what Bee
    /// itself says of a failure or a test can spell one, and is masked.
    private func variableValues(for collection: Collection) -> Redactor {
        guard let model else { return Redactor(secrets: []) }
        let variables = model.workspace.environments.flatMap(\.variables) + collection.variables + model.workspace.globals
        return Redactor(secrets: variables.map(\.value))
    }

    /// The names under which the authorization of a request, of its folders and of its collection puts a
    /// credential on the wire: a header or a parameter of that name is the person's to set.
    private static func credentialNames(of found: Found) -> (headers: Set<String>, parameters: Set<String>) {
        var headers: Set<String> = ["authorization", "proxy-authorization", "cookie"]
        var parameters: Set<String> = []
        let folders = found.collection.ancestry(of: found.item.id) ?? []
        for auth in [found.item.auth, found.collection.auth] + folders.map(\.auth) where auth.kind == .apiKey {
            let name = auth.apiKeyName.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            if auth.apiKeyLocation == .query { parameters.insert(name) } else { headers.insert(name) }
        }
        return (headers, parameters)
    }

    private func answer(_ call: AgentCall, program: AgentProgram?, connection: UUID) async -> AgentReply {
        defer { withdrawn.remove(connection) }
        // What a program calls itself, and its path, are shown to the person: each stays one line.
        let call = AgentCall(id: call.id, tool: call.tool, arguments: call.arguments, client: AgentReader.oneLine(call.client, limit: 80))
        let name = AgentReader.oneLine(program.map { AgentProgram.shortName(of: $0.identity) } ?? "An unknown program", limit: 120)
        func refuse(_ text: String) -> AgentReply {
            log(name, call.tool, "Refused")
            return AgentReply(id: call.id, text: text, isError: true)
        }
        let turnedOff = "Agents are not allowed in Bee (Settings › Agents)."
        guard let model, model.settings.agentsEnabled else { return refuse(turnedOff) }
        guard let tool = AgentTool(rawValue: call.tool) else { return refuse("Bee has no such tool.") }
        guard let program else { return refuse("Bee could not tell which program started the relay, so it answers nothing.") }
        let identity = program.identity

        // A program the person has not met yet is introduced first.
        let isKnown = program.canBeRemembered ? isPaired(identity) : allowedUntilQuit.contains(identity)
        if !isKnown {
            let turnedAway = "The person did not allow this program to use Bee."
            guard !deniedPrograms.contains(identity) else { return refuse(turnedAway) }
            let lasting = if program.canBeRemembered {
                ""
            } else if program.hasNoFile {
                " Its file is no longer on the disk, so Bee cannot tell where it came from: an update does that to a program that is running, and a program can do it on purpose. Allow it only if you started it yourself. This lasts until it quits or Bee quits."
            } else {
                " Bee cannot tell it from another program started the same way, so this lasts until Bee quits."
            }
            let allowed = await ask(
                title: "Let this program use Bee?",
                detail: "\(AgentReader.oneLine(identity))\nIt calls itself “\(call.client)”. It will be able to \(Self.describe(model.settings.agentAccess)) in the collections you opened to agents. Secret values are never given to it.\(lasting)",
                content: nil, offersUntilQuit: false, program: identity, connection: connection
            )
            guard model.settings.agentsEnabled else { return refuse(turnedOff) }
            guard let allowed else { return refuse("Bee could not ask the person about this program. Try again later.") }
            guard allowed != .deny else {
                deniedPrograms.insert(identity)
                return refuse(turnedAway)
            }
            if program.canBeRemembered {
                if !model.settings.agentPrograms.contains(identity) { model.settings.agentPrograms.append(identity) }
            } else {
                allowedUntilQuit.insert(identity)
            }
        }
        guard tool.access <= model.settings.agentAccess else {
            return refuse("The person has not allowed agents to do this in Bee (Settings › Agents).")
        }

        let open = Set(model.settings.agentCollections)
        let collections = model.workspace.collections.filter { open.contains($0.id) }
        func argument(_ name: String) -> UUID? { call.arguments[name]?.string.flatMap(UUID.init(uuidString:)) }
        let unknownRequest = "No request has this identifier in the collections opened to agents. Use list_requests."

        switch tool {
        case .listCollections:
            log(name, call.tool, "Answered")
            return AgentReply(id: call.id, text: AgentReader.text(AgentReader.collections(collections)))
        case .listRequests:
            guard let collection = collections.first(where: { $0.id == argument("collection_id") }) else {
                return refuse("No collection has this identifier among those opened to agents. Use list_collections.")
            }
            log(name, call.tool, collection.name)
            return AgentReply(id: call.id, text: AgentReader.text(AgentReader.requests(of: collection, forks: model.workspace.forks.filter { model.holdsOnce($0.originID) })))
        case .getRequest:
            guard let found = openRequest(argument("request_id")) else { return refuse(unknownRequest) }
            log(name, call.tool, found.fork?.name ?? found.item.name)
            let described = if let fork = found.fork, let original = found.original {
                AgentReader.fork(fork, of: original)
            } else {
                AgentReader.request(found.item)
            }
            return AgentReply(id: call.id, text: AgentReader.text(described))
        case .listEnvironments:
            log(name, call.tool, "Answered")
            return AgentReply(id: call.id, text: AgentReader.text(AgentReader.environments(model.workspace)))
        case .sendRequest:
            guard let id = argument("request_id"), openRequest(id) != nil else { return refuse(unknownRequest) }
            guard !model.isVaultLocked else { return refuse("Secrets are locked in Bee: the person has to unlock them first.") }
            // The environment an agent names is used for this send only: it knows it by its name, never
            // by what it holds, and the one the person works with stays as it is.
            var named: UUID?
            if let text = call.arguments["environment"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let matches = model.workspace.environments.filter {
                    $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame || $0.name == text
                }
                guard matches.count == 1 else {
                    return refuse(
                        matches.isEmpty
                            ? "No environment has this name or identifier. Use list_environments."
                            : "Several environments are named “\(text)”: name it by its identifier, from list_environments."
                    )
                }
                named = matches[0].id
            }
            return await send(id, in: named, call: call, program: identity, name: name, connection: connection)
        case .getResponse:
            guard let id = argument("request_id"), openRequest(id) != nil else { return refuse(unknownRequest) }
            guard !model.isVaultLocked else { return refuse("Secrets are locked in Bee: the person has to unlock them first.") }
            return await response(of: id, call: call, program: identity, name: name, connection: connection)
        case .proposeChange:
            guard let found = openRequest(argument("request_id")) else { return refuse(unknownRequest) }
            guard !model.isVaultLocked else { return refuse("Secrets are locked in Bee: the person has to unlock them first.") }
            return propose(on: found, call: call, program: name, identity: identity)
        }
    }

    private static func describe(_ access: AgentAccess) -> String {
        switch access {
        case .read: "read your requests"
        case .run: "read your requests and, each time you agree, send one or read the last response it got"
        case .propose: "read your requests, propose changes as forks and, each time you agree, send a request or a fork or read the last response it got"
        }
    }

    // MARK: Sending

    /// What the person agrees to when they allow a request to be sent: the request and what it inherits, as
    /// written and with its secrets, the environment it is sent with, and where its address leads now.
    /// `environmentID` is the one it is sent with: `nil` for none. `nil` comes back when that environment
    /// is gone.
    private func fingerprint(_ found: Found, with environmentID: UUID?) -> String? {
        guard let model, let request = AgentReader.fingerprint(of: found.item.id, in: found.collection),
              environmentID == nil || model.workspace.environments.contains(where: { $0.id == environmentID })
        else { return nil }
        return [request, environmentID?.uuidString ?? "no environment", destination(of: found, with: environmentID).sent]
            .joined(separator: "|")
    }

    /// Where the address of a request leads with the variables as they are now: as it is sent, and as it
    /// may be shown (a secret in it is masked).
    private func destination(of found: Found, with environmentID: UUID?) -> (sent: String, shown: String) {
        guard let model else { return ("", "") }
        let context = model.variableContext(collectionID: found.collection.id, environmentID: environmentID)
        let rendered = TemplateEngine.render(found.item.url, in: context)
        return (AgentReader.origin(of: rendered.text), AgentReader.origin(of: rendered.shown))
    }

    /// What a request carries besides its address, in a few words.
    private static func load(of found: Found) -> String {
        let item = found.item
        var parts: [String] = []
        let headers = item.headers.count { $0.isEnabled && !$0.key.isEmpty }
        if headers > 0 { parts.append(headers == 1 ? "1 header" : "\(headers) headers") }
        if item.body.mode != .none { parts.append("a body") }
        let folders = found.collection.ancestry(of: item.id) ?? []
        let scripts = [item.preRequestScript, item.postResponseScript, found.collection.preRequestScript, found.collection.postResponseScript]
            + folders.flatMap { [$0.preRequestScript, $0.postResponseScript] }
        var text = parts.isEmpty ? "" : " It carries \(parts.joined(separator: " and "))."
        if scripts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            text += " Scripts run with it: they can send other requests and read variables."
        }
        return text
    }

    /// `named` is the environment the agent asked for; without one, the request is sent with the one Bee is
    /// on when it leaves.
    private func send(_ id: UUID, in named: UUID?, call: AgentCall, program: String, name: String, connection: UUID) async -> AgentReply {
        func refuse(_ text: String, _ outcome: String = "Refused") -> AgentReply {
            log(name, call.tool, outcome)
            return AgentReply(id: call.id, text: text, isError: true)
        }
        guard let model else { return refuse("Bee is quitting.") }
        func sentWith() -> UUID? { named ?? model.workspace.activeEnvironmentID }
        guard let found = openRequest(id), let shown = fingerprint(found, with: sentWith()) else {
            return refuse("The request, or the environment, is gone.")
        }
        // What an agent wrote does not carry a secret its original does not carry: asked of every send,
        // since a variable may have become secret since the fork was proposed.
        var added: [String] = []
        if let fork = found.fork, let original = found.original, fork.proposedBy != nil {
            let variables = addedVariables(in: found.item, since: original, collection: found.collection)
            guard variables.secret.isEmpty else {
                return refuse("This fork uses \(Self.named(variables.secret)), secret and not used by its original: only the person can send it.")
            }
            added = variables.all
        }
        let approval = Approval(program: program, request: id, environment: sentWith())
        if sendsAllowed[approval] != shown {
            // Allowed before, and no longer the same: said, since the question may look the same.
            let changed = sendsAllowed[approval] != nil
                ? " It is not what you allowed until Bee quits: the request, a script, a secret, the environment or where it leads changed."
                : ""
            sendsAllowed[approval] = nil
            let with = sentWith()
            var environment = model.workspace.environments.first { $0.id == with }.map { "the environment \(Self.quoted($0.name))" } ?? "no environment"
            if named != nil, with != model.workspace.activeEnvironmentID {
                // Not the one on screen: said, since the person would otherwise read the one they see.
                let active = model.workspace.activeEnvironment.map { Self.quoted($0.name) } ?? "none"
                environment += ", which the agent chose and is not the one Bee is on (\(active)),"
            }
            let leads = AgentReader.oneLine(destination(of: found, with: with).shown, limit: 300)
            // A fork is not what the person knows under that name: what it changes is shown in full.
            var title = "Send \(Self.quoted(found.item.name))?"
            var forked = ""
            var content: String?
            if let fork = found.fork, let original = found.original {
                title = "Send the fork \(Self.quoted(fork.name))?"
                let changes = AgentReader.changes(of: fork, from: original)
                forked = "It is a fork of \(Self.quoted(original.name)), \(fork.proposedBy == nil ? "which you made" : "proposed by an agent"). "
                    + (changes.isEmpty ? "It changes nothing of it. " : "What it changes is below. ")
                    + (added.isEmpty ? "" : "It takes a value from \(Self.named(added)), which \(Self.quoted(original.name)) does not use. ")
                // A hundred long headers would not be read: what is shown is said to be a part.
                let limit = 60000
                content = changes.isEmpty ? nil : changes.count <= limit ? changes
                    : "Too long to show whole: the first \(limit) of \(changes.count) characters. Read the fork before you allow it.\n" + changes.prefix(limit)
            }
            let allowed = await ask(
                title: title,
                detail: "\(AgentReader.oneLine("\(found.item.method.rawValue) \(URLTemplate.join(base: found.item.url, params: found.item.queryParams))"))\n\(forked)It goes to \(leads.isEmpty ? "an address Bee cannot read" : leads), with \(environment) and its secrets.\(Self.load(of: found))\(changed) Asked by \(name), which calls itself “\(call.client)”; the response goes back to it with secrets masked.",
                content: content, offersUntilQuit: true, program: program, connection: connection
            )
            guard let allowed, !withdrawn.contains(connection) else {
                return refuse("Bee could not ask the person: the call was given up, or too many questions are waiting.")
            }
            if allowed == .deny { return refuse("The person did not allow this request to be sent.", "Denied: \(found.fork?.name ?? found.item.name)") }
            // The answer was given to what the question showed: if anything changed while it was on screen
            // (the request, its folders, the environment, what agents may do), nothing is sent on it.
            guard model.settings.agentsEnabled, AgentTool.sendRequest.access <= model.settings.agentAccess, isPaired(program),
                  let current = openRequest(id), fingerprint(current, with: sentWith()) == shown
            else {
                return refuse("The request, or what agents may do, changed while Bee was asking the person. Ask again.")
            }
            if allowed == .untilQuit { sendsAllowed[approval] = shown }
        }
        guard !model.isVaultLocked else { return refuse("Secrets are locked in Bee: the person has to unlock them first.") }
        // What is sent is the request the person agreed to and no other: an identifier held twice (a file
        // that repeats the one of a request elsewhere, of a fork) would send something else under its name.
        guard let current = openRequest(id), fingerprint(current, with: sentWith()) == shown, model.holdsOnce(id),
              let session = model.session(for: id), session.collectionID == current.collection.id, session.item == current.item
        else {
            sendsAllowed[approval] = nil
            return refuse("Bee cannot tell this request from another one any more. Use list_requests, then ask again.")
        }
        guard !session.isSending else { return refuse("This request is already being sent. Try again when it is done.") }
        // What this send brings back and no other: the person may send the same request right after, or
        // reveal what its response hides.
        let sent = await withCheckedContinuation { (continuation: CheckedContinuation<AppModel.Sent, Never>) in
            model.send(session, with: sentWith()) { continuation.resume(returning: $0) }
        }
        log(name, call.tool, "Sent: \(found.fork?.name ?? found.item.name)")
        // What it was given, it may read again: the rest of a long body.
        responsesGiven[Approval(program: program, request: id)] = sent.receivedAt
        // What Bee itself says of a failure or a test can spell the value of a variable (an address that
        // cannot be reached, a comparison): it is masked there. What the server sent is the server's.
        let values = variableValues(for: current.collection)
        let text = await Task.detached { Self.report(sent, hiding: values) }.value
        return AgentReply(id: call.id, text: text)
    }

    /// What a send brought back, with secrets masked and a long body cut. From an `offset` in the body,
    /// only what follows it. `received` says when, for a response read again.
    private nonisolated static func report(_ sent: AppModel.Sent, hiding values: Redactor, from offset: Int = 0, received: String? = nil) -> String {
        let outcome = sent.outcome
        if let response = sent.masked, offset > 0 {
            return (["Status: \(response.statusCode) \(response.statusText)"] + AgentReader.body(response.body, from: offset)).joined(separator: "\n")
        }
        var lines = ["Sent with \(sent.environmentName.map { "the environment “\($0)”" } ?? "no environment")."]
        if let received { lines.append("Received at \(received); nothing was sent again.") }
        if let response = sent.masked {
            lines.append("Status: \(response.statusCode) \(response.statusText)")
            lines.append("Time: \(Int((response.duration * 1000).rounded())) ms")
            lines.append("Headers:")
            lines += response.headers.map { "  \($0.name): \($0.value)" }
            lines += AgentReader.body(response.body)
        } else {
            lines.append("No response: \(values.redact(outcome.errorMessage ?? "the request failed")).")
        }
        if !outcome.tests.isEmpty {
            lines.append("Tests:")
            lines += outcome.tests.map { test in
                "  \(test.passed ? "passed" : "failed"): \(test.name)\(test.message.map { " (\(values.redact($0)))" } ?? "")"
            }
        }
        if !outcome.unresolvedVariables.isEmpty {
            lines.append("Variables without a value: \(outcome.unresolvedVariables.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Reading a response

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The last response Bee got for a request, for a program that asks without sending again. One it was
    /// given already (it sent the request itself, or the person agreed) is read again without a question,
    /// to go on in a long body; any other is the person's to give.
    private func response(of id: UUID, call: AgentCall, program: String, name: String, connection: UUID) async -> AgentReply {
        func refuse(_ text: String, _ outcome: String = "Refused") -> AgentReply {
            log(name, call.tool, outcome)
            return AgentReply(id: call.id, text: text, isError: true)
        }
        var offset = 0
        if case .number(let value)? = call.arguments["offset"], value.isFinite, value > 0 { offset = Int(min(value, 1e12)) }
        // An identifier held twice would give the response of another request under this name.
        guard let model, let found = openRequest(id), model.holdsOnce(id),
              let session = model.session(for: id), session.collectionID == found.collection.id
        else { return refuse("The request is gone.") }
        guard !session.isSending else { return refuse("This request is being sent. Try again when it is done.") }
        guard let outcome = session.outcome, let received = session.receivedAt else {
            return refuse("Bee has no response for this request since it started. Send it with send_request.")
        }
        let title = found.fork?.name ?? found.item.name
        let approval = Approval(program: program, request: id)
        if responsesGiven[approval] != received {
            let status = outcome.response.map { "\($0.statusCode) \($0.statusText), \($0.body.count) bytes" } ?? "no response, the request failed"
            let allowed = await ask(
                title: "Give the response of \(Self.quoted(title)) to this program?",
                detail: "\(AgentReader.oneLine("\(found.item.method.rawValue) \(URLTemplate.join(base: found.item.url, params: found.item.queryParams)) → \(status)"))\nIt is the last response Bee got for this request, at \(Self.clock.string(from: received)), and this program has not seen it. Nothing is sent again. Asked by \(name), which calls itself “\(call.client)”; it gets the response with secrets masked.",
                content: nil, offersUntilQuit: false, program: program, connection: connection
            )
            guard let allowed, !withdrawn.contains(connection) else {
                return refuse("Bee could not ask the person: the call was given up, or too many questions are waiting.")
            }
            if allowed == .deny { return refuse("The person did not allow this response to be read.", "Denied: \(title)") }
            // The answer was given to the response the question told of: another one that came meanwhile
            // is not it.
            guard model.settings.agentsEnabled, AgentTool.getResponse.access <= model.settings.agentAccess, isPaired(program),
                  openRequest(id) != nil, model.holdsOnce(id), model.session(for: id) === session, session.receivedAt == received
            else {
                return refuse("Another response came, or what agents may do changed, while Bee was asking the person. Ask again.")
            }
            responsesGiven[approval] = received
        }
        guard !model.isVaultLocked else { return refuse("Secrets are locked in Bee: the person has to unlock them first.") }
        log(name, call.tool, "Read: \(title)")
        // As the run masked it, never as the person may have revealed it since; and again with the secrets
        // as they are now: one added since the response came is one too.
        let current = Redactor(secrets: model.workspace.secretValues())
        let values = variableValues(for: found.collection)
        let environmentName = session.sentEnvironmentName
        let clock = Self.clock.string(from: received)
        let text = await Task.detached {
            let masked = AppModel.masking(AppModel.masking(outcome.response, with: outcome.redactor), with: current)
            let sent = AppModel.Sent(outcome: outcome, masked: masked, receivedAt: received, environmentName: environmentName)
            return Self.report(sent, hiding: values, from: offset, received: clock)
        }.value
        return AgentReply(id: call.id, text: text)
    }

    // MARK: Proposing

    /// A proposal is a fork: nothing in the collection changes until the person merges it. On a fork an
    /// agent suggested, it revises that fork; on the person's own, it starts another one from it.
    private func propose(on found: Found, call: AgentCall, program: String, identity: String) -> AgentReply {
        func refuse(_ text: String) -> AgentReply {
            log(program, call.tool, "Refused")
            return AgentReply(id: call.id, text: text, isError: true)
        }
        guard let model else { return refuse("Bee is quitting.") }
        let now = Date()
        let recent = (proposals[identity] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < Self.proposalsPerMinute else { return refuse("Too many proposals in a minute. Wait before proposing again.") }
        proposals[identity] = recent + [now]
        let original = found.original ?? found.item
        let revised = found.fork.flatMap { $0.proposedBy == nil ? nil : $0 }
        // Forks are the person's to review one by one: an agent does not pile them up.
        guard revised != nil || model.workspace.forks(of: original.id).count < Self.forksPerRequest else {
            return refuse("This request already has \(Self.forksPerRequest) forks. Revise one you proposed (propose_change with its identifier), or the person has to merge or discard some first.")
        }
        let headers = call.arguments["headers"]?.object ?? [:]
        let removed = (call.arguments["remove_headers"]?.array ?? []).compactMap(\.string)
        let size = (call.arguments["url"]?.string?.utf8.count ?? 0) + (call.arguments["body"]?.string?.utf8.count ?? 0)
            + headers.reduce(0) { $0 + $1.key.utf8.count + ($1.value.string?.utf8.count ?? 0) }
        guard size <= Self.proposalLimit, headers.count <= 100, removed.count <= 100 else { return refuse("The proposal is too large for Bee.") }
        // The person reads an address and a header on one line when asked to send them: neither holds a
        // line break or a character that hides, and neither is longer than can be read.
        func plain(_ text: String?, upTo limit: Int) -> Bool {
            guard let text else { return true }
            return text.count <= limit && AgentReader.oneLine(text, limit: limit) == text
        }
        guard plain(call.arguments["url"]?.string, upTo: Self.addressLimit), plain(call.arguments["method"]?.string, upTo: 20),
              headers.allSatisfy({ plain($0.key, upTo: 200) && plain($0.value.string, upTo: Self.headerLimit) })
        else {
            return refuse("An address, a method and a header hold no line break, no tab and no hidden character, and stay short: \(Self.addressLimit) characters for an address, \(Self.headerLimit) for a header.")
        }
        let credentials = Self.credentialNames(of: found)

        var changed = found.item
        if let method = call.arguments["method"]?.string {
            guard let known = HTTPMethod(rawValue: method.uppercased()) else { return refuse("Bee does not send the method \(method).") }
            changed.method = known
        }
        if let url = call.arguments["url"]?.string {
            let parts = URLTemplate.split(url)
            changed.url = parts.base
            changed.queryParams = URLTemplate.merge(parsed: parts.params, into: found.item.queryParams)
            changed.pathVariables = PathVariables.storedRows(for: parts.base, from: found.item.pathVariables)
            for row in changed.queryParams where !found.item.queryParams.contains(where: { $0.id == row.id && $0.key == row.key && $0.value == row.value }) {
                // A parameter that holds a secret is the person's: an agent writes it as it is listed, or
                // leaves it out. So is the one the authorization sets.
                guard !row.isSecret else {
                    return refuse("The parameter \(row.key) holds a secret: only the person can change it. Write it as it is listed, or leave it out.")
                }
                guard !credentials.parameters.contains(row.key.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    return refuse("The parameter \(row.key) is the one the authorization sets: only the person can set it.")
                }
            }
        }
        // A request carries the person's secrets to its host: where it is sent is theirs to change, in
        // the proposal as in a fork of theirs it starts from.
        guard AgentReader.origin(of: changed.url) == AgentReader.origin(of: original.url) else {
            return refuse("Only the person can change where a request is sent (its scheme, host and port). Propose the rest.")
        }
        if let body = call.arguments["body"]?.string {
            changed.body.mode = .raw
            changed.body.raw = body
        }
        for (name, value) in headers {
            guard let text = value.string else { continue }
            // The header the authorization writes, or a cookie: a header of that name would take its place.
            guard !credentials.headers.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) else {
                return refuse("The header \(name) carries the authorization: only the person can set it.")
            }
            if let index = changed.headers.firstIndex(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                // A header that holds a secret is the person's to change.
                guard !changed.headers[index].isSecret else {
                    return refuse("The header \(name) holds a secret: only the person can change it.")
                }
                changed.headers[index].value = text
                changed.headers[index].isEnabled = true
            } else {
                changed.headers.append(KeyValue(key: name, value: text))
            }
        }
        // Turned off, not deleted: a merge then says so, and the value stays where the person put it.
        for name in removed {
            for index in changed.headers.indices where changed.headers[index].key.caseInsensitiveCompare(name) == .orderedSame {
                changed.headers[index].isEnabled = false
            }
        }
        // A secret is the person's to place: a proposal does not point a request at one it does not use.
        let secret = addedVariables(in: changed, since: original, collection: found.collection).secret
        guard secret.isEmpty else {
            return refuse("This request does not use \(Self.named(secret)), which is secret: only the person can put a secret in a request.")
        }
        let label = (call.arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "\(call.client): \(label.isEmpty ? "proposal" : AgentReader.oneLine(String(label.prefix(60)), limit: 60))"
        let next = "Send it with send_request and this identifier to see what it returns: the person is asked in Bee and sees what it changes. "
            + "Revise it with propose_change and this identifier. Nothing changed in the collection: the person merges the fork, or discards it."
        if let revised {
            guard model.reviseFork(revised.id, named: title, changed: changed, by: call.client) else {
                return refuse("This fork cannot be revised now: the person edited it, or it is being sent. Propose on “\(original.name)”.")
            }
            log(program, call.tool, "Revised on \(original.name)")
            model.inform("\(program) revised the fork it proposed on “\(original.name)”.")
            return AgentReply(id: call.id, text: "Revised the fork \(revised.id.uuidString) of “\(original.name)”. \(next)")
        }
        guard let id = model.proposeFork(of: original.id, named: title, changed: changed, by: call.client) else {
            return refuse("The proposal could not be made.")
        }
        log(program, call.tool, "Proposed on \(original.name)")
        model.inform("\(program) proposed a change to “\(original.name)”. It is a fork under that request.")
        return AgentReply(id: call.id, text: "Proposed as the fork \(id.uuidString) of “\(original.name)”. \(next)")
    }

    // MARK: Questions

    /// Puts a question to the person. `nil` when they did not answer it: the program gave up, too many of
    /// its questions are waiting already, or nobody answered for a long time.
    private func ask(
        title: String, detail: String, content: String?, offersUntilQuit: Bool, program: String, connection: UUID
    ) async -> Question.Answer? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BEE_AGENT_AUTOALLOW"] == "1" { return .once }
        #endif
        let pending = (question.map { [$0] } ?? []) + waiting
        guard !withdrawn.contains(connection), pending.count < Self.questionsInAll,
              pending.count(where: { $0.program == program }) < Self.questionsPerProgram else { return nil }
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { continuation in
            let asked = Question(
                title: title, detail: detail, content: content, offersUntilQuit: offersUntilQuit, program: program, connection: connection
            ) {
                continuation.resume(returning: $0)
            }
            if question == nil { question = asked } else { waiting.append(asked) }
            Task { [weak self] in
                try? await Task.sleep(for: Self.questionLifetime)
                self?.settle(asked.id, with: nil)
            }
        }
    }

    /// The person's answer to the question they were shown; the next one, if any, takes its place. An
    /// answer to a question that is no longer on screen, or that has only just come up, is not one.
    func resolve(_ id: UUID, _ answer: Question.Answer) {
        guard let current = question, current.id == id, Date().timeIntervalSince(questionShownAt) >= Self.questionSettling else { return }
        settle(id, with: answer)
    }

    /// Ends a question, on screen or waiting, with an answer or without one.
    private func settle(_ id: UUID, with answer: Question.Answer?) {
        if let current = question, current.id == id {
            question = waiting.isEmpty ? nil : waiting.removeFirst()
            current.answer(answer)
        } else if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).answer(answer)
        }
    }

    /// A program left before its call was answered: its questions go, unanswered.
    private func withdraw(_ connection: UUID) {
        withdrawn.insert(connection)
        let left = ((question.map { [$0] } ?? []) + waiting).filter { $0.connection == connection }
        left.forEach { settle($0.id, with: nil) }
    }

    private func log(_ program: String, _ tool: String, _ outcome: String) {
        activity.insert(Activity(program: program, tool: AgentReader.oneLine(tool, limit: 40), outcome: AgentReader.oneLine(outcome, limit: 160)), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
