import Foundation
import Darwin

public enum LiveError: Error, LocalizedError, Equatable {
    case invalidOrigin, authentication, http(Int), invalidPayload, oversized, stale, unsupportedActions
    public var errorDescription: String? {
        switch self {
        case .unsupportedActions: "Update the a0_notch plugin to enable exact-target chat actions. No action was sent."
        case .invalidOrigin: "Use an HTTPS origin, or HTTP on localhost, with no path or credentials."
        case .authentication: "WebUI login or session was rejected. Enter valid WebUI credentials and check that login and the a0_notch plugin are enabled. Anonymous access is not supported."
        case .http(let code): "Connection failed (HTTP \(code)). Check plugin enablement and authorization."
        case .invalidPayload: "The server returned an unsupported or malformed response."
        case .oversized: "The server response exceeded the 2 MiB safety limit."
        case .stale: "Live connection is stale. Reconnect explicitly."
        }
    }
}

public struct LiveOrigin: Equatable, Sendable {
    public let url: URL
    public init(_ text: String) throws {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw LiveError.invalidOrigin }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        guard let url = parts.url else { throw LiveError.invalidOrigin }
        self.url = url
    }
}

public enum LiveActivity: String, Codable, Sendable, CaseIterable {
    case idle, working, thinking, browsing, delegating, finished, error, paused
}
public struct LiveContext: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let state: LiveActivity
    public let tool: String
    public let running: Bool
    public let incarnation: String?
    public let parent_id: String?
    public let last_activity_at: Double?
    public let created_at: Double?
}
public struct LiveDiff: Codable, Equatable, Sendable {
    public let path: String
    public let added: Int
    public let removed: Int
}
public struct LiveEvent: Codable, Equatable, Sendable {
    public let sequence: Int
    public let context_id: String
    public let state: LiveActivity
    public let tool: String
    public let kind: String
    public let observed_at: Double
    public let incarnation: String?
    public let diff: LiveDiff?
}
public struct LiveEnvelope: Decodable, Sendable {
    public let ok: Bool
    public let schema_version: Int
    public let server_epoch: String
    public var contexts: [LiveContext]
    public let cursor: Int?
    public let reset: Bool?
    public let events: [LiveEvent]?
    public let plugin_version: String?
    public let auth: String?
    public let capabilities: [String]?
    public let dropped: [String: Int]?
    public let page_token: String?
    public let page_offset: Int?
    public var next_offset: Int?
    public let catalog_count: Int?

    public static func decode(_ data: Data, status: Bool = false) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw LiveError.oversized }
        do {
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validate(status: status)
            return result
        } catch let error as LiveError { throw error }
        catch { throw LiveError.invalidPayload }
    }
    func validate(status: Bool) throws {
        func text(_ value: String, max: Int, empty: Bool = false) -> Bool {
            (empty || !value.isEmpty) && value.count <= max && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard ok, (schema_version == 1 || schema_version == 2), UUID(uuidString: server_epoch) != nil,
              Set(contexts.map(\.id)).count == contexts.count,
              contexts.allSatisfy({ text($0.id, max: 128) && text($0.name, max: 80) && text($0.tool, max: 64, empty: true) })
        else { throw LiveError.invalidPayload }
        guard contexts.allSatisfy({ row in
            (row.incarnation.map { UUID(uuidString: $0) != nil } ?? true)
            && (row.parent_id.map { text($0, max: 128) && $0 != row.id } ?? true)
            && [row.last_activity_at, row.created_at].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) }
        }) else { throw LiveError.invalidPayload }
        if schema_version == 2 && page_token == nil { throw LiveError.invalidPayload }
        if let page_token {
            guard UUID(uuidString: page_token) != nil, let page_offset, let catalog_count,
                  page_offset >= 0, catalog_count >= 0, page_offset <= catalog_count,
                  contexts.count <= catalog_count - page_offset,
                  next_offset == nil ? contexts.count == catalog_count - page_offset
                    : (next_offset! >= page_offset && next_offset! - page_offset == contexts.count && next_offset! < catalog_count),
                  contexts.allSatisfy({ $0.incarnation != nil }) else { throw LiveError.invalidPayload }
        } else if page_offset != nil || next_offset != nil || catalog_count != nil {
            throw LiveError.invalidPayload
        }
        if status {
            guard auth == "session_csrf", let version = plugin_version, text(version, max: 32),
                  let caps = capabilities, Set(["discovery", "metadata", "poll"]).isSubset(of: Set(caps))
            else { throw LiveError.invalidPayload }
        } else {
            guard let cursor, cursor >= 0, cursor <= 9_007_199_254_740_991, reset != nil,
                  let events, events.count <= 64, let dropped,
                  Set(dropped.keys) == Set(["overflow", "contention", "no_consumer", "invalid"]),
                  dropped.values.allSatisfy({ $0 >= 0 }) else { throw LiveError.invalidPayload }
            var last = -1
            let ids = Set(contexts.map(\.id))
            for event in events {
                guard event.sequence > last, event.sequence <= cursor, (page_token != nil || ids.contains(event.context_id)),
                      text(event.tool, max: 64, empty: true), event.observed_at.isFinite, event.observed_at >= 0,
                      ["thinking", "tool_start", "tool_end", "finished", "error", "idle", "intervention"].contains(event.kind)
                else { throw LiveError.invalidPayload }
                if let incarnation = event.incarnation, UUID(uuidString: incarnation) == nil { throw LiveError.invalidPayload }
                if let diff = event.diff {
                    let parts = diff.path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !diff.path.isEmpty, diff.path.count <= 240, !diff.path.contains("\\"),
                          parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
                          text(diff.path, max: 240), (0...512).contains(diff.added), (0...512).contains(diff.removed)
                    else { throw LiveError.invalidPayload }
                }
                last = event.sequence
            }
        }
    }
}

