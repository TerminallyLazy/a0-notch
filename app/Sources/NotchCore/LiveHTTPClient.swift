import Foundation

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One isolated cookie jar per explicit connection. Never follows redirects or uses shared credentials.
public actor LiveHTTPClient {
    public let origin: LiveOrigin
    private let session: URLSession
    private var csrf = ""
    private var authenticated = false
    private var exactTargetActions = false
    public init(origin: LiveOrigin, configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        // Never accept a caller-provided shared/persistent cookie jar.
        let isolated = URLSessionConfiguration.ephemeral
        isolated.protocolClasses = configuration.protocolClasses
        let configuration = isolated
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func cancel() { authenticated = false; csrf = ""; session.invalidateAndCancel() }

    private func request(path: String, method: String = "POST", body: Data? = nil,
                         contentType: String = "application/json", login: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: origin.url.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(origin.url.absoluteString, forHTTPHeaderField: "Origin")
        if !csrf.isEmpty { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw LiveError.invalidPayload }
        if login {
            guard response.statusCode == 302,
                  response.value(forHTTPHeaderField: "Location") == "/" else { throw LiveError.authentication }
            return Data()
        }
        guard response.statusCode == 200 else {
            if [301, 302, 303, 307, 308, 401, 403].contains(response.statusCode) { throw LiveError.authentication }
            throw LiveError.http(response.statusCode)
        }
        guard response.mimeType == "application/json" else { throw LiveError.invalidPayload }
        guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw LiveError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw LiveError.oversized }
            data.append(byte)
        }
        return data
    }
    public func authenticate(username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else { throw LiveError.authentication }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = "username=\(username.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")&password=\(password.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        _ = try await request(path: "login", body: Data(form.utf8), contentType: "application/x-www-form-urlencoded", login: true)
        let data = try await request(path: "api/csrf_token", method: "GET")
        struct CSRF: Decodable { let ok: Bool; let token: String }
        let result: CSRF
        do { result = try JSONDecoder().decode(CSRF.self, from: data) }
        catch { throw LiveError.invalidPayload }
        guard result.ok, (16...256).contains(result.token.count) else { throw LiveError.authentication }
        csrf = result.token
    }
    public func status() async throws -> LiveEnvelope {
        let result = try LiveEnvelope.decode(await request(path: "api/plugins/a0_notch/status", body: Data("{}".utf8)), status: true)
        guard !csrf.isEmpty else { throw LiveError.authentication }
        authenticated = true
        exactTargetActions = result.capabilities?.contains("exact_target_actions") == true
        return result
    }
    public func exchange(action: String, clientID: UUID, epoch: String? = nil, cursor: Int? = nil) async throws -> LiveEnvelope {
        var body: [String: Any] = ["action": action, "client_id": clientID.uuidString]
        if let epoch { body["server_epoch"] = epoch }
        if let cursor { body["cursor"] = cursor }
        return try LiveEnvelope.decode(await request(path: "api/plugins/a0_notch/events", body: JSONSerialization.data(withJSONObject: body)))
    }

    private func api(_ path: String, body: [String: Any]) async throws -> Data {
        guard authenticated else { throw LiveError.authentication }
        return try await request(path: "api/" + path, body: JSONSerialization.data(withJSONObject: body))
    }
    public func snapshot(context: String, logFrom: Int = 0) async throws -> ChatSnapshot {
        guard !context.isEmpty, logFrom >= 0 else { throw LiveError.invalidPayload }
        return try ChatSnapshot.decode(await api("poll", body: ["context": context, "log_from": logFrom,
            "notifications_from": 9_007_199_254_740_991, "timezone": "UTC"]), target: context)
    }
    /// Probe version without history, then fetch recent updates. No whole-chat download.
    public func recentSnapshot(context: String) async throws -> ChatSnapshot {
        let head = try await snapshot(context: context, logFrom: 9_007_199_254_740_991)
        let recent = try await snapshot(context: context, logFrom: max(0, head.log_version - 80))
        guard head.log_guid == recent.log_guid else { throw LiveError.stale }
        return recent
    }
    public func send(context: String, text: String, messageID: UUID) async throws {
        guard !context.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024 else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        guard exactTargetActions else { throw LiveError.unsupportedActions }
        let data = try await api("plugins/a0_notch/action", body: ["action": "send", "context": context, "text": text, "message_id": messageID.uuidString])
        struct Accepted: Decodable { let context: String; let message: String }
        guard let result = try? JSONDecoder().decode(Accepted.self, from: data), result.context == context
        else { throw LiveError.invalidPayload }
    }
    public func createChat(id: String) async throws -> String {
        guard UUID(uuidString: id) != nil else { throw LiveError.invalidPayload }
        // Explicit empty project avoids accidental inheritance from another chat.
        let data = try await api("chat_create", body: ["new_context": id, "project_name": ""])
        struct Created: Decodable { let ok: Bool; let ctxid: String }
        guard let result = try? JSONDecoder().decode(Created.self, from: data), result.ok, result.ctxid == id
        else { throw LiveError.invalidPayload }
        return result.ctxid
    }
    public func setPaused(context: String, paused: Bool) async throws {
        guard !context.isEmpty else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        guard exactTargetActions else { throw LiveError.unsupportedActions }
        let data = try await api("plugins/a0_notch/action", body: ["action": paused ? "pause" : "resume", "context": context])
        struct Paused: Decodable { let context: String; let pause: Bool }
        guard let result = try? JSONDecoder().decode(Paused.self, from: data), result.pause == paused, result.context == context
        else { throw LiveError.invalidPayload }
    }
    public func stop(context: String) async throws {
        guard !context.isEmpty else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        guard exactTargetActions else { throw LiveError.unsupportedActions }
        let data = try await api("plugins/a0_notch/action", body: ["action": "stop", "context": context])
        struct Stopped: Decodable { let context: String; let stopped: Bool }
        guard let result = try? JSONDecoder().decode(Stopped.self, from: data), result.context == context
        else { throw LiveError.invalidPayload }
    }
}
