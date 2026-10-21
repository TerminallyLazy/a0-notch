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
    private var attachmentDelivery = false
    private var modelPresets = false
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
        let result = try await catalog(path: "api/plugins/a0_notch/status", body: [:], status: true)
        guard !csrf.isEmpty else { throw LiveError.authentication }
        authenticated = true
        exactTargetActions = result.capabilities?.contains("incarnation_actions") == true
        modelPresets = result.capabilities?.contains("model_presets") == true
        attachmentDelivery = result.capabilities?.contains("attachments") == true
        return result
    }
    public func exchange(action: String, clientID: UUID, epoch: String? = nil, cursor: Int? = nil) async throws -> LiveEnvelope {
        var body: [String: Any] = ["action": action, "client_id": clientID.uuidString]
        if let epoch { body["server_epoch"] = epoch }
        if let cursor { body["cursor"] = cursor }
        return try await catalog(path: "api/plugins/a0_notch/events", body: body)
    }

    /// Pages form one immutable transaction. No partial catalog escapes this method.
    private func catalog(path: String, body: [String: Any], status: Bool = false) async throws -> LiveEnvelope {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let firstData = try await request(path: path, body: JSONSerialization.data(withJSONObject: body))
        var totalBytes = firstData.count
        var pageCount = 1
        guard ContinuousClock.now < deadline else { throw LiveError.stale }
        var result = try LiveEnvelope.decode(firstData, status: status)
        guard result.page_offset == nil || result.page_offset == 0 else { throw LiveError.invalidPayload }
        var ids = Set(result.contexts.map(\.id))
        while let offset = result.next_offset {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, offset == result.contexts.count,
                  let token = result.page_token else { throw LiveError.stale }
            guard pageCount < 512 else { throw LiveError.oversized }
            let pageData = try await request(path: path, body: JSONSerialization.data(withJSONObject: ["page_token": token, "offset": offset]))
            totalBytes += pageData.count; pageCount += 1
            guard totalBytes <= 32 * 1024 * 1024 else { throw LiveError.oversized }
            guard ContinuousClock.now < deadline else { throw LiveError.stale }
            let page = try LiveEnvelope.decode(pageData, status: status)
            guard page.page_token == token, page.page_offset == offset,
                  page.server_epoch == result.server_epoch, page.catalog_count == result.catalog_count,
                  page.cursor == result.cursor, page.reset == result.reset,
                  page.events?.isEmpty != false, !page.contexts.isEmpty else { throw LiveError.invalidPayload }
            for row in page.contexts {
                guard ids.insert(row.id).inserted else { throw LiveError.invalidPayload }
            }
            result.contexts.append(contentsOf: page.contexts)
            result.next_offset = page.next_offset
        }
        guard result.catalog_count == nil || result.contexts.count == result.catalog_count else { throw LiveError.invalidPayload }
        let tokens = Dictionary(uniqueKeysWithValues: result.contexts.map { ($0.id, $0.incarnation) })
        for event in result.events ?? [] {
            guard ids.contains(event.context_id),
                  result.page_token == nil || (event.incarnation != nil && tokens[event.context_id] == event.incarnation)
            else { throw LiveError.invalidPayload }
        }
        return result
    }

    private func checkedIncarnation(_ value: String?) throws -> String {
        guard authenticated else { throw LiveError.authentication }
        guard exactTargetActions, let value, UUID(uuidString: value) != nil else { throw LiveError.unsupportedActions }
        return value
    }

    private func api(_ path: String, body: [String: Any]) async throws -> Data {
        guard authenticated else { throw LiveError.authentication }
        return try await request(path: "api/" + path, body: JSONSerialization.data(withJSONObject: body))
    }
    public func snapshot(context: String, logFrom: Int = 0, incarnation: String? = nil) async throws -> ChatSnapshot {
        guard !context.isEmpty, logFrom >= 0 else { throw LiveError.invalidPayload }
        let incarnation = try checkedIncarnation(incarnation)
        return try ChatSnapshot.decode(await api("plugins/a0_notch/selected", body: ["context": context, "log_from": logFrom,
            "incarnation": incarnation]), target: context)
    }
    /// Probe version without history, then fetch recent updates. No whole-chat download.
    public func recentSnapshot(context: String, incarnation: String? = nil) async throws -> ChatSnapshot {
        let head = try await snapshot(context: context, logFrom: 9_007_199_254_740_991, incarnation: incarnation)
        let recent = try await snapshot(context: context, logFrom: max(0, head.log_version - 80), incarnation: incarnation)
        guard head.log_guid == recent.log_guid else { throw LiveError.stale }
        return recent
    }
    public func send(context: String, text: String, messageID: UUID, incarnation: String? = nil) async throws {
        guard !context.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024 else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        let incarnation = try checkedIncarnation(incarnation)
        let data = try await api("plugins/a0_notch/action", body: ["action": "send", "context": context, "incarnation": incarnation, "text": text, "message_id": messageID.uuidString])
        struct Accepted: Decodable { let context: String; let message: String }
        guard let result = try? JSONDecoder().decode(Accepted.self, from: data), result.context == context
        else { throw LiveError.invalidPayload }
    }
    /// One exact-target multipart message; never retries an ambiguous upload.
    public func upload(context: String, incarnation: String, files: [LiveAttachment], text: String = "",
                       messageID: UUID) async throws -> [String] {
        let body: Data
        let boundary = "A0Notch-" + UUID().uuidString
        do {
            body = try prepareUpload(context: context, incarnation: incarnation, files: files, text: text, messageID: messageID, boundary: boundary)
            try Task.checkCancellation()
        } catch { throw UploadPreparationError() }
        let data = try await request(path: "api/plugins/a0_notch/attachment", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        struct Accepted: Decodable { let context: String; let message: String; let attachment_count: Int; let attachments: [String] }
        guard let result = try? JSONDecoder().decode(Accepted.self, from: data), result.context == context,
              result.attachment_count == files.count, result.attachments.count == files.count,
              Set(result.attachments).count == files.count,
              result.attachments.allSatisfy({ $0.hasPrefix("notch-") && !$0.contains("/") && !$0.contains("..") })
        else { throw LiveError.invalidPayload }
        return result.attachments
    }

    private func prepareUpload(context: String, incarnation: String, files: [LiveAttachment], text: String,
                               messageID: UUID, boundary: String) throws -> Data {
        let incarnation = try checkedIncarnation(incarnation)
        guard attachmentDelivery, !context.isEmpty, (1...8).contains(files.count), text.utf8.count <= 64 * 1024 else { throw LiveError.invalidPayload }
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        for (key, value) in [("context", context), ("incarnation", incarnation), ("text", text), ("message_id", messageID.uuidString)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        for file in files {
            guard body.count + file.data.count + 1024 <= 16 * 1024 * 1024 else { throw LiveError.oversized }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    public func presets(context: String, incarnation: String?, action: String = "list", presetID: String? = nil) async throws -> ModelPresetList {
        let incarnation = try checkedIncarnation(incarnation)
        guard modelPresets, ["list", "set", "clear"].contains(action), !context.isEmpty else { throw LiveError.unsupportedActions }
        var body: [String: Any] = ["context": context, "incarnation": incarnation, "action": action]
        if action == "set" { guard let presetID, presetID.count == 64 else { throw LiveError.invalidPayload }; body["preset_id"] = presetID }
        return try ModelPresetList.decode(await api("plugins/a0_notch/model_presets", body: body), context: context, incarnation: incarnation)
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
    public func setPaused(context: String, paused: Bool, incarnation: String? = nil) async throws {
        guard !context.isEmpty else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        let incarnation = try checkedIncarnation(incarnation)
        let data = try await api("plugins/a0_notch/action", body: ["action": paused ? "pause" : "resume", "context": context, "incarnation": incarnation])
        struct Paused: Decodable { let context: String; let pause: Bool }
        guard let result = try? JSONDecoder().decode(Paused.self, from: data), result.pause == paused, result.context == context
        else { throw LiveError.invalidPayload }
    }
    public func stop(context: String, incarnation: String? = nil) async throws {
        guard !context.isEmpty else { throw LiveError.invalidPayload }
        guard authenticated else { throw LiveError.authentication }
        let incarnation = try checkedIncarnation(incarnation)
        let data = try await api("plugins/a0_notch/action", body: ["action": "stop", "context": context, "incarnation": incarnation])
        struct Stopped: Decodable { let context: String; let stopped: Bool }
        guard let result = try? JSONDecoder().decode(Stopped.self, from: data), result.context == context
        else { throw LiveError.invalidPayload }
    }
}