/// Value-state owner shared by the app and tests; uses a monotonic clock supplied by caller.
public struct LiveSessionState: Sendable {
    public enum Mode: String, Sendable { case disconnected, connecting, live, stale }
    public private(set) var mode: Mode = .disconnected
    public private(set) var generation = UUID()
    public private(set) var contexts: [LiveContext] = []
    public private(set) var epoch: String?
    public private(set) var cursor = 0
    public private(set) var lastAccepted: TimeInterval?
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        clear(.connecting); return generation
    }
    public mutating func clear(_ mode: Mode = .disconnected) {
        generation = UUID(); self.mode = mode; contexts = []; epoch = nil; cursor = 0; lastAccepted = nil
    }
    @discardableResult public mutating func accept(_ envelope: LiveEnvelope, generation: UUID, now: TimeInterval) throws -> Bool {
        guard self.generation == generation, mode == .connecting || mode == .live else { return false }
        guard envelope.next_offset == nil, envelope.catalog_count == nil || envelope.catalog_count == envelope.contexts.count,
              now.isFinite, let nextCursor = envelope.cursor,
              epoch == nil || (epoch == envelope.server_epoch && nextCursor >= cursor) else { throw LiveError.invalidPayload }
        if let events = envelope.events, epoch != nil,
           events.contains(where: { $0.sequence <= cursor }) { throw LiveError.invalidPayload }
        epoch = envelope.server_epoch; cursor = nextCursor; contexts = envelope.contexts
        lastAccepted = now; mode = .live
        return true
    }
    public mutating func fail(generation: UUID) {
        guard generation == self.generation, mode == .live || mode == .connecting else { return }
        mode = lastAccepted == nil ? .disconnected : .stale
        self.generation = UUID()
        contexts = [] // stale data is not represented as current agent activity
    }
    @discardableResult public mutating func expire(now: TimeInterval) -> Bool {
        guard mode == .live, let lastAccepted, now - lastAccepted >= 10 else { return false }
        fail(generation: generation); return true
    }
}


/// Only the explicitly selected chat is requested. Other snapshot collections are ignored.
public struct ChatLog: Decodable, Identifiable, Sendable, Equatable {
    public let no: Int
    public let type: String
    public let heading: String
    public let content: String
    public let agentno: Int?
    public var id: Int { no }
}
public struct ChatSnapshot: Decodable, Sendable {
    public let context: String
    public let deselect_chat: Bool
    public let logs: [ChatLog]
    public let log_guid: String
    public let log_version: Int
    public let paused: Bool
    public let log_progress: String
    public let log_progress_active: Bool

