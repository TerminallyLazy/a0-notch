import AppKit
import Observation
import SwiftUI
import NotchCore

enum A0Theme {
    static let background = Color(hex: 0x131313)
    static let messageBackground = Color(hex: 0x2D2D2D)
    static let highlight = Color(hex: 0x2B5AB9)
    static let error = Color(hex: 0xE72323)
    static let warning = Color(hex: 0xE79C23)
    static let okHover = Color(hex: 0x353BC5)
    static let okPressed = Color(hex: 0x2B309C)
    static let panel = Color(hex: 0x1A1A1A)
    static let border = Color(hex: 0x444444).opacity(0.66)
    static let muted = Color(hex: 0xD4D4D4).opacity(0.9)
    static let accent = Color(hex: 0xCF6679)
    static let ok = Color(hex: 0x4248F1)
}
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

enum ContextActivity: String, CaseIterable {
    case thinking, working, browsing, delegating, finished, idle, error, paused
    var color: Color {
        switch self {
        case .idle, .paused: Color(hex: 0x94A3B8)
        case .error: A0Theme.error
        case .thinking: Color(hex: 0x38BDF8)
        case .working: Color(hex: 0xFBBF24)
        case .browsing: Color(hex: 0x818CF8)
        case .delegating: Color(hex: 0x14B8A6)
        case .finished: Color(hex: 0x22C55E)
        }
    }
    var symbol: String {
        switch self {
        case .idle, .paused: "pause.circle"
        case .error: "exclamationmark.circle"
        case .thinking: "sparkles"
        case .working: "terminal"
        case .browsing: "globe"
        case .delegating: "arrow.triangle.branch"
        case .finished: "checkmark.circle"
        }
    }
    var step: String {
        switch self {
        case .idle: "Agent Zero is idle"
        case .paused: "Paused in the WebUI"
        case .error: "An error was observed"
        case .thinking: "Planning the next step"
        case .working: "Running a local tool"
        case .browsing: "Exploring a reference"
        case .delegating: "Asking a subordinate"
        case .finished: "Response delivered"
        }
    }
}
extension LiveContext {
    var activity: ContextActivity { ContextActivity(rawValue: state.rawValue) ?? .idle }
}

@MainActor @Observable
final class IslandStore {
    private(set) var mode: IslandMode = .hidden
    private(set) var contexts: [LiveContext] = []
    private(set) var focusedID = ""
    private(set) var selection = UUID()
    var gaze = CGPoint.zero
    var geometry = IslandGeometry(size: CGSize(width: 80, height: 24), bottomRadius: 14, restrictBelow: true)
    var hardwareNotchHeight = 0.0
    private(set) var presentation: IslandPresentation
    var countdown = 1.0
    var hasNotch = false
    var displayName = "Display"
    var displayChoice: IslandDisplayChoice
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var machine = IslandStateMachine(now: ProcessInfo.processInfo.systemUptime)
    @ObservationIgnored var showChats: () -> Void = {}
    @ObservationIgnored var showConnection: () -> Void = {}

