import Foundation
import JavaScriptCore

/// A `bee.sendRequest` input that cannot become an HTTP request.
struct ScriptRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// The native functions the prelude calls through `__host`. Scalars and JSON strings cross the boundary;
/// the prelude owns the JavaScript-facing API and this side owns the data.
extension ScriptRuntime {
    func makeHostObject() -> JSValue {
        let host = JSValue(newObjectIn: context)!
        func define(_ name: String, _ function: Any) {
            host.setObject(function, forKeyedSubscript: name as NSString)
        }
        let state = self.state

        // MARK: Initial data

        let initialData: @convention(block) () -> [String: Any] = { [unowned self] in
            initialPayload()
        }
        define("init", initialData)

        // MARK: Variable scopes

        let scopeGet: @convention(block) (String, String) -> String? = { scope, name in
            ScriptRunState.Scope(rawValue: scope).flatMap { state.value(of: $0, name: name) }
        }
        define("scopeGet", scopeGet)

        let scopeHas: @convention(block) (String, String) -> Bool = { scope, name in
            ScriptRunState.Scope(rawValue: scope).flatMap { state.value(of: $0, name: name) } != nil
        }
        define("scopeHas", scopeHas)

        // `secret`: 1 forces secret, 0 forces plain, -1 leaves the choice to the heuristic.
        let scopeSet: @convention(block) (String, String, String, Int) -> Void = { scope, name, value, secret in
            guard let scope = ScriptRunState.Scope(rawValue: scope) else { return }
            state.set(scope, name: name, value: value, secret: secret < 0 ? nil : secret == 1)
        }
        define("scopeSet", scopeSet)

        let scopeUnset: @convention(block) (String, String) -> Void = { scope, name in
            if let scope = ScriptRunState.Scope(rawValue: scope) { state.unset(scope, name: name) }
        }
        define("scopeUnset", scopeUnset)

        let scopeClear: @convention(block) (String) -> Void = { scope in
            if let scope = ScriptRunState.Scope(rawValue: scope) { state.clear(scope) }
        }
        define("scopeClear", scopeClear)

        let scopeEntries: @convention(block) (String) -> [[String]] = { scope in
            ScriptRunState.Scope(rawValue: scope).map { state.entries(of: $0) } ?? []
        }
        define("scopeEntries", scopeEntries)

        // MARK: Request, tests, console

        let syncRequest: @convention(block) (String) -> Void = { json in
            if let request = Self.decodeRequest(json) { state.replaceRequest(request) }
        }
        define("syncRequest", syncRequest)

        let testBegin: @convention(block) (String) -> Int = { name in
            state.beginTest(name: name)
        }
        define("testBegin", testBegin)

        let testEnd: @convention(block) (Int, Bool, String?) -> Void = { index, passed, message in
            state.endTest(index: index, passed: passed, message: message)
        }
        define("testEnd", testEnd)

        let console: @convention(block) (String, String) -> Void = { level, message in
            state.log(level: ConsoleLevel(rawValue: level) ?? .log, message: message)
        }
        define("console", console)

        // MARK: Utilities

        let hash: @convention(block) (String, String) -> String? = { algorithm, text in
            ScriptCodec.hash(algorithm, of: text)
        }
        define("hash", hash)

        let hmac: @convention(block) (String, String, Bool) -> String = { key, text, base64 in
            ScriptCodec.hmacSHA256(key: key, text: text, base64: base64)
        }
        define("hmac", hmac)

        let base64Encode: @convention(block) (String) -> String = { ScriptCodec.encodeUTF8($0) }
        define("base64Encode", base64Encode)

        let base64Decode: @convention(block) (String) -> String? = { ScriptCodec.decodeUTF8($0) }
        define("base64Decode", base64Decode)

        let btoa: @convention(block) (String) -> String? = { ScriptCodec.binaryToBase64($0) }
        define("btoa", btoa)

        let atob: @convention(block) (String) -> String? = { ScriptCodec.base64ToBinary($0) }
        define("atob", atob)

        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        define("uuid", uuid)

        // MARK: Event loop

        let timerSet: @convention(block) (Int, Double) -> Void = { [unowned self] id, delay in
            timers[id] = Self.now() &+ UInt64(max(delay, 0) * 1_000_000)
        }
        define("timerSet", timerSet)

        let timerClear: @convention(block) (Int) -> Void = { [unowned self] id in
            timers[id] = nil
        }
        define("timerClear", timerClear)

        let sendRequest: @convention(block) (String) -> Int = { [unowned self] json in
            startRequest(json)
        }
        define("sendRequest", sendRequest)

        let sourceSettled: @convention(block) (Bool, JSValue?) -> Void = { [unowned self] succeeded, error in
            settlement = succeeded ? .fulfilled : .rejected(error ?? JSValue(undefinedIn: context))
        }
        define("sourceSettled", sourceSettled)

        return host
    }