    enum CodingKeys: String, CodingKey {
        case context, deselect_chat, logs, log_guid, log_version, paused, log_progress, log_progress_active
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = try c.decode(String.self, forKey: .context)
        deselect_chat = try c.decode(Bool.self, forKey: .deselect_chat)
        logs = try c.decode([ChatLog].self, forKey: .logs)
        log_guid = try c.decode(String.self, forKey: .log_guid)
        log_version = try c.decode(Int.self, forKey: .log_version)
        paused = try c.decode(Bool.self, forKey: .paused)
        log_progress = (try? c.decode(String.self, forKey: .log_progress)) ?? ""
        log_progress_active = try c.decode(Bool.self, forKey: .log_progress_active)
    }
    public static func decode(_ data: Data, target: String) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw LiveError.oversized }
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              !target.isEmpty, value.context == target, !value.deselect_chat,
              !value.log_guid.isEmpty, value.log_version >= 0,
              value.logs.allSatisfy({ $0.no >= 0 }),
              Set(value.logs.map(\.no)).count == value.logs.count
        else { throw LiveError.invalidPayload }
        return value
    }
    public var lastResponse: String? {
        logs.filter { $0.type == "response" && ($0.agentno ?? 0) == 0 }
            .max(by: { $0.no < $1.no })?.content
    }
}

/// Captured before any await. Selection and connection revisions are both required.
public struct ChatTarget: Equatable, Sendable {
    public let context: String
    public let generation: UUID
    public let selection: UUID
    public let incarnation: String?
    public init(context: String, generation: UUID, selection: UUID, incarnation: String? = nil) {
        self.context = context; self.generation = generation; self.selection = selection; self.incarnation = incarnation
    }
}
public extension LiveSessionState {
    func permits(_ target: ChatTarget, selected: String, selection: UUID, now: TimeInterval) -> Bool {
        mode == .live && generation == target.generation && target.selection == selection
        && target.context == selected && contexts.contains { $0.id == selected && $0.incarnation == target.incarnation }
        && isFresh(now: now)
    }
    func isFresh(now: TimeInterval) -> Bool {
        mode == .live && now.isFinite && lastAccepted.map { now >= $0 && now - $0 < 10 } == true
    }
}

/// Prepared locally before upload. Paths never cross the wire; only a safe basename.
public struct LiveAttachment: Sendable {
    public let filename: String
    public let contentType: String
    public let data: Data
    public init(url: URL, remainingBytes: Int = 8 * 1024 * 1024) throws {
        guard url.isFileURL else { throw LiveError.invalidPayload }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw LiveError.invalidPayload }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw LiveError.invalidPayload }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = String(part).withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            guard next >= 0 else { throw LiveError.invalidPayload }
            Darwin.close(directory); directory = next
        }
        let descriptor = String(parts.last!).withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw LiveError.invalidPayload }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= min(8 * 1024 * 1024, remainingBytes) else { throw LiveError.invalidPayload }
        // Bound the read even if a concurrent writer grows/replaces the path.
        let data = try handle.read(upToCount: min(8 * 1024 * 1024, max(0, remainingBytes)) + 1) ?? Data()
        guard data.count <= remainingBytes else { throw LiveError.oversized }
        try self.init(filename: url.lastPathComponent, data: data)
    }
    public init(filename: String, data: Data) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        let types = ["txt":"text/plain", "md":"text/markdown", "csv":"text/csv", "json":"application/json",
                     "log":"text/plain", "yaml":"application/yaml", "yml":"application/yaml",
                     "pdf":"application/pdf", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg"]
        let suffix = (filename as NSString).pathExtension.lowercased()
        guard (1...120).contains(filename.count), filename.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              filename.first?.isASCII == true, filename.first?.isLetter == true || filename.first?.isNumber == true,
              !filename.hasSuffix(" "), !filename.hasSuffix("."), let type = types[suffix],
              !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw LiveError.invalidPayload }
        self.filename = filename; self.contentType = type; self.data = data
    }
}


/// Raised only before any upload request is dispatched.
public struct UploadPreparationError: Error, Sendable {}


public struct ModelPresetList: Decodable, Sendable {
    public struct Preset: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let model: String
    }
    public let ok: Bool
    public let context: String
    public let incarnation: String
    public let allowed: Bool
    public let current_id: String
    public let current_label: String
    public let presets: [Preset]
    public static func decode(_ data: Data, context: String, incarnation: String) throws -> Self {
        guard data.count <= 512 * 1024, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.ok, value.context == context, value.incarnation.lowercased() == incarnation.lowercased(),
              value.presets.count <= 256, Set(value.presets.map(\.id)).count == value.presets.count,
              value.current_label.count <= 120,
              value.presets.allSatisfy({ $0.id.count == 64 && $0.label.count <= 120 && $0.model.count <= 120 })
        else { throw LiveError.invalidPayload }
        return value
    }
}
