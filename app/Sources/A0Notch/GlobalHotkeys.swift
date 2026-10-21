import AppKit
import Carbon
import Foundation

public enum NotchHotkeyAction: String, CaseIterable, Codable, Sendable {
    case toggleIsland, openPrompt, goToAlert, openWebUI, attachWindow
    case nextContext, previousContext, mute, desktopZero, wardrobe
}

public struct NotchHotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
    public static let supported: Self = [.command, .option, .control, .shift]

    public init(eventFlags: NSEvent.ModifierFlags) {
        var result: Self = []
        if eventFlags.contains(.command) { result.insert(.command) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.shift) { result.insert(.shift) }
        self = result
    }
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

/// Physical macOS virtual key codes, not localized characters. Brackets use ANSI positions.
public struct NotchHotkeyChord: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: NotchHotkeyModifiers
    public init(keyCode: UInt32, modifiers: NotchHotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    /// Avoid intercepting ordinary typing and modifier-only keys.
    public var isValid: Bool {
        keyCode < 128 && !(54...63).contains(keyCode)
            && modifiers.subtracting(.supported).isEmpty
            && !modifiers.intersection([.command, .control, .option]).isEmpty
    }
    public var displayName: String {
        let labels: [UInt32: String] = [0: "A", 2: "D", 5: "G", 13: "W", 32: "U",
                                      33: "[", 30: "]", 45: "N", 46: "M", 49: "Space"]
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
            + (labels[keyCode] ?? "Key \(keyCode)")
    }
}

public struct NotchHotkeyBinding: Codable, Equatable, Sendable {
    public let action: NotchHotkeyAction
    public var chord: NotchHotkeyChord
    public var isEnabled: Bool
    public init(action: NotchHotkeyAction, chord: NotchHotkeyChord, isEnabled: Bool) {
        self.action = action
        self.chord = chord
        self.isEnabled = isEnabled
    }
    public static let defaults: [Self] = {
        let keys: [(NotchHotkeyAction, UInt32)] = [(.openPrompt, 49), (.goToAlert, 0),
            (.openWebUI, 32), (.attachWindow, 13), (.nextContext, 30), (.previousContext, 33),
            (.mute, 46), (.desktopZero, 2), (.wardrobe, 5)]
        return [Self(action: .toggleIsland, chord: .init(keyCode: 45, modifiers: [.command, .shift]),
                     isEnabled: false)] + keys.map {
            Self(action: $0.0, chord: .init(keyCode: $0.1, modifiers: [.control, .option]), isEnabled: true)
        }
    }()
}

public enum NotchHotkeyStatus: Equatable, Sendable {
    case disabled, stopped, recording, registered, invalidShortcut
    /// Highlight red; every enabled participant is withheld from registration.
    case internalConflict([NotchHotkeyAction])
    /// Highlight orange. Carbon reports eventHotKeyExistsErr for an owned combination.
    case systemConflict(Int32)
    /// Other Carbon failures are not misrepresented as known keyboard conflicts.
    case registrationFailed(Int32)
}

/// Injectable registrar; use CarbonNotchHotkeyRegistrar in production.
@MainActor
public protocol NotchHotkeyRegistering: AnyObject, Sendable {
    var onAction: ((NotchHotkeyAction) -> Void)? { get set }
    func register(_ binding: NotchHotkeyBinding) -> Int32
    func unregisterAll()
    func shutdown()
}

// Carbon invokes application event handlers on the main event loop. This box is kept alive
// until RemoveEventHandler, and accessed only on that loop (including deferred cleanup).
private final class NotchCarbonCallback: @unchecked Sendable {
    var receive: (@MainActor (UInt32) -> Bool)?
}
private final class NotchCarbonResources: @unchecked Sendable {
    var handler: EventHandlerRef?
    var references: [EventHotKeyRef] = []
    let callback = NotchCarbonCallback()
    @MainActor func clearKeys() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }
    @MainActor func clear() {
        clearKeys()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        callback.receive = nil
    }
}

@MainActor
public final class CarbonNotchHotkeyRegistrar: NotchHotkeyRegistering {
    private static let signature: OSType = 0x41304E48 // A0NH
    private static var nextIdentifier: UInt32 = 0
    private let resources = NotchCarbonResources()
    private var actions: [UInt32: NotchHotkeyAction] = [:]
    public var onAction: ((NotchHotkeyAction) -> Void)?
    public init() {}

