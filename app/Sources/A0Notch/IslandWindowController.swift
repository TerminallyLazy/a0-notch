import AppKit
import SwiftUI
import NotchCore

final class IslandPanel: NSPanel {
    // Text input lives in the explicitly opened chat window, never the passive island.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandWindowController {
    let store: IslandStore
    let panel: IslandPanel
    private var timer: Timer?
    private var eventMonitor: Any?
    private var currentDisplay: DisplayDescriptor?
    private var lastMouse = NSEvent.mouseLocation
    private var animationStart = 0.0
    private var animationFrom: IslandGeometry?
    private var animationTarget: IslandGeometry?
    private var opening = false
    private var suspended = false

    init(store: IslandStore) {
        self.store = store
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "a0_notch — Agent Zero"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: IslandView(store: store))
        hosting.sizingOptions = []
        panel.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep),
                                                          name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
                                                          name: NSWorkspace.screensDidWakeNotification, object: nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel && event.type == .keyDown && event.keyCode == 53 {
                self.store.close()
                return nil
            }
            if event.window === self.panel { self.store.interact() }
            return event
        }
        refreshDisplay()
        if let currentDisplay {
            store.geometry = targetGeometry(for: currentDisplay)
            animationTarget = store.geometry
        }
        panel.orderFrontRegardless()
        startTimer()
    }
    static func descriptor(_ screen: NSScreen) -> DisplayDescriptor {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        let id: String
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            id = CFUUIDCreateString(nil, uuid) as String
        } else { id = "screen-\(displayID)" }
        let hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        let width = hasNotch ? screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0) : 80
        return DisplayDescriptor(id: id, frame: screen.frame, hasNotch: hasNotch,
                                 notchWidth: width, notchHeight: hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness)
    }
    func refreshDisplay() {
        let screens = NSScreen.screens
        guard let selected = IslandDisplayResolver.resolve(
            choice: store.displayChoice, displays: screens.map(Self.descriptor),
            mainID: NSScreen.main.map { Self.descriptor($0).id }, cursor: NSEvent.mouseLocation,
            currentID: currentDisplay?.id, mode: store.mode, isDragging: false) else { return }
        if selected != currentDisplay {
            currentDisplay = selected
            panel.setFrame(NSRect(x: selected.frame.midX - 360, y: selected.frame.maxY - 320, width: 720, height: 320), display: true)
            store.hasNotch = selected.hasNotch
            store.hardwareNotchHeight = selected.hasNotch ? selected.notchHeight : 0
            store.displayName = screens.first { Self.descriptor($0).id == selected.id }?.localizedName ?? "Display"
            NotificationCenter.default.post(name: .islandScreenChanged, object: panel)
        }
    }
    @objc private func screensChanged() { refreshDisplay() }
    @objc private func sleep() { suspended = true; timer?.invalidate(); timer = nil; panel.orderOut(nil) }
    @objc private func wake() { suspended = false; refreshDisplay(); panel.orderFrontRegardless(); startTimer() }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(frame), userInfo: nil, repeats: true)
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    @objc private func frame() {
        guard !suspended else { return }
        let mouse = NSEvent.mouseLocation
        let moved = mouse != lastMouse
        if store.displayChoice == .followMouse { refreshDisplay() }
        guard let display = currentDisplay else { return }
        updateGeometry(display: display)
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        store.tick(hovering: store.geometry.containsPanelPoint(point, margin: 6), moved: moved)
        updateGeometry(display: display)
        // Click interception uses the exact current rendered silhouette, never its hover grace zone.
        panel.ignoresMouseEvents = !store.geometry.containsPanelPoint(point)
        if moved && store.mode != .hidden {
            store.gaze = CGPoint(x: tanh((mouse.x - display.frame.midX) / 260),
                                 y: tanh((display.frame.maxY - mouse.y - store.geometry.topOffset - 90) / 200))
        }
        lastMouse = mouse
    }
    private func targetGeometry(for display: DisplayDescriptor) -> IslandGeometry {
        IslandGeometry(display: display, mode: store.mode, hasContexts: !store.contexts.isEmpty,
                       presentation: store.presentation)
    }
    private func updateGeometry(display: DisplayDescriptor) {
        let target = targetGeometry(for: display)
        let now = ProcessInfo.processInfo.systemUptime
        if target != animationTarget {
            animationStart = now
            animationFrom = store.geometry
            animationTarget = target
            opening = target.size.width > store.geometry.size.width
        }
        guard store.geometry != target else { return }
        let duration = opening ? 0.36 : 0.24
        let progress = min(1, max(0, (now - animationStart) / duration))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || progress >= 1 {
            store.geometry = target
        } else {
            let fraction = progress * progress * (3 - 2 * progress)
            store.geometry = (animationFrom ?? store.geometry).interpolated(to: target, fraction: fraction)
        }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.orderOut(nil)
    }
    func diagnostics() -> [String: Any] {
        ["panelWidth": panel.frame.width, "panelHeight": panel.frame.height,
         "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
         "canBecomeKey": panel.canBecomeKey, "canBecomeMain": panel.canBecomeMain,
         "hasShadow": panel.hasShadow, "isOpaque": panel.isOpaque,
         "mode": store.mode.rawValue, "contextCount": store.contexts.count,
         "presentation": store.presentation.rawValue,
         "islandWidth": store.geometry.size.width, "islandHeight": store.geometry.size.height,
         "islandTopOffset": store.geometry.topOffset, "topCornerRadius": store.geometry.topRadius,
         "contentTopInset": store.geometry.contentTopInset(hardwareNotchHeight: store.hardwareNotchHeight),
         "presentationSettled": currentDisplay.map { store.geometry == targetGeometry(for: $0) } ?? false,
         "transparentMarginPassesThrough": !store.geometry.containsPanelPoint(CGPoint(x: 1, y: 1)),
         "display": store.displayName, "hasNotch": store.hasNotch,
         "topAnchored": currentDisplay.map { abs(panel.frame.maxY - $0.frame.maxY) < 0.1 } ?? false,
         "isVisible": panel.isVisible, "isKeyWindow": panel.isKeyWindow,
         "activationPolicyAccessory": NSApp.activationPolicy() == .accessory]
    }
}
extension Notification.Name {
    static let islandScreenChanged = Notification.Name("a0_notch.islandScreenChanged")
}
