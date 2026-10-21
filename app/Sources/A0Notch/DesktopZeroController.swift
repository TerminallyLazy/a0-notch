import AppKit
import Observation
import SwiftUI

/// A passive desktop companion. The owner supplies island geometry and all app effects.
/// Call shutdown() before releasing it. No IslandStore, audio-player, or transport dependencies.
@MainActor
public final class DesktopZeroController: NSObject {
    public enum ReturnReason: Equatable { case user, alert }
    public enum SoundCue: Equatable { case pop, happy, slap, annoyed, yawn, sleep }
    public enum Interaction: Equatable { case dragBegan, dragEnded, slap, wardrobe, soundToggle }

    public struct Callbacks {
        /// Global AppKit screen coordinates, not island-local or SwiftUI coordinates.
        public var islandFrame: () -> CGRect?
        /// Called after the flight completes (immediately under Reduce Motion).
        public var returnedHome: (ReturnReason) -> Void
        /// True only while a desktop avatar is actually presented, not the persisted desire.
        public var visibilityChanged: (Bool) -> Void
        public var wardrobeRequested: () -> Void
        public var soundToggleRequested: () -> Void
        public var sound: (SoundCue) -> Void
        public var interaction: (Interaction) -> Void

        public init(islandFrame: @escaping () -> CGRect?,
                    returnedHome: @escaping (ReturnReason) -> Void = { _ in },
                    visibilityChanged: @escaping (Bool) -> Void = { _ in },
                    wardrobeRequested: @escaping () -> Void = {},
                    soundToggleRequested: @escaping () -> Void = {},
                    sound: @escaping (SoundCue) -> Void = { _ in },
                    interaction: @escaping (Interaction) -> Void = { _ in }) {
            self.islandFrame = islandFrame
            self.returnedHome = returnedHome
            self.visibilityChanged = visibilityChanged
            self.wardrobeRequested = wardrobeRequested
            self.soundToggleRequested = soundToggleRequested
            self.sound = sound
            self.interaction = interaction
        }
    }

    public private(set) var isVisible = false
    public var wantsDesktop: Bool { lifecycle.desired }
    public var isSleeping: Bool { lifecycle.sleeping }
    public var isSuspended: Bool { lifecycle.suspended }
    public var frame: CGRect { panel.frame }
    /// Controller sampling cadence, not a claim about the renderer's internal TimelineView.
    public var framesPerSecond: Int { cadence }

    private let panel: DesktopZeroPanel
    private let render = DesktopZeroRenderState()
    private let defaults: UserDefaults
    private var callbacks: Callbacks
    private var lifecycle: DesktopZeroLifecycle
    private let resources = DesktopZeroResources()
    private var stopped = false
    private var started = false
    private var savedOrigin: CGPoint
    private var pointerDown: CGPoint?
    private var pointerOrigin: CGPoint = .zero
    private var dragging = false
    private var clickDeadline: TimeInterval?
    private var emoteDeadline: TimeInterval?
    private var flight: Flight?
    private var cadence = 0
    private var agentState: ZeroCharacterState = .idle
    private var agentHappy = false

    private struct Flight {
        let start: TimeInterval
        let origin: CGPoint
        let destination: CGPoint
        let reason: ReturnReason
    }