    private func installHandler() -> OSStatus {
        if resources.handler != nil { return noErr }
        resources.callback.receive = { [weak self] identifier in
            guard let self, let action = self.actions[identifier] else { return false }
            self.onAction?(action)
            return true
        }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x41304E48 else {
                return OSStatus(eventNotHandledErr)
            }
            let box = Unmanaged<NotchCarbonCallback>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                box.receive?(identifier.id) == true ? noErr : OSStatus(eventNotHandledErr)
            }
        }, 1, &kind, Unmanaged.passUnretained(resources.callback).toOpaque(), &resources.handler)
    }

    public func register(_ binding: NotchHotkeyBinding) -> Int32 {
        guard binding.chord.isValid else { return OSStatus(paramErr) }
        let handlerResult = installHandler()
        guard handlerResult == noErr else { return handlerResult }
        Self.nextIdentifier &+= 1
        let identifier = Self.nextIdentifier
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(binding.chord.keyCode, binding.chord.modifiers.carbonFlags,
                                         EventHotKeyID(signature: Self.signature, id: identifier),
                                         GetApplicationEventTarget(), 0, &reference)
        if result == noErr, let reference {
            resources.references.append(reference)
            actions[identifier] = binding.action
        }
        return result
    }
    public func unregisterAll() { resources.clearKeys(); actions.removeAll() }
    public func shutdown() {
        resources.clear()
        actions.removeAll()
        onAction = nil
    }
    deinit {
        // Deinit is nonisolated in Swift 6; transfer owned resources rather than self.
        let resources = resources
        Task { @MainActor in resources.clear() }
    }
}

private final class NotchRecorderResources: @unchecked Sendable {
    var monitor: Any?
    var resignObserver: NSObjectProtocol?
    var windowObservers: [NSObjectProtocol] = []
    @MainActor func clear() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        monitor = nil
        resignObserver = nil
    }
}

/// No app/store dependencies. Own one instance and route onAction to application commands.
@MainActor
public final class GlobalHotkeys {
    public enum RecordingResult: Equatable, Sendable {
        case saved(NotchHotkeyAction, NotchHotkeyChord, NotchHotkeyStatus)
        case rejected(NotchHotkeyAction, String)
        case cancelled(NotchHotkeyAction)
    }
    public var onAction: ((NotchHotkeyAction) -> Void)?
    public var onChange: (() -> Void)?
    public var onRecordingResult: ((RecordingResult) -> Void)?
    public private(set) var isRunning = false
    public private(set) var recordingAction: NotchHotkeyAction?
    public private(set) var statuses: [NotchHotkeyAction: NotchHotkeyStatus] = [:]
    private var saved: [NotchHotkeyAction: NotchHotkeyBinding]
    private let defaults: UserDefaults
    private let storageKey: String
    private let registrar: any NotchHotkeyRegistering
    private let recorder = NotchRecorderResources()