    // MARK: Initial payload

    private func initialPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "eventName": input.phase == .preRequest ? "prerequest" : "test",
            "requestName": input.requestName,
            "writable": state.allowsRequestChanges,
            "request": Self.payload(for: state.currentRequest),
        ]
        if let name = state.environmentName { payload["environmentName"] = name }
        if input.phase == .postResponse, let response = input.response {
            payload["response"] = [
                "code": response.code,
                "status": response.status,
                "headers": response.headers.map { [$0.name, $0.value] },
                "text": Self.text(of: response.body),
                "responseTime": response.responseTime,
                "size": response.body.count,
            ] as [String: Any]
        }
        return payload
    }

    private static func payload(for request: ScriptRequest) -> [String: Any] {
        var payload: [String: Any] = [
            "method": request.method,
            "url": request.url,
            "headers": request.headers.map { [$0.name, $0.value] },
        ]
        if let body = request.body { payload["body"] = body }
        return payload
    }

    static func payload(for response: HTTPResponse) -> [String: Any] {
        [
            "code": response.statusCode,
            "status": response.statusText.isEmpty
                ? HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
                : response.statusText,
            "headers": response.headers.map { [$0.name, $0.value] },
            "text": text(of: response.body),
            "responseTime": response.duration * 1000,
            "size": response.body.count,
        ]
    }

    private static func text(of body: Data) -> String {
        String(decoding: body, as: UTF8.self)
    }

    private static func decodeRequest(_ json: String) -> ScriptRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let method = object["method"] as? String, let url = object["url"] as? String
        else { return nil }
        let headers = (object["headers"] as? [[String]] ?? []).compactMap { pair in
            pair.count == 2 ? HeaderEntry(name: pair[0], value: pair[1]) : nil
        }
        return ScriptRequest(method: method, url: url, headers: headers, body: object["body"] as? String)
    }

    // MARK: bee.sendRequest

    /// Starts the exchange and returns its id; the outcome always arrives later through `completions`,
    /// even when the request cannot be built, so scripts see one consistent asynchronous behaviour.
    private func startRequest(_ json: String) -> Int {
        requestCounter += 1
        let id = requestCounter
        let completions = self.completions
        pendingRequests.insert(id)
        switch Self.resolvedRequest(from: json) {
        case .failure(let error):
            completions.push(id: id, result: .failure(error))
        case .success(let request):
            guard let transport else {
                completions.push(id: id, result: .failure(ScriptRequestError(
                    message: "bee.sendRequest is not available: no HTTP transport is configured"
                )))
                return id
            }
            requestTasks[id] = Task {
                do {
                    completions.push(id: id, result: .success(try await transport.send(request)))
                } catch {
                    completions.push(id: id, result: .failure(error))
                }
            }
        }
        return id
    }

    private static func resolvedRequest(from json: String) -> Result<ResolvedRequest, ScriptRequestError> {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .failure(ScriptRequestError(message: "Invalid request description"))
        }
        if let message = object["error"] as? String { return .failure(ScriptRequestError(message: message)) }
        guard let address = object["url"] as? String, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host(percentEncoded: false)?.isEmpty == false
        else {
            return .failure(ScriptRequestError(
                message: "bee.sendRequest only supports absolute http(s) URLs: \(object["url"] as? String ?? "")"
            ))
        }
        let headers = (object["headers"] as? [[String]] ?? []).compactMap { pair in
            pair.count == 2 ? HeaderEntry(name: pair[0], value: pair[1]) : nil
        }
        let body: ResolvedBody = (object["body"] as? String).map { $0.isEmpty ? .none : .data(Data($0.utf8)) } ?? .none
        return .success(ResolvedRequest(
            method: object["method"] as? String ?? "GET", url: url, headers: headers, body: body,
            timeout: 30, followRedirects: true, verifyTLS: true
        ))
    }
}