    /// Construction is side-effect-free with respect to window visibility and observers.
    /// Call start() once ready. Missing position uses the main display's bottom-right corner.
    public init(wardrobe: ZeroWardrobe, defaults: UserDefaults = .standard,
                tint: Color = .white, callbacks: Callbacks) {
        self.defaults = defaults
        self.callbacks = callbacks
        lifecycle = DesktopZeroLifecycle(desired: defaults.bool(forKey: "zeroOnDesktop"),
                                         now: ProcessInfo.processInfo.systemUptime)
        let fallback = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let x = (defaults.object(forKey: "desktopZeroX") as? NSNumber)?.doubleValue
        let y = (defaults.object(forKey: "desktopZeroY") as? NSNumber)?.doubleValue
        let proposed = CGPoint(x: x ?? Double(fallback.maxX - 144), y: y ?? Double(fallback.minY + 24))
        savedOrigin = DesktopZeroGeometry.clamp(proposed, to: Self.visibleFrames)
        panel = DesktopZeroPanel(contentRect: CGRect(origin: savedOrigin, size: DesktopZeroGeometry.size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init()
        render.tint = tint
        panel.title = "Zero on the desktop"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let surface = DesktopZeroSurface(frame: CGRect(origin: .zero, size: DesktopZeroGeometry.size))
        surface.controller = self
        let hosting = NSHostingView(rootView: DesktopZeroContent(render: render, wardrobe: wardrobe))
        hosting.sizingOptions = []
        hosting.frame = surface.bounds
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.button)
        surface.setAccessibilityLabel("Zero desktop companion")
        surface.setAccessibilityHelp("Return Zero to the notch, change wardrobe, or toggle sound.")
        surface.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Return to notch", handler: { [weak self] in self?.accessibleReturn() ?? false }),
            NSAccessibilityCustomAction(name: "Wardrobe", handler: { [weak self] in self?.accessibleWardrobe() ?? false }),
            NSAccessibilityCustomAction(name: "Toggle sound", handler: { [weak self] in self?.accessibleSound() ?? false })
        ])
        panel.contentView = surface
    }

    public func start() {
        guard !started, !stopped else { return }
        started = true
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSuspension("screen", active: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSuspension("screen", active: false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSuspension("system", active: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSuspension("system", active: false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSuspension("session", active: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSuspension("session", active: false) }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.setSuspension("lock", active: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspension("lock", active: false) }
        reconcile()
    }

    /// Install from an island drag/drop. `center` is a global screen point.
    /// The desired preference is persisted even when an alert currently prevents presentation.
    public func show(at center: CGPoint? = nil) {
        guard !stopped else { return }
        if let center, center.x.isFinite, center.y.isFinite {
            savedOrigin = DesktopZeroGeometry.clamp(CGPoint(x: center.x - 60, y: center.y - 60), to: Self.visibleFrames)
            persistPosition()
        }
        lifecycle.setDesired(true)
        defaults.set(true, forKey: "zeroOnDesktop")
        flight = nil
        setEmote(.surprised, duration: 0.6)
        panel.alphaValue = 1
        panel.setFrameOrigin(savedOrigin)
        callbacks.sound(.pop)
        callbacks.sound(.happy)
        if !started { start() } else { reconcile() }
    }

    /// An explicit return clears the preference; alert-driven returns never do.
    public func flyHome() {
        guard !stopped else { return }
        lifecycle.setDesired(false)
        defaults.set(false, forKey: "zeroOnDesktop")
        beginFlight(reason: .user)
    }

    /// Caller forwards real agent activity; ongoing work should keep forwarding activity pulses.
    public func agentActivity(state: ZeroCharacterState, tint: Color? = nil, happy: Bool = false) {
        guard !stopped else { return }
        lifecycle.activity(now: now)
        agentState = state
        agentHappy = happy || state == .finished
        if let tint { render.tint = tint }
        render.state = state
        render.happy = agentHappy
        reconcile()
    }

    /// Use unique IDs for overlapping intervention/error alerts. Repeated IDs are idempotent.
    public func beginAlert(id: String) {
        guard !stopped else { return }
        let first = lifecycle.beginAlert(id: id, now: now)
        if first {
            cancelPointer()
            setEmote(.surprised, duration: 0.45)
        }
        reconcile()
    }

    public func resolveAlert(id: String) {
        guard !stopped else { return }
        lifecycle.resolveAlert(id: id)
        if lifecycle.alerts.isEmpty {
            if flight?.reason == .alert {
                flight = nil
                panel.alphaValue = 1
                panel.setFrameOrigin(savedOrigin)
            }
            render.emote = nil
            emoteDeadline = nil
        }
        reconcile()
    }

    /// Releases timers, notification registrations, pending input, and the panel. Idempotent.
    /// Shutdown preserves preferences so the next launch can restore the desktop companion.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        cancelPointer()
        flight = nil
        resources.cancel()
        cadence = 0
        render.paused = true
        setVisible(false)
        panel.contentView = nil
        panel.close()
        callbacks = Callbacks(islandFrame: { nil })
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static var visibleFrames: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (DesktopZeroController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.stopped { action(self) } }
        }
        resources.observers.append((center, token))
    }

    private func setSuspension(_ reason: String, active: Bool) {
        if active { lifecycle.suspensions.insert(reason) } else { lifecycle.suspensions.remove(reason) }
        if active { cancelPointer() }
        if !lifecycle.suspended && lifecycle.retractIfDue(now: now) {
            // An alert that matured while locked must not flash the desktop on wake.
            completeFlight(reason: .alert)
        }
        reconcile()
    }

    private func screensChanged() {
        savedOrigin = DesktopZeroGeometry.clamp(savedOrigin, to: Self.visibleFrames)
        persistPosition()
        cancelPointer()
        if flight == nil { panel.setFrameOrigin(savedOrigin) }
        reconcile()
    }

    private func persistPosition() {
        defaults.set(Double(savedOrigin.x), forKey: "desktopZeroX")
        defaults.set(Double(savedOrigin.y), forKey: "desktopZeroY")
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
        callbacks.visibilityChanged(visible)
    }

    private func reconcile() {
        guard started, !stopped else { return }
        let presenting = !lifecycle.suspended && (lifecycle.presentable || flight != nil)
        render.paused = !presenting
        render.sleeping = lifecycle.sleeping
        render.state = lifecycle.sleeping ? .sleeping : agentState
        render.happy = agentHappy
        if presenting && !isVisible && flight == nil {
            panel.setFrameOrigin(savedOrigin)
            updateHitTesting(cursor: NSEvent.mouseLocation)
        }
        setVisible(presenting)
        let wantedCadence = lifecycle.suspended ? 0 : ((flight != nil || lifecycle.alertDeadline != nil) ? 30 : lifecycle.framesPerSecond)
        guard wantedCadence != cadence else { return }
        resources.timer?.invalidate()
        resources.timer = nil
        cadence = wantedCadence
        guard cadence > 0 else { return }
        let timer = Timer(timeInterval: 1 / Double(cadence), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        resources.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard !stopped, !lifecycle.suspended else { return }
        let time = now
        let cursor = NSEvent.mouseLocation
        if lifecycle.retractIfDue(now: time) { beginFlight(reason: .alert) }
        if let flight {
            let progress = min(1, max(0, (time - flight.start) / 0.42))
            let eased = progress * progress * (3 - 2 * progress)
            panel.setFrameOrigin(CGPoint(x: flight.origin.x + (flight.destination.x - flight.origin.x) * eased,
                                         y: flight.origin.y + (flight.destination.y - flight.origin.y) * eased))
            panel.alphaValue = 1 - eased
            if progress >= 1 { completeFlight(reason: flight.reason) }
        }
        if let deadline = clickDeadline, time >= deadline {
            clickDeadline = nil
            setEmote(.annoyed, duration: 0.8)
            callbacks.interaction(.slap)
            callbacks.sound(.slap)
            callbacks.sound(.annoyed)
        }
        if let deadline = emoteDeadline, time >= deadline { render.emote = nil; emoteDeadline = nil }
        let distance = hypot(cursor.x - panel.frame.midX, cursor.y - panel.frame.midY)
        let wasSleeping = lifecycle.sleeping
        lifecycle.updateSleep(now: time, cursorDistance: distance, interacting: dragging || pointerDown != nil)
        if lifecycle.sleeping && !wasSleeping {
            setEmote(.yawn, duration: 0.8)
            callbacks.sound(.yawn)
            callbacks.sound(.sleep)
        }
        if !lifecycle.sleeping {
            render.gaze = CGPoint(x: tanh((cursor.x - panel.frame.midX) / 260),
                                  y: tanh((panel.frame.midY - cursor.y) / 200))
        }
        updateHitTesting(cursor: cursor)
        reconcile()
    }

    private func updateHitTesting(cursor: CGPoint) {
        panel.ignoresMouseEvents = flight != nil || (!dragging && pointerDown == nil && !DesktopZeroGeometry.bodyContains(cursor, frame: panel.frame))
    }

    private func setEmote(_ emote: ZeroEmote, duration: TimeInterval) {
        render.emote = emote
        emoteDeadline = now + duration
    }

    private func beginFlight(reason: ReturnReason) {
        cancelPointer()
        guard started, isVisible, !lifecycle.suspended,
              let destination = callbacks.islandFrame(), !destination.isEmpty,
              destination.midX.isFinite, destination.midY.isFinite,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completeFlight(reason: reason)
            return
        }
        flight = Flight(start: now, origin: panel.frame.origin,
                        destination: CGPoint(x: destination.midX - 60, y: destination.midY - 60), reason: reason)
        panel.ignoresMouseEvents = true
        reconcile()
    }

    private func completeFlight(reason: ReturnReason) {
        flight = nil
        setVisible(false)
        panel.alphaValue = 1
        callbacks.returnedHome(reason)
        reconcile()
    }

    fileprivate func mouseDown(_ event: NSEvent) {
        guard !stopped, flight == nil, lifecycle.alerts.isEmpty else { return }
        if event.clickCount >= 2 {
            clickDeadline = nil
            flyHome()
            return
        }
        pointerDown = NSEvent.mouseLocation
        pointerOrigin = panel.frame.origin
        lifecycle.wake()
        reconcile()
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        guard let down = pointerDown else { return }
        let cursor = NSEvent.mouseLocation
        let delta = CGPoint(x: cursor.x - down.x, y: cursor.y - down.y)
        if !dragging && DesktopZeroGeometry.crossesDragThreshold(delta) {
            dragging = true
            clickDeadline = nil
            setEmote(.surprised, duration: 60)
            callbacks.interaction(.dragBegan)
            callbacks.sound(.pop)
        }
        guard dragging else { return }
        panel.ignoresMouseEvents = false
        // Keep the pointer offset from mouse-down; no jump to the cursor center.
        panel.setFrameOrigin(DesktopZeroGeometry.clamp(CGPoint(x: pointerOrigin.x + delta.x,
                                                             y: pointerOrigin.y + delta.y), to: Self.visibleFrames))
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        guard pointerDown != nil else { return }
        pointerDown = nil
        if dragging {
            dragging = false
            render.emote = nil
            emoteDeadline = nil
            savedOrigin = DesktopZeroGeometry.clamp(panel.frame.origin, to: Self.visibleFrames)
            persistPosition()
            callbacks.interaction(.dragEnded)
            if callbacks.islandFrame()?.contains(NSEvent.mouseLocation) == true { flyHome() }
        } else {
            // AppKit double-click interval prevents a double click from also becoming a slap.
            clickDeadline = now + NSEvent.doubleClickInterval
        }
        updateHitTesting(cursor: NSEvent.mouseLocation)
    }

    private func cancelPointer() {
        let wasDragging = dragging
        pointerDown = nil
        dragging = false
        clickDeadline = nil
        if wasDragging {
            savedOrigin = DesktopZeroGeometry.clamp(panel.frame.origin, to: Self.visibleFrames)
            persistPosition()
            render.emote = nil
            emoteDeadline = nil
            callbacks.interaction(.dragEnded)
        }
    }

    fileprivate func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Zero")
        for (title, action) in [("Return to notch", #selector(menuReturn)),
                                ("Wardrobe…", #selector(menuWardrobe)),
                                ("Toggle sound", #selector(menuSound))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuReturn() { flyHome() }
    @objc private func menuWardrobe() { requestWardrobe() }
    @objc private func menuSound() { requestSoundToggle() }
    @objc fileprivate func accessibleReturn() -> Bool { guard !stopped else { return false }; flyHome(); return true }
    @objc private func accessibleWardrobe() -> Bool { guard !stopped else { return false }; requestWardrobe(); return true }
    @objc private func accessibleSound() -> Bool { guard !stopped else { return false }; requestSoundToggle(); return true }
    private func requestWardrobe() {
        guard !stopped else { return }
        callbacks.interaction(.wardrobe)
        callbacks.wardrobeRequested()
    }
    private func requestSoundToggle() {
        guard !stopped else { return }
        callbacks.interaction(.soundToggle)
        callbacks.soundToggleRequested()
    }
}

@MainActor
private final class DesktopZeroPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DesktopZeroSurface: NSView {
    weak var controller: DesktopZeroController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Child SwiftUI content is drawing-only. The native surface owns pointer dispatch.
        DesktopZeroGeometry.bodyContains(point, frame: frame) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu() }
    override func accessibilityPerformPress() -> Bool { controller?.accessibleReturn() ?? false }
}

@MainActor @Observable
private final class DesktopZeroRenderState {
    var tint: Color = .white
    var gaze: CGPoint = .zero
    var state: ZeroCharacterState = .idle
    var emote: ZeroEmote?
    var happy = false
    var sleeping = false
    var paused = true
}

@MainActor
private struct DesktopZeroContent: View {
    let render: DesktopZeroRenderState
    let wardrobe: ZeroWardrobe
    var body: some View {
        // The external clock owns both cadences; frameTime disables ZeroView's internal
        // schedule while animated:true preserves breathing, blink and particle motion.
        TimelineView(.animation(minimumInterval: render.sleeping ? 0.1 : 1.0 / 30,
                                paused: render.paused)) { timeline in
            ZeroView(tint: render.tint, gaze: render.gaze,
                     animated: true, happy: render.happy,
                     state: render.state, emote: render.emote,
                     outfit: wardrobe.resolved(at: timeline.date), paused: render.paused,
                     frameTime: timeline.date.timeIntervalSinceReferenceDate)
                .frame(width: 120, height: 120)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Resource bag is mutated only on the main actor; teardown may run during deinitialization.
/// Timers never strongly retain the controller. NotificationCenter removal is thread-safe.
private final class DesktopZeroResources: @unchecked Sendable {
    var timer: Timer?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    func cancel() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
    deinit { cancel() }
}

/// Pure helpers shared with the standalone executable tests, not an application store.
enum DesktopZeroGeometry {
    static let size = CGSize(width: 120, height: 120)
    static func crossesDragThreshold(_ delta: CGPoint) -> Bool { hypot(delta.x, delta.y) > 7 }
    static func bodyContains(_ point: CGPoint, frame: CGRect) -> Bool {
        hypot(point.x - frame.midX, point.y - frame.midY) <= min(frame.width, frame.height) * 0.24
    }
    /// The entire panel is bounded by the selected visibleFrame expanded by 24 points.
    /// Nearest-display selection handles negative origins, gaps, and disconnected displays.
    static func clamp(_ origin: CGPoint, to frames: [CGRect]) -> CGPoint {
        let finite = CGPoint(x: origin.x.isFinite ? origin.x : 0, y: origin.y.isFinite ? origin.y : 0)
        guard !frames.isEmpty else { return finite }
        let center = CGPoint(x: finite.x + 60, y: finite.y + 60)
        let valid = frames.filter { !$0.isEmpty && $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite }
        let selected = valid.min { distance(center, to: $0) < distance(center, to: $1) }
        guard let selected else { return finite }
        let bounds = selected.insetBy(dx: -24, dy: -24)
        return CGPoint(x: min(max(finite.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                       y: min(max(finite.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }
    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
              max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}

struct DesktopZeroLifecycle {
    private(set) var desired: Bool
    private(set) var alerts: Set<String> = []
    private(set) var alertDeadline: TimeInterval?
    private(set) var retracted = false
    private(set) var sleeping = false
    private(set) var lastActivity: TimeInterval
    var suspensions: Set<String> = []
    var suspended: Bool { !suspensions.isEmpty }
    var presentable: Bool { desired && !retracted }
    var framesPerSecond: Int { suspended || !presentable ? 0 : (sleeping ? 10 : 30) }

    init(desired: Bool, now: TimeInterval) { self.desired = desired; lastActivity = now }
    mutating func setDesired(_ value: Bool) {
        desired = value
        sleeping = false
        if value && !alerts.isEmpty { retracted = true; alertDeadline = nil }
    }
    mutating func wake() { sleeping = false }
    mutating func activity(now: TimeInterval) { lastActivity = now; sleeping = false }
    mutating func beginAlert(id: String, now: TimeInterval) -> Bool {
        let first = alerts.isEmpty
        guard alerts.insert(id).inserted else { return false }
        sleeping = false
        if first { alertDeadline = now + 0.45 }
        return first
    }
    mutating func resolveAlert(id: String) {
        guard alerts.remove(id) != nil else { return }
        if alerts.isEmpty { alertDeadline = nil; retracted = false }
    }
    mutating func retractIfDue(now: TimeInterval) -> Bool {
        guard let deadline = alertDeadline, now >= deadline else { return false }
        alertDeadline = nil
        retracted = true
        return desired
    }
    mutating func updateSleep(now: TimeInterval, cursorDistance: CGFloat, interacting: Bool) {
        sleeping = presentable && !suspended && alerts.isEmpty && !interacting
            && now - lastActivity >= 120 && cursorDistance > 150
    }
}