    var connectionURL: String
    var autoCloseSeconds: Double = 60 {
        didSet { machine.autoCloseSeconds = autoCloseSeconds; defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds") }
    }
    var absenceMinutes: Double = 3 {
        didSet { machine.absenceSeconds = absenceMinutes * 60; defaults.set(absenceMinutes, forKey: "absenceMinutes") }
    }
    var autoOpenEvents = true {
        didSet { defaults.set(autoOpenEvents, forKey: "autoOpenEvents") }
    }
    var connectionUsername: String
    private(set) var connectedOrigin = ""
    private(set) var supportsActions = false
    private(set) var connectionMessage = "Connect with your Agent Zero WebUI account to discover your chats."
    private(set) var connectionError = false
    private(set) var live = LiveSessionState()
    private(set) var chatSnapshot: ChatSnapshot?
    private(set) var lastResponse = ""
    private(set) var chatMessage = "Select a chat to view recent activity."
    private(set) var mutationMessage = ""
    private(set) var mutationBusy = false
    private(set) var uncertainOutcome = false
    private var drafts: [String: String] = [:]
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var client: LiveHTTPClient?
    @ObservationIgnored private var clientID = UUID()
    @ObservationIgnored private var detailAccepted: TimeInterval?
    @ObservationIgnored private var pendingCreatedID: String?
    @ObservationIgnored private var creationSelection: UUID?

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        connectionURL = defaults.string(forKey: "connectionURL") ?? ""
        connectionUsername = defaults.string(forKey: "connectionUsername") ?? ""
        displayChoice = IslandDisplayChoice(rawValue: defaults.string(forKey: "islandDisplay") ?? "notch")
        presentation = IslandPresentation.launchOverride(arguments: arguments)
            ?? IslandPresentation(persistedValue: defaults.string(forKey: "islandPresentation"))
        let close = defaults.object(forKey: "autoCloseSeconds") as? Double ?? 60
        let absent = defaults.object(forKey: "absenceMinutes") as? Double ?? 3
        autoCloseSeconds = close.isFinite ? min(300, max(15, close)) : 60
        absenceMinutes = absent.isFinite ? min(30, max(1, absent)) : 3
        autoOpenEvents = defaults.object(forKey: "autoOpenEvents") as? Bool ?? true
        machine.autoCloseSeconds = autoCloseSeconds
        machine.absenceSeconds = absenceMinutes * 60
    }
    var focused: LiveContext? { contexts.first { $0.id == focusedID } }
    var tint: Color { focused?.activity.color ?? A0Theme.accent }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var connectionLabel: String { live.mode.rawValue.uppercased() }
    var animatesActivity: Bool { live.mode == .live }
    var connecting: Bool { live.mode == .connecting }
    var draft: String {
        get { drafts[focusedID] ?? "" }
        set { if !focusedID.isEmpty { drafts[focusedID] = newValue; interact() } }
    }
    var target: ChatTarget { ChatTarget(context: focusedID, generation: live.generation, selection: selection) }
    var canMutate: Bool {
        supportsActions && !mutationBusy && !uncertainOutcome && permits(target)
        && detailAccepted.map { now - $0 < 10 } == true && chatSnapshot?.context == focusedID
    }
    var canCreate: Bool { !mutationBusy && !uncertainOutcome && live.isFresh(now: now) }
    var activityLine: String {
        if let snapshot = chatSnapshot, snapshot.context == focusedID, !snapshot.log_progress.isEmpty {
            return snapshot.log_progress
        }
        if let tool = focused?.tool, !tool.isEmpty { return tool }
        return focused?.activity.step ?? "No chat selected"
    }
    private func permits(_ captured: ChatTarget) -> Bool {
        live.permits(captured, selected: focusedID, selection: selection, now: now)
    }
    func selectPresentation(_ choice: IslandPresentation) {
        presentation = choice; defaults.set(choice.rawValue, forKey: "islandPresentation"); interact()
    }
    func selectDisplay(_ choice: IslandDisplayChoice) {
        displayChoice = choice; defaults.set(choice.rawValue, forKey: "islandDisplay")
    }
    func tick(hovering: Bool, moved: Bool) {
        if live.expire(now: now) {
            liveTask?.cancel(); invalidateMutation(); clearSelection(); contexts = []; machine.hasActivity = false; machine.close(now: now)
            connectionMessage = LiveError.stale.localizedDescription; connectionError = true; releaseClient()
        }
        machine.tick(now: now, isHovering: hovering, mouseMoved: moved)
        if mode != machine.mode { mode = machine.mode }
        if abs(countdown - machine.countdownFraction) > 0.005 { countdown = machine.countdownFraction }
    }
    func open() { machine.open(now: now); mode = machine.mode }
    func close() { machine.close(now: now); mode = machine.mode }
    func interact() { machine.interact(now: now) }
    func focus(_ id: String) {
        pendingCreatedID = nil
        guard id != focusedID, contexts.contains(where: { $0.id == id }) else { return }
        clearSelection(); focusedID = id; interact(); refreshSelectedChat()
    }
    private func clearSelection() {
        detailTask?.cancel(); detailTask = nil; selection = UUID(); focusedID = ""
        chatSnapshot = nil; detailAccepted = nil; lastResponse = ""
        chatMessage = "Select a chat to view recent activity."
    }
    private func releaseClient() {
        let previous = client; client = nil
        let previousID = clientID, epoch = live.epoch
        if let previous {
            Task {
                if let epoch { _ = try? await previous.exchange(action: "disconnect", clientID: previousID, epoch: epoch) }
                await previous.cancel()
            }
        }
    }
    private func invalidateMutation() {
        if mutationBusy {
            uncertainOutcome = true
            mutationMessage = "Connection changed during an action. Check the chat before trying again; nothing is replayed."
        }
        mutationTask?.cancel(); mutationTask = nil; mutationBusy = false
    }
    func disconnectLive() {
        liveTask?.cancel(); liveTask = nil
        invalidateMutation()
        clearSelection(); releaseClient(); live.clear(); contexts = []; drafts = [:]; pendingCreatedID = nil
        machine.hasActivity = false; machine.close(now: now); connectedOrigin = ""; supportsActions = false
        connectionMessage = "Disconnected. Your saved server and account are unchanged."; connectionError = false
    }
    func connectLive(password: String, savePassword: Bool, testOnly: Bool = false) {
        guard !connecting else { return }
        disconnectLive()
        let generation = live.begin()
        do {
            let origin = try LiveOrigin(connectionURL)
            let username = connectionUsername
            let credential = password.isEmpty ? (NotchKeychain.read(origin: origin.url.absoluteString, username: username) ?? "") : password
            guard !username.isEmpty, !credential.isEmpty else { throw LiveError.authentication }
            defaults.set(origin.url.absoluteString, forKey: "connectionURL")
            defaults.set(username, forKey: "connectionUsername")
            let connection = LiveHTTPClient(origin: origin)
            client = connection; clientID = UUID(); let id = clientID
            connectionMessage = testOnly ? "Signing in and testing discovery…" : "Signing in securely…"
            liveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await connection.authenticate(username: username, password: credential)
                    let status = try await connection.status()
                    guard self.live.generation == generation, !Task.isCancelled else { return }
                    if savePassword { try NotchKeychain.save(credential, origin: origin.url.absoluteString, username: username) }
                    if testOnly {
                        self.disconnectLive()
                        self.connectionMessage = "Authenticated · plugin \(status.plugin_version ?? "unknown") · \(status.contexts.count) chats discovered. Test complete; not connected."
                        return
                    }
                    self.connectedOrigin = origin.url.absoluteString
                    self.supportsActions = status.capabilities?.contains("exact_target_actions") == true
                    var envelope = try await connection.exchange(action: "connect", clientID: id)
                    while !Task.isCancelled {
                        guard try self.live.accept(envelope, generation: generation, now: self.now) else { return }
                        self.contexts = self.live.contexts.sorted {
                            let a = $0.last_activity_at ?? 0, b = $1.last_activity_at ?? 0
                            return a == b ? $0.id < $1.id : a > b
                        }
                        self.machine.hasActivity = self.contexts.contains { $0.running }
                        self.connectionMessage = self.supportsActions ? "Connected · \(self.contexts.count) chats · refreshed automatically" : "Connected read-only. Update the plugin to enable exact-target actions."
                        if let created = self.pendingCreatedID, self.contexts.contains(where: { $0.id == created }) {
                            self.pendingCreatedID = nil
                            if self.creationSelection == self.selection { self.focus(created) }
                        } else if !self.contexts.contains(where: { $0.id == self.focusedID }) {
                            if !self.focusedID.isEmpty { self.clearSelection() }
                        }
                        if self.detailTask == nil { self.refreshSelectedChat() }
                        // Never steal the user's selected chat or fetch another transcript.
                        if self.autoOpenEvents, !self.focusedID.isEmpty {
                            for event in envelope.events ?? [] where event.context_id == self.focusedID {
                                if event.kind == "error" { self.machine.showAttention(now: self.now) }
                                else if event.kind == "finished" { self.machine.showFinished(now: self.now) }
                            }
                        }
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                        envelope = try await connection.exchange(action: "poll", clientID: id, epoch: self.live.epoch, cursor: self.live.cursor)
                    }
                } catch {
                    guard self.live.generation == generation else { return }
                    self.invalidateMutation(); self.live.fail(generation: generation); self.clearSelection(); self.contexts = []; self.machine.hasActivity = false; self.machine.close(now: self.now)
                    self.connectionMessage = (error as? LiveError)?.localizedDescription ?? "Connection interrupted. Reconnect explicitly."
                    self.connectionError = true; self.releaseClient()
                }
            }
        } catch {
            live.fail(generation: generation); connectionError = true
            connectionMessage = (error as? LiveError)?.localizedDescription ?? "Connection unavailable."
        }
    }
    func refreshSelectedChat() {
        guard detailTask == nil, let connection = client, permits(target) else { return }
        let captured = target
        detailTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.selection == captured.selection { self.detailTask = nil } }
            do {
                let snapshot = try await connection.recentSnapshot(context: captured.context)
                guard self.permits(captured), !Task.isCancelled else { return }
                if self.chatSnapshot?.log_guid != snapshot.log_guid { self.lastResponse = "" }
                self.chatSnapshot = snapshot; self.detailAccepted = self.now
                if let response = snapshot.lastResponse { self.lastResponse = response }
                self.chatMessage = "Recent activity · updated just now"
            } catch {
                guard self.permits(captured), !Task.isCancelled else { return }
                self.detailAccepted = nil; self.chatMessage = "Recent activity unavailable. Actions disabled until this chat refreshes."
                if error as? LiveError == .authentication { self.disconnectLive(); self.connectionError = true; self.connectionMessage = LiveError.authentication.localizedDescription }
            }
        }
    }
    enum Action { case send, pause(Bool), stop }
    func perform(_ action: Action, target captured: ChatTarget) {
        guard canMutate, permits(captured), let connection = client else { return }
        let text = draft
        if case .send = action {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64 * 1024 else { return }
        }
        mutationBusy = true; mutationMessage = "Checking selected chat…"
        mutationTask = Task { [weak self] in
            guard let self else { return }
            var dispatched = false
            defer { if self.live.generation == captured.generation { self.mutationBusy = false; self.mutationTask = nil } }
            do {
                // Preflight preserves local selection intent; the plugin revalidates target identity at dispatch.
                let status = try await connection.status()
                guard status.server_epoch == self.live.epoch, status.contexts.contains(where: { $0.id == captured.context }) else { throw LiveError.stale }
                _ = try await connection.snapshot(context: captured.context, logFrom: 9_007_199_254_740_991)
                try Task.checkCancellation()
                guard self.permits(captured) else { throw LiveError.stale }
                dispatched = true; self.mutationMessage = "Sending action…"
                switch action {
                case .send: try await connection.send(context: captured.context, text: text, messageID: UUID())
                case .pause(let paused): try await connection.setPaused(context: captured.context, paused: paused)
                case .stop: try await connection.stop(context: captured.context)
                }
                guard self.live.generation == captured.generation, !Task.isCancelled else { return }
                if case .send = action, self.drafts[captured.context] == text { self.drafts[captured.context] = "" }
                self.mutationMessage = "Action accepted by Agent Zero for chat \(captured.context)."
                if self.permits(captured) {
                    self.detailAccepted = nil
                    self.refreshSelectedChat()
                }
            } catch {
                guard self.live.generation == captured.generation else { return }
                self.uncertainOutcome = dispatched
                self.mutationMessage = dispatched
                    ? "Outcome unknown. Check this chat in the WebUI before sending again. Nothing will be retried automatically."
                    : "Action not sent: the selected chat or connection changed. Refresh and try explicitly."
            }
        }
    }
    func acknowledgeOutcome() { uncertainOutcome = false; mutationMessage = "Acknowledged. No action was replayed." }
    func createChat() {
        guard canCreate, let connection = client else { return }
        let generation = live.generation, id = UUID().uuidString
        creationSelection = selection
        mutationBusy = true; mutationMessage = "Creating a new chat…"
        mutationTask = Task { [weak self] in
            guard let self else { return }
            var dispatched = false
            defer { if self.live.generation == generation { self.mutationBusy = false; self.mutationTask = nil } }
            do {
                let status = try await connection.status()
                guard self.live.generation == generation, self.live.isFresh(now: self.now), status.server_epoch == self.live.epoch else { throw LiveError.stale }
                try Task.checkCancellation(); dispatched = true
                _ = try await connection.createChat(id: id)
                guard self.live.generation == generation, !Task.isCancelled else { return }
                self.pendingCreatedID = id; self.mutationMessage = "Chat created. Waiting for discovery…"
            } catch {
                guard self.live.generation == generation else { return }
                self.uncertainOutcome = dispatched
                self.mutationMessage = dispatched ? "Creation outcome unknown. Check the WebUI before creating another chat. Nothing is replayed." : "Chat was not created: connection changed."
            }
        }
    }
    func openWebUI() {
        // Opening a browser is an explicit user action, never a telemetry side effect.
        guard let origin = try? LiveOrigin(connectedOrigin.isEmpty ? connectionURL : connectedOrigin) else { return }
        NSWorkspace.shared.open(origin.url)
    }
}
