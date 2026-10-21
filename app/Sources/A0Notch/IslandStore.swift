import AppKit
import Observation
import CryptoKit
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
    enum DictationSurface { case island, chat }
    let dictation: DictationSession
    private(set) var dictationSurface: DictationSurface?
    private var dictationTarget: ChatTarget?
    var dictationOnDeviceOnly = true {
        didSet { if dictationOnDeviceOnly != oldValue { cancelDictation(); saveDictationPreferences() } }
    }
    var dictationLocale = Locale.current.identifier {
        didSet { if dictationLocale != oldValue { cancelDictation(); saveDictationPreferences() } }
    }
    var canDictate: Bool { canMutate && !suspended }
    private(set) var modelPresets: ModelPresetList?
    private(set) var modelPresetTarget: ChatTarget?
    private(set) var modelPresetMessage = "Open to load this chat's model presets."
    private var modelReadID: UUID?
    var modelInformation: String { modelPresets?.current_label ?? "Model preset · managed by Agent Zero" }
    var modelSettingsGuidance: String { "Select an existing preset for this chat only. A preset can also change utility and embedding models. Definitions are edited in the WebUI; this app never changes global settings." }
    func loadModelPresets() {
        guard canMutate, let connection = client else { return }
        let captured = target, revision = UUID(); modelReadID = revision
        modelPresets = nil; modelPresetTarget = nil; modelPresetMessage = "Loading presets…"
        Task { [weak self] in
            do {
                let value = try await connection.presets(context: captured.context, incarnation: captured.incarnation)
                guard let self, self.modelReadID == revision, self.permits(captured) else { return }
                self.modelPresets = value; self.modelPresetTarget = captured; self.modelPresetMessage = value.allowed ? "Choose explicitly to apply to this chat." : "Per-chat overrides are disabled by Agent Zero."
            } catch {
                guard let self, self.modelReadID == revision, self.permits(captured) else { return }
                self.modelPresetMessage = "Preset selection unavailable. Update the plugin or use this chat's selector in the WebUI."
            }
        }
    }
    func selectModelPreset(_ id: String?, target captured: ChatTarget) {
        guard canMutate, permits(captured), modelPresetTarget == captured, modelPresets?.allowed == true,
              id == nil || modelPresets?.presets.contains(where: { $0.id == id }) == true, let connection = client else { return }
        detailID = UUID(); detailTask?.cancel(); detailTask = nil
        let owner = UUID(); mutationID = owner; mutationBusy = true
        modelReadID = nil; mutationMessage = "Applying this chat's preset…"
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.mutationID == owner { self.mutationID = nil; self.mutationBusy = false; self.mutationTask = nil } }
            do {
                try Task.checkCancellation()
                guard self.permits(captured) else { throw LiveError.stale }
                let value = try await connection.presets(context: captured.context, incarnation: captured.incarnation,
                    action: id == nil ? "clear" : "set", presetID: id)
                guard self.mutationID == owner, self.permits(captured), !Task.isCancelled else { return }
                self.modelPresets = value; self.mutationMessage = "Chat preset updated. Global settings unchanged."
            } catch {
                guard self.mutationID == owner, self.permits(captured) else { return }
                self.uncertainOutcome = true
                self.mutationMessage = "Preset outcome unknown. Check this chat in the WebUI; nothing is replayed."
            }
        }
    }
    func openModelSettings() { openWebUI() }
    func beginDictation(surface: DictationSurface, consent: Bool) {
        guard consent, canDictate else { return }
        cancelDictation(); dictationSurface = surface; dictationTarget = target
        dictation.begin(locale: dictationLocale, onDeviceOnly: dictationOnDeviceOnly, consent: true)
    }
    func stopDictation() { if dictation.active { dictation.finish() } }
    func cancelDictation() { dictation.cancel(); dictationTarget = nil; dictationSurface = nil }
    @discardableResult func insertDictation() -> Bool {
        guard let captured = dictationTarget, captured == target, permits(captured),
              !dictation.active, !dictation.transcript.isEmpty else { cancelDictation(); return false }
        let text = draft + (draft.isEmpty ? "" : " ") + dictation.transcript
        guard text.utf8.count <= 64 * 1024 else {
            dictation.finish(error: "This would exceed the draft limit. Copy the transcript before cancelling, or shorten the draft and try again.")
            return false
        }
        draft = text; cancelDictation() // never dispatch or submit
        return true
    }
    private func loadDictationPreferences() {
        let onDevice = defaults.object(forKey: preferenceKey + ".dictation.onDevice") as? Bool ?? true
        let locale = defaults.string(forKey: preferenceKey + ".dictation.locale") ?? Locale.current.identifier
        dictationOnDeviceOnly = onDevice
        dictationLocale = locale
    }
    private func saveDictationPreferences() {
        guard !preferenceKey.isEmpty else { return }
        defaults.set(dictationOnDeviceOnly, forKey: preferenceKey + ".dictation.onDevice")
        defaults.set(dictationLocale, forKey: preferenceKey + ".dictation.locale")
    }
    var gaze = CGPoint.zero
    var geometry = IslandGeometry(size: CGSize(width: 80, height: 24), bottomRadius: 14, restrictBelow: true)
    var hardwareNotchHeight = 0.0
    private(set) var presentation: IslandPresentation
    var countdown = 1.0
    private var noteDeadline: TimeInterval?
    var hasNotch = false
    var displayName = "Display"
    var displayChoice: IslandDisplayChoice
    @ObservationIgnored private let defaults: UserDefaults
    var expanded = ExpandedPresentationModel(now: ProcessInfo.processInfo.systemUptime)
    var preferences = ContextPreferences()
    var transfer = FileTransferState()
    var uploadPrompt = ""
    var showDiff = false
    var wardrobePresented = false
    var islandEditing = false
    var islandComposerEditing = false { didSet { if !islandComposerEditing && dictationSurface == .island { cancelDictation() } } }
    var chatComposerEditing = false { didSet { if !chatComposerEditing && dictationSurface == .chat { cancelDictation() } } }
    var avatarDragging = false
    var desktopVisible = false
    var suspended = false { didSet { if suspended { cancelDictation() } } }
    var soundMuted = false
    var soundVolume = 0.12
    var shortcutRevision = 0
    private var desktopAlertIDs: Set<String> = []
    var composerRequested = UUID()
    let wardrobe: ZeroWardrobe
    let interaction = ZeroInteraction()
    @ObservationIgnored var sounds: NotchSoundPlayer?
    @ObservationIgnored var hotkeys: GlobalHotkeys?
    @ObservationIgnored var desktop: DesktopZeroController?
    @ObservationIgnored var focusComposer: () -> Void = {}
    @ObservationIgnored private var contentGate = SelectedContentGate()
    @ObservationIgnored private var preferenceKey = ""
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var attachments: [LiveAttachment] = []
    private(set) var recentEvents: [LiveEvent] = []
    @ObservationIgnored var showChats: () -> Void = {}
    @ObservationIgnored var showConnection: () -> Void = {}

    var connectionURL: String { didSet { if connectionURL != oldValue { cancelDictation() } } }
    var autoCloseSeconds: Double = 60 {
        didSet { _ = expanded.configure(autoCloseSeconds: autoCloseSeconds, absenceSeconds: absenceMinutes * 60); defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds") }
    }
    var absenceMinutes: Double = 3 {
        didSet { _ = expanded.configure(autoCloseSeconds: autoCloseSeconds, absenceSeconds: absenceMinutes * 60); defaults.set(absenceMinutes, forKey: "absenceMinutes") }
    }
    var autoOpenEvents = true {
        didSet { defaults.set(autoOpenEvents, forKey: "autoOpenEvents") }
    }
    var connectionUsername: String { didSet { if connectionUsername != oldValue { cancelDictation() } } }
    private(set) var connectedOrigin = ""
    private(set) var supportsActions = false
    private(set) var supportsUploads = false
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
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var mutationID: UUID?
    @ObservationIgnored private var stagingReading = false
    @ObservationIgnored private var stagingID: UUID?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var client: LiveHTTPClient?
    @ObservationIgnored private var clientID = UUID()
    @ObservationIgnored private var detailAccepted: TimeInterval?
    @ObservationIgnored private var pendingCreatedID: String?
    @ObservationIgnored private var creationSelection: UUID?

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments, dictationDriver: (any DictationDriver)? = nil) {
        self.defaults = defaults
        dictation = DictationSession(driver: dictationDriver ?? AppleDictationDriver())
        wardrobe = ZeroWardrobe(defaults: defaults)
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
        _ = expanded.configure(autoCloseSeconds: autoCloseSeconds, absenceSeconds: absenceMinutes * 60)
    }
    var focused: LiveContext? { contexts.first { $0.id == focusedID } }
    var tint: Color { focused.map(color) ?? A0Theme.accent }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var connectionLabel: String { live.mode.rawValue.uppercased() }
    var animatesActivity: Bool { live.mode == .live }
    var connecting: Bool { live.mode == .connecting }
    var draft: String {
        get { drafts[focusedID] ?? "" }
        set { if !focusedID.isEmpty { drafts[focusedID] = newValue; interact() } }
    }
    var target: ChatTarget { ChatTarget(context: focusedID, generation: live.generation, selection: selection, incarnation: focused?.incarnation) }
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
        guard let permit = contentGate.selection else { return false }
        return contentGate.permits(permit, currentTarget: captured, currentContexts: identities,
            sessionPermits: live.permits(captured, selected: focusedID, selection: selection, now: now))
    }
    func selectPresentation(_ choice: IslandPresentation) {
        presentation = choice; defaults.set(choice.rawValue, forKey: "islandPresentation"); interact()
    }
    func selectDisplay(_ choice: IslandDisplayChoice) {
        displayChoice = choice; defaults.set(choice.rawValue, forKey: "islandDisplay")
    }
    func tick(hovering: Bool, moved: Bool) {
        if live.expire(now: now) {
            liveTask?.cancel(); invalidateMutation(); clearSelection(); contexts = []; expanded.reconcile(currentContexts: [], hasActivity: false, now: now); _ = expanded.close(now: now)
            connectionMessage = LiveError.stale.localizedDescription; connectionError = true; releaseClient()
        }
        interaction.update(now: now)
        if let deadline = noteDeadline, now >= deadline { noteDeadline = nil; close() }
        expanded.tick(now: now, isHovering: hovering, mouseMoved: moved)
        _ = expanded.takeExpiredCompletions()
        syncDesktopAlerts()
        if transfer.invalidateIfNeeded(access: fileAccess) { uploadTask?.cancel(); attachments = []; uploadPrompt = "" }
        if mode != expanded.mode {
            if expanded.mode == .peek { interaction.greet(now: now) }
            else if expanded.mode == .expanded { sounds?.play(.open) }
            else if mode == .expanded { sounds?.play(.close) }
        }
        if mode != expanded.mode { mode = expanded.mode }
        if abs(countdown - expanded.countdownFraction) > 0.005 { countdown = expanded.countdownFraction }
    }
    func open() { navigate(contexts.isEmpty ? .empty : .overview) }
    func close() { cancelDictation(); _ = expanded.close(now: now); mode = expanded.mode }
    func interact() { expanded.interact(now: now) }
    func focus(_ identity: ProductContextIdentity) {
        guard identities.contains(identity) else { return }
        focus(identity.contextID)
    }
    func focus(_ row: LiveContext) {
        guard contexts.contains(where: { $0.id == row.id && $0.incarnation == row.incarnation }) else { return }
        focus(row.id)
    }
    func focus(_ id: String) {
        pendingCreatedID = nil
        guard id != focusedID, contexts.contains(where: { $0.id == id }) else { return }
        invalidateMutation(); clearSelection(); focusedID = id
        if let identity = focusedIdentity { _ = contentGate.select(identity, target: target, currentContexts: identities) }
        interact(); refreshSelectedChat()
    }
    private func clearSelection() {
        cancelDictation(); stagingID = nil; modelReadID = nil; modelPresets = nil; modelPresetTarget = nil
        islandEditing = false; islandComposerEditing = false
        detailID = UUID(); detailTask?.cancel(); detailTask = nil; contentGate.clear(); selection = UUID(); focusedID = ""
        uploadTask?.cancel(); _ = transfer.invalidateIfNeeded(access: nil); attachments = []; uploadPrompt = ""
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
        mutationID = nil; stagingID = nil
        mutationTask?.cancel(); mutationTask = nil; uploadTask?.cancel(); uploadTask = nil; mutationBusy = false
    }
    func disconnectLive() {
        liveTask?.cancel(); liveTask = nil
        invalidateMutation()
        clearSelection(); releaseClient(); live.clear(); contexts = []; drafts = [:]; pendingCreatedID = nil; recentEvents = []; syncDesktopAlerts()
        expanded.reconcile(currentContexts: [], hasActivity: false, now: now); syncDesktopAlerts(); _ = expanded.close(now: now); connectedOrigin = ""; supportsActions = false; supportsUploads = false
        connectionMessage = "Disconnected. Your saved server and account are unchanged."; connectionError = false
    }
    func connectLive(password: String, savePassword: Bool, testOnly: Bool = false) {
        guard !connecting else { return }
        disconnectLive()
        let generation = live.begin()
        do {
            let origin = try LiveOrigin(connectionURL)
            let username = connectionUsername
            let credential = password.isEmpty ? (try NotchKeychain.read(origin: origin.url.absoluteString, username: username) ?? "") : password
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
                    self.supportsActions = status.capabilities?.contains("incarnation_actions") == true
                    self.supportsUploads = status.capabilities?.contains("attachments") == true
                    self.loadPreferences(origin: origin.url.absoluteString, account: username)
                    var envelope = try await connection.exchange(action: "connect", clientID: id)
                    while !Task.isCancelled {
                        let oldRows = self.contexts
                        guard try self.live.accept(envelope, generation: generation, now: self.now) else { return }
                        self.contexts = self.live.contexts.sorted {
                            let a = $0.last_activity_at ?? 0, b = $1.last_activity_at ?? 0
                            return a == b ? $0.id < $1.id : a > b
                        }
                        for row in oldRows where !self.contexts.contains(where: { $0.id == row.id && $0.incarnation == row.incarnation }) {
                            self.drafts.removeValue(forKey: row.id)
                            if self.focusedID == row.id { self.invalidateMutation(); self.clearSelection() }
                        }
                        try self.preferences.reconcile(discoveredContextIDs: self.contexts.map(\.id))
                        self.savePreferences()
                        self.expanded.reconcile(currentContexts: self.identities, hasActivity: self.contexts.contains { $0.running }, now: self.now)
                        self.processEvents(envelope.events ?? [])
                        self.connectionMessage = self.supportsActions ? "Connected · \(self.contexts.count) chats · refreshed automatically" : "Connected read-only. Update the plugin to enable exact-target actions."
                        if let created = self.pendingCreatedID, self.contexts.contains(where: { $0.id == created }) {
                            self.pendingCreatedID = nil
                            if self.creationSelection == self.selection { self.focus(created) }
                        } else if !self.contexts.contains(where: { $0.id == self.focusedID }) {
                            if !self.focusedID.isEmpty { self.clearSelection() }
                        }
                        if self.detailTask == nil { self.refreshSelectedChat() }
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                        envelope = try await connection.exchange(action: "poll", clientID: id, epoch: self.live.epoch, cursor: self.live.cursor)
                    }
                } catch {
                    guard self.live.generation == generation else { return }
                    self.invalidateMutation(); self.live.fail(generation: generation); self.clearSelection(); self.contexts = []; self.expanded.reconcile(currentContexts: [], hasActivity: false, now: self.now); _ = self.expanded.close(now: self.now)
                    self.connectionMessage = (error as? NotchKeychain.Failure)?.localizedDescription ?? (error as? LiveError)?.localizedDescription ?? "Connection interrupted. Reconnect explicitly."
                    self.connectionError = true; self.releaseClient()
                }
            }
        } catch {
            live.fail(generation: generation); connectionError = true
            connectionMessage = (error as? NotchKeychain.Failure)?.localizedDescription ?? (error as? LiveError)?.localizedDescription ?? "Connection unavailable."
        }
    }
    func refreshSelectedChat() {
        guard detailTask == nil, let connection = client, permits(target) else { return }
        let captured = target, readID = UUID(); detailID = readID
        detailTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.detailID == readID { self.detailTask = nil } }
            do {
                let snapshot = try await connection.recentSnapshot(context: captured.context, incarnation: captured.incarnation)
                guard self.detailID == readID, self.permits(captured), !Task.isCancelled else { return }
                if self.chatSnapshot?.log_guid != snapshot.log_guid { self.lastResponse = "" }
                self.chatSnapshot = snapshot; self.detailAccepted = self.now
                if let response = snapshot.lastResponse { self.lastResponse = response }
                self.chatMessage = "Recent activity · updated just now"
            } catch {
                guard self.detailID == readID, self.permits(captured), !Task.isCancelled else { return }
                self.detailAccepted = nil; self.chatMessage = "Recent activity unavailable. Actions disabled until this chat refreshes."
                if error as? LiveError == .authentication { self.disconnectLive(); self.connectionError = true; self.connectionMessage = LiveError.authentication.localizedDescription }
            }
        }
    }
    enum Action { case send, pause(Bool), stop }
    func perform(_ action: Action, target captured: ChatTarget) {
        guard canMutate, permits(captured), let connection = client else { return }
        cancelDictation()
        let text = draft
        if case .send = action {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64 * 1024 else { return }
        }
        detailID = UUID(); detailTask?.cancel(); detailTask = nil
        let owner = UUID(); mutationID = owner
        mutationBusy = true; mutationMessage = "Checking selected chat…"
        mutationTask = Task { [weak self] in
            guard let self else { return }
            var dispatched = false
            defer { if self.mutationID == owner { self.mutationBusy = false; self.mutationTask = nil; self.mutationID = nil } }
            do {
                // Preflight preserves local selection intent; the plugin revalidates target identity at dispatch.
                let status = try await connection.status()
                guard status.server_epoch == self.live.epoch, status.contexts.contains(where: { $0.id == captured.context && $0.incarnation == captured.incarnation }) else { throw LiveError.stale }
                _ = try await connection.snapshot(context: captured.context, logFrom: 9_007_199_254_740_991, incarnation: captured.incarnation)
                try Task.checkCancellation()
                guard self.mutationID == owner, self.permits(captured) else { throw LiveError.stale }
                dispatched = true; self.mutationMessage = "Sending action…"
                switch action {
                case .send: try await connection.send(context: captured.context, text: text, messageID: UUID(), incarnation: captured.incarnation)
                case .pause(let paused): try await connection.setPaused(context: captured.context, paused: paused, incarnation: captured.incarnation)
                case .stop: try await connection.stop(context: captured.context, incarnation: captured.incarnation)
                }
                guard self.mutationID == owner, self.permits(captured), !Task.isCancelled else { return }
                if case .send = action, self.drafts[captured.context] == text { self.drafts[captured.context] = "" }
                self.mutationMessage = "Action accepted by Agent Zero."
                self.interaction.play(.wink)
                if case .send = action {
                    if let alert = self.expanded.attention.first, alert.id.context.matches(captured) { self.dismissAlert(alert.id) }
                    self.navigate(.working)
                }
                if self.permits(captured) {
                    self.detailAccepted = nil
                    self.refreshSelectedChat()
                }
            } catch {
                guard self.mutationID == owner, self.target == captured else { return }
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
        detailID = UUID(); detailTask?.cancel(); detailTask = nil
        let owner = UUID(); mutationID = owner
        mutationBusy = true; mutationMessage = "Creating a new chat…"
        mutationTask = Task { [weak self] in
            guard let self else { return }
            var dispatched = false
            defer { if self.mutationID == owner { self.mutationBusy = false; self.mutationTask = nil; self.mutationID = nil } }
            do {
                let status = try await connection.status()
                guard self.mutationID == owner, self.live.generation == generation, self.live.isFresh(now: self.now), status.server_epoch == self.live.epoch else { throw LiveError.stale }
                try Task.checkCancellation(); dispatched = true
                _ = try await connection.createChat(id: id)
                guard self.mutationID == owner, self.live.generation == generation, !Task.isCancelled else { return }
                self.pendingCreatedID = id; self.mutationMessage = "Chat created. Waiting for discovery…"
            } catch {
                guard self.mutationID == owner, self.live.generation == generation else { return }
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

extension IslandStore {
    var identities: Set<ProductContextIdentity> {
        Set(contexts.compactMap { row in row.incarnation.map {
            ProductContextIdentity(generation: live.generation, contextID: row.id, incarnation: $0)
        } })
    }
    var focusedIdentity: ProductContextIdentity? { identities.first { $0.contextID == focusedID } }
    var orderedContexts: [LiveContext] {
        preferences.orderedAvailableContextIDs.compactMap { id in contexts.first { $0.id == id } }
    }
    var pinnedContexts: [LiveContext] {
        let ids = [preferences.mainContextID].compactMap { $0 } + preferences.pinnedContextIDs
        return ids.compactMap { id in contexts.first { $0.id == id } }
    }
    func name(_ row: LiveContext) -> String { preferences.displayName(for: row.id, discoveredName: row.name) }
    func color(_ row: LiveContext) -> Color {
        guard row.state == .idle || row.state == .paused,
              let hex = preferences.preference(for: row.id)?.colorHex,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return row.activity.color }
        return Color(hex: value)
    }
    func loadPreferences(origin: String, account: String) {
        let scope = Data((origin + "\u{0}" + account).utf8)
        preferenceKey = "contexts.v1." + SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        let value = defaults.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(ContextPreferences.Persistence.self, from: $0) }
        preferences = ContextPreferences(persistence: value ?? .init())
        loadDictationPreferences()
    }
    func savePreferences() {
        guard !preferenceKey.isEmpty else { return }
        let saved = defaults.data(forKey: preferenceKey).flatMap {
            try? JSONDecoder().decode(ContextPreferences.Persistence.self, from: $0)
        }
        guard saved != preferences.persistence else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(preferences.persistence) else { return }
        defaults.set(data, forKey: preferenceKey)
    }
    func updatePreference(_ update: (inout ContextPreferences) throws -> Void) {
        do { try update(&preferences); savePreferences() }
        catch { mutationMessage = "Preference not saved. Use a unique main context, at most four pins, an alias up to 80 characters, and #RRGGBB colors." }
    }
    func navigate(_ view: ExpandedPresentationModel.View) {
        if view != .prompt { cancelDictation() }
        noteDeadline = view == .note ? now + 2 : nil
        _ = expanded.open(view, context: focusedIdentity, now: now); mode = expanded.mode
        if view == .prompt { islandEditing = true; composerRequested = UUID(); focusComposer() }
        else if view == .upload { islandEditing = true; focusComposer() }
        else { islandEditing = false; islandComposerEditing = false }
        if view == .result { interaction.play(.proud) }
    }
    func processEvents(_ events: [LiveEvent]) {
        recentEvents = (recentEvents + events).filter { event in
            identities.contains { $0.contextID == event.context_id && $0.incarnation == event.incarnation }
        }.suffix(64).map { $0 }
        for event in events {
            guard let identity = identities.first(where: { $0.contextID == event.context_id && $0.incarnation == event.incarnation }) else { continue }
            let id = ProductEventIdentity(context: identity, eventID: "\(live.epoch ?? ""):\(event.sequence)")
            if autoOpenEvents {
                if event.kind == "error" || event.kind == "intervention" {
                    let kind: AttentionQueue.Kind = event.kind == "error" ? .error : .intervention
                    if expanded.enqueueAttention(.init(id: id, kind: kind), now: now) == .accepted {
                        sounds?.play(kind == .error ? .error : .attention)
                    }
                } else if event.kind == "finished", expanded.enqueueCompletion(id, now: now) {
                    sounds?.play(.finish)
                }
            }
            if identity == focusedIdentity {
                desktop?.agentActivity(state: characterState, tint: tint, happy: event.kind == "finished")
            }
        }
        syncDesktopAlerts()
        mode = expanded.mode
    }
    func syncDesktopAlerts() {
        // Reconcile exact IDs, including removals/replacements/disconnects.
        let next = Set(expanded.attention.entries.map { $0.id.eventID })
        for id in desktopAlertIDs.subtracting(next) { desktop?.resolveAlert(id: id) }
        for id in next.subtracting(desktopAlertIDs) { desktop?.beginAlert(id: id) }
        desktopAlertIDs = next
    }
    func dismissAlert(_ id: ProductEventIdentity) {
        _ = expanded.resolveAttention(id, now: now); syncDesktopAlerts(); mode = expanded.mode
    }
    func viewAlert(_ entry: AttentionQueue.Entry) {
        guard identities.contains(entry.id.context) else { return }
        focus(entry.id.context.contextID) // explicit user click is the only content-fetch grant
        if entry.kind == .intervention { islandEditing = true; composerRequested = UUID(); focusComposer() }
    }
    var characterState: ZeroCharacterState {
        if interaction.dizzy { return .dizzy }
        if let alert = expanded.attention.first, alert.id.context == focusedIdentity {
            return alert.kind == .error ? .error : .waiting
        }
        switch focused?.state {
        case .thinking: return .thinking
        case .working: return .working
        case .browsing: return .searching
        case .delegating: return .delegating
        case .finished: return .finished
        case .error: return .error
        default: return .idle // paused is not a question or request for input
        }
    }
    func toggleSound() { sounds?.toggleMute(); soundMuted = sounds?.isMuted ?? true }
    func setVolume(_ value: Double) { sounds?.setVolume(value); soundVolume = sounds?.volume ?? value }
    func cycleContext(_ delta: Int) {
        let rows = orderedContexts
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == focusedID } ?? (delta > 0 ? -1 : 0)
        focus(rows[(index + delta + rows.count) % rows.count].id)
    }
    func toggleDesktop() {
        if desktop?.wantsDesktop == true { desktop?.flyHome() }
        else { desktop?.show(at: NSEvent.mouseLocation) }
    }
    func attachFrontApplication() {
        // Only application identity is available without Accessibility/Screen Recording.
        // No window title, screenshot, document contents, or automatic send.
        guard focusedIdentity != nil, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            mutationMessage = "Focus another application, then use Attach front app. No permissions are requested."
            return
        }
        let label = app.localizedName ?? "another application"
        draft = "\(draft)\(draft.isEmpty ? "" : "\n")Context note: I am working with \(label)."
        sounds?.play(.attach); navigate(.prompt)
    }
    var fileAccess: FileTransferState.Access? {
        guard let identity = focusedIdentity else { return nil }
        return .init(target: target, context: identity, isPermitted: permits(target))
    }
    func pickFiles() {
        guard canMutate, supportsUploads else { return }
        let captured = target
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowsMultipleSelection = true; picker.resolvesAliases = false
        picker.prompt = "Stage files"
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                guard let self, self.permits(captured) else { return }
                self.stageFiles(picker.urls, target: captured)
            }
        }
    }
    func stageFiles(_ urls: [URL], target captured: ChatTarget) {
        guard canMutate, supportsUploads, permits(captured), transfer.phase != .uploading, !stagingReading else { return }
        let revision = UUID(); stagingID = revision; stagingReading = true
        Task { [weak self] in
            defer { self?.stagingReading = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    guard (1...8).contains(urls.count) else { throw LiveError.invalidPayload }
                    var remaining = 16 * 1024 * 1024 - 64 * 1024 - 16 * 1024
                    var prepared: [LiveAttachment] = []
                    for url in urls {
                        try Task.checkCancellation()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let file = try LiveAttachment(url: url, remainingBytes: remaining)
                        remaining -= file.data.count
                        prepared.append(file)
                    }
                    return prepared
                }.value
                guard let self, self.stagingID == revision, self.canMutate, self.permits(captured) else { return }
                let files = try zip(urls, prepared).map { try FileTransferState.File(id: UUID(), url: $0.0, byteCount: Int64($0.1.data.count)) }
                _ = try self.transfer.stage(files: files, operationID: UUID(), access: self.fileAccess)
                self.stagingID = nil; self.attachments = prepared; self.uploadPrompt = ""; self.navigate(.upload)
            } catch {
                guard let self, self.stagingID == revision, self.permits(captured) else { return }
                self.stagingID = nil
                self.mutationMessage = "Files not staged. Choose 1–8 regular, non-symlink files with safe names: text, PDF, PNG or JPEG; 8 MiB each and under 16 MiB total including message overhead."
            }
        }
    }

    func uploadFiles() {
        guard canMutate, supportsUploads, uploadPrompt.utf8.count <= 64 * 1024, let connection = client, let operation = transfer.operation,
              transfer.start(operation, access: fileAccess) else { return }
        let prepared = attachments, files = transfer.files, text = uploadPrompt
        guard let incarnation = operation.target.incarnation else { return }
        detailID = UUID(); detailTask?.cancel(); detailTask = nil
        let owner = UUID(); mutationID = owner
        mutationBusy = true; navigate(.uploading)
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.mutationID == owner {
                    self.mutationBusy = false; self.mutationID = nil
                    self.attachments = []; self.uploadTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard self.mutationID == owner, self.permits(operation.target) else { throw LiveError.stale }
                let references = try await connection.upload(context: operation.target.context, incarnation: incarnation,
                    files: prepared, text: text, messageID: operation.id)
                guard self.mutationID == owner, self.permits(operation.target), !Task.isCancelled, references.count == files.count else { throw LiveError.stale }
                let delivered = try zip(files, references).map { try FileTransferState.DeliveredFile(fileID: $0.0.id, reference: $0.1) }
                let receipt = try FileTransferState.Receipt(files: delivered)
                guard self.transfer.receive(receipt, operation: operation, access: self.fileAccess) else { return }
                self.uploadPrompt = ""; self.navigate(.choose); self.interaction.play(.content)
                self.refreshSelectedChat()
            } catch {
                guard self.mutationID == owner, self.target == operation.target else { return }
                if error is UploadPreparationError {
                    _ = self.transfer.fail(.definite("Upload not sent: local preparation failed."), operation: operation, access: self.fileAccess)
                    self.uncertainOutcome = false; self.mutationMessage = "Upload not sent: local preparation failed."
                    return
                }
                _ = self.transfer.fail(.ambiguous("Delivery outcome unknown. Check this chat in the WebUI before sending again."), operation: operation, access: self.fileAccess)
                self.uncertainOutcome = true
                self.mutationMessage = "Upload outcome unknown. Nothing is retried automatically."
            }
        }
    }
    func cancelUpload() {
        guard uploadTask != nil || stagingID != nil || transfer.phase == .staged else { return }
        if let operation = transfer.operation {
            if transfer.phase == .uploading { uncertainOutcome = true; mutationMessage = "Cancelled locally; delivery may already have occurred. Check the WebUI." }
            _ = transfer.cancel(operation)
        }
        stagingID = nil
        if uploadTask != nil { mutationID = nil; mutationBusy = false }
        uploadTask?.cancel(); uploadTask = nil; attachments = []
    }
    func chooseFiles(_ action: FileTransferState.NextAction) {
        guard let operation = transfer.operation,
              transfer.choose(action, operation: operation, access: fileAccess) != nil else { return }
        if action == .openInChat { showChats() }
        else { draft = "Please explain the files I just sent."; navigate(.prompt) }
    }
}