    /// Construction does not register keys; call start() after the app event loop is ready.
    public init(defaults: UserDefaults = .standard, storageKey: String = "a0_notch.hotkeys.v1",
                registrar: (any NotchHotkeyRegistering)? = nil) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.registrar = registrar ?? CarbonNotchHotkeyRegistrar()
        var values = Dictionary(uniqueKeysWithValues: NotchHotkeyBinding.defaults.map { ($0.action, $0) })
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([NotchHotkeyBinding].self, from: data) {
            for binding in stored where binding.chord.isValid { values[binding.action] = binding }
        }
        saved = values
        self.registrar.onAction = { [weak self] action in
            guard let self, self.isRunning, self.recordingAction == nil,
                  self.statuses[action] == .registered else { return }
            self.onAction?(action)
        }
        refresh()
    }
    public var bindings: [NotchHotkeyBinding] { NotchHotkeyAction.allCases.compactMap { saved[$0] } }
    public func binding(for action: NotchHotkeyAction) -> NotchHotkeyBinding { saved[action]! }
    public func status(for action: NotchHotkeyAction) -> NotchHotkeyStatus { statuses[action] ?? .stopped }

    public func start() { isRunning = true; refresh() }
    /// Releases registrations; retains callbacks and settings so start() can resume.
    public func stop() { isRunning = false; cancelRecording(); refresh() }
    public func setEnabled(_ enabled: Bool, for action: NotchHotkeyAction) {
        saved[action]?.isEnabled = enabled
        persistAndRefresh()
    }
    /// Invalid chords are rejected without replacing the saved binding.
    @discardableResult
    public func setShortcut(_ chord: NotchHotkeyChord, for action: NotchHotkeyAction) -> Bool {
        guard chord.isValid else { return false }
        saved[action]?.chord = chord
        persistAndRefresh()
        return true
    }
    public func resetAll() {
        cancelRecording()
        saved = Dictionary(uniqueKeysWithValues: NotchHotkeyBinding.defaults.map { ($0.action, $0) })
        persistAndRefresh()
    }
    /// Reattempt OS registration after another application releases a conflicting key.
    public func retryRegistration() { refresh() }
    private func persistAndRefresh() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: storageKey) }
        refresh()
    }
    private func refresh() {
        registrar.unregisterAll()
        var next: [NotchHotkeyAction: NotchHotkeyStatus] = [:]
        for binding in bindings {
            let action = binding.action
            if !binding.isEnabled { next[action] = .disabled; continue }
            if !binding.chord.isValid { next[action] = .invalidShortcut; continue }
            let duplicates = bindings.filter {
                $0.action != action && $0.isEnabled && $0.chord == binding.chord
            }.map(\.action)
            if !duplicates.isEmpty { next[action] = .internalConflict(duplicates); continue }
            if recordingAction != nil { next[action] = .recording; continue }
            if !isRunning { next[action] = .stopped; continue }
            let code = registrar.register(binding)
            if code == noErr { next[action] = .registered }
            else if code == OSStatus(eventHotKeyExistsErr) { next[action] = .systemConflict(code) }
            else { next[action] = .registrationFailed(code) }
        }
        statuses = next
        onChange?()
    }

    /// Foreground recorder only; no global keyboard monitor or Accessibility permission.
    /// Escape cancels. Shift-only/unmodified shortcuts are rejected; recording remains open.
    /// A valid chord is saved even if conflicting, so Settings can display the exact conflict.
    public func beginRecording(for action: NotchHotkeyAction, window: NSWindow? = nil) {
        cancelRecording()
        recordingAction = action
        refresh()
        recorder.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.recordingAction != nil else { return false }
                guard let window, event.window === window, window.isKeyWindow else { self.cancelRecording(); return false }
                if event.isARepeat { return true }
                if event.keyCode == UInt16(kVK_Escape) { self.cancelRecording(); return true }
                self.record(keyCode: UInt32(event.keyCode), modifiers: .init(eventFlags: event.modifierFlags))
                return true
            }
            return consumed ? nil : event
        }
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                recorder.windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelRecording() }
                })
            }
        }
        recorder.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }
    /// Supports a custom recorder UI and deterministic tests using the same validation path.
    @discardableResult
    public func record(keyCode: UInt32, modifiers: NotchHotkeyModifiers) -> Bool {
        guard let action = recordingAction else { return false }
        let chord = NotchHotkeyChord(keyCode: keyCode, modifiers: modifiers)
        guard chord.isValid else {
            onRecordingResult?(.rejected(action, "Use Command, Control or Option with a non-modifier key."))
            return false
        }
        recorder.clear()
        recordingAction = nil
        saved[action]?.chord = chord
        persistAndRefresh()
        onRecordingResult?(.saved(action, chord, status(for: action)))
        return true
    }
    public func cancelRecording() {
        guard let action = recordingAction else { return }
        recorder.clear()
        recordingAction = nil
        refresh()
        onRecordingResult?(.cancelled(action))
    }
    /// Final teardown; use stop() when intending to restart the same instance.
    public func shutdown() {
        isRunning = false
        cancelRecording()
        registrar.shutdown()
        refresh()
        onAction = nil
        onChange = nil
        onRecordingResult = nil
    }
    deinit {
        let registrar = registrar
        let recorder = recorder
        Task { @MainActor in recorder.clear(); registrar.shutdown() }
    }
}
