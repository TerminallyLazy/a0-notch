import AppKit
import Observation
import SwiftUI
import NotchCore

final class IslandPanel: NSPanel {
    var textInputEnabled = false
    override var canBecomeKey: Bool { textInputEnabled }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandWindowController {
    let store: IslandStore
    let panel: IslandPanel
    let motion = IslandMotionState()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var currentDisplay: DisplayDescriptor?
    private var lastDisplayChoice: IslandDisplayChoice?
    private var lastMouse = NSEvent.mouseLocation
    private var animationStart = 0.0
    private var animationFrom: IslandGeometry?
    private var animationTarget: IslandGeometry?
    private var opening = false
    private var suspended = false
    private var stopped = false
    private var suspensionReasons: Set<String> = []
    private var observationGeneration = 0
    private var hovering = false
    private var nativeDragNearby = false
    private var fileTarget: ChatTarget?
    private var pointerDown: CGPoint?
    private var dragOffset = CGPoint.zero
    private var ghost: IslandPanel?
    private var flightStart: Double?
    private var flightOrigin = CGPoint.zero
    private var interactionWake: Double?
    private var hoverWake: Double?
    private var noteWake: Double?
    private var lastContent: ExpandedPresentationModel.Content?
    private var lastEmote: ZeroEmote?
    private var lastDizzy = false
    private var lastWave = false
    private(set) var driverWakeCount = 0

    init(store: IslandStore) {
        self.store = store
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "a0_notch — Agent Zero"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isMovable = false; panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let destination = IslandDestinationView(frame: NSRect(x: 0, y: 0, width: 720, height: 320))
        let hosting = NSHostingView(rootView: IslandHostedContent(store: store, motion: motion))
        hosting.sizingOptions = []; hosting.frame = destination.bounds
        hosting.autoresizingMask = [.width, .height]
        destination.addSubview(hosting)
        destination.registerForDraggedTypes([.fileURL])
        destination.acceptsPoint = { [weak self] point in
            guard let self else { return false }
            return self.nativeDragNearby || self.store.geometry.containsPanelPoint(point)
        }
        destination.entered = { [weak self] info in self?.fileDrag(info, entering: true) ?? [] }
        destination.updated = { [weak self] info in self?.fileDrag(info, entering: false) ?? [] }
        destination.exited = { [weak self] in self?.endFileDrag() }
        destination.dropped = { [weak self] info in self?.dropFiles(info) ?? false }
        panel.contentView = destination
        motion.pointerDown = { [weak self] point in self?.avatarDown(point) }
        motion.pointerDragged = { [weak self] point in self?.avatarDragged(point) }
        motion.pointerUp = { [weak self] point in self?.avatarUp(point) }
        motion.press = { [weak self] in self?.avatarClick() }
        motion.hover = { [weak self] inside in
            guard let self, !self.suspended else { return }
            self.store.interaction.hover(inside)
            self.hoverWake = inside ? self.store.now + 1.9 : nil
            self.drive()
        }
        motion.wardrobe = { [weak self] in self?.store.wardrobePresented = true }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sleep(_:)), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(wake(_:)), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .leftMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask.union([.keyDown, .scrollWheel]), handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel && (event.type == .keyDown || event.type == .leftMouseDown || event.type == .scrollWheel) {
                    self.store.interact()
                    if event.type == .leftMouseDown, let content = self.panel.contentView {
                        let local = content.convert(event.locationInWindow, from: nil)
                        var hit = content.hitTest(local)
                        while let view = hit {
                            if view is NSTextField || view is NSTextView {
                                self.store.islandEditing = true
                                self.enableTextInput()
                                break
                            }
                            hit = view.superview
                        }
                    }
                }
                self.mouseEvent(event)
            }
            return event
        }) { monitors.append(monitor) }
        if currentDisplay == nil || lastDisplayChoice != store.displayChoice || store.displayChoice == .followMouse { refreshDisplay() }
        if let currentDisplay { store.geometry = targetGeometry(for: currentDisplay); animationTarget = store.geometry }
        panel.orderFrontRegardless()
        drive()
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
    var visibleFrame: CGRect {
        let geometry = store.geometry
        return CGRect(x: panel.frame.midX - geometry.size.width / 2,
            y: panel.frame.maxY - geometry.topOffset - geometry.size.height,
            width: geometry.size.width, height: geometry.size.height)
    }
    func enableTextInput() {
        // Explicit composer intent only; opening an alert or wardrobe never takes key.
        guard !suspended, store.mode == .expanded, store.islandEditing else { return }
        panel.textInputEnabled = true; panel.makeKey()
    }
    func refreshDisplay() {
        lastDisplayChoice = store.displayChoice
        let screens = NSScreen.screens
        guard let selected = IslandDisplayResolver.resolve(
            choice: store.displayChoice, displays: screens.map(Self.descriptor),
            mainID: NSScreen.main.map { Self.descriptor($0).id }, cursor: NSEvent.mouseLocation,
            currentID: currentDisplay?.id, mode: store.mode, isDragging: store.avatarDragging) else { return }
        if selected != currentDisplay {
            currentDisplay = selected
            panel.setFrame(NSRect(x: selected.frame.midX - 360, y: selected.frame.maxY - 320, width: 720, height: 320), display: true)
            store.hasNotch = selected.hasNotch
            store.hardwareNotchHeight = selected.hasNotch ? selected.notchHeight : 0
            store.displayName = screens.first { Self.descriptor($0).id == selected.id }?.localizedName ?? "Display"
            NotificationCenter.default.post(name: .islandScreenChanged, object: panel)
        }
    }
    @objc private func screensChanged() { guard !stopped else { return }; refreshDisplay(); drive() }
    private func suspensionKey(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: "screen"
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: "system"
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification: "session"
        default: "lock"
        }
    }
    @objc private func sleep(_ notification: Notification) {
        suspensionReasons.insert(suspensionKey(notification.name))
        suspended = true; store.suspended = true; motion.animationPaused = true
        store.sounds?.stopAll(); cancelDrag(); endFileDrag()
        timer?.invalidate(); timer = nil; observationGeneration += 1
        panel.textInputEnabled = false
        if panel.isKeyWindow { panel.resignKey() }
        panel.orderOut(nil)
    }
    @objc private func wake(_ notification: Notification) {
        guard !stopped else { return }
        suspensionReasons.remove(suspensionKey(notification.name))
        guard suspensionReasons.isEmpty else { return }
        suspended = false; store.suspended = false
        refreshDisplay(); drive(); panel.orderFrontRegardless()
    }
    private func observeStore() {
        let generation = observationGeneration
        withObservationTracking {
            _ = store.mode; _ = store.presentation; _ = store.displayChoice
            _ = store.contexts; _ = store.expanded; _ = store.live
            _ = store.islandEditing; _ = store.avatarDragging; _ = store.desktopVisible
            _ = store.interaction.emote; _ = store.interaction.dizzy; _ = store.interaction.waving
            _ = store.autoCloseSeconds; _ = store.absenceMinutes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration, !self.stopped, !self.suspended else { return }
                self.drive()
            }
        }
    }
    private func mouseEvent(_ event: NSEvent) {
        guard !suspended, !stopped else { return }
        let mouse = NSEvent.mouseLocation
        if event.type == .leftMouseDragged && pointerDown == nil {
            // Only arm the native destination during an actual drag, in a bounded
            // approach zone. File eligibility is checked by NSDraggingDestination.
            nativeDragNearby = abs(mouse.x - panel.frame.midX) <= 220
                && mouse.y <= panel.frame.maxY
                && mouse.y >= visibleFrame.minY - 26
        } else if event.type == .leftMouseUp && fileTarget == nil { endFileDrag() }
        drive(mouse: mouse, moved: mouse != lastMouse)
    }
    private func drive(mouse: CGPoint? = nil, moved: Bool = false) {
        guard !stopped, !suspended else { return }
        observationGeneration += 1 // Discard our own model mutation callbacks.
        timer?.invalidate(); timer = nil
        let cursor = mouse ?? NSEvent.mouseLocation
        if currentDisplay == nil || lastDisplayChoice != store.displayChoice || store.displayChoice == .followMouse { refreshDisplay() }
        guard let display = currentDisplay else { observeStore(); return }
        updateGeometry(display: display)
        let point = CGPoint(x: cursor.x - panel.frame.minX, y: panel.frame.maxY - cursor.y)
        let wasHovering = hovering
        hovering = store.geometry.containsPanelPoint(point, margin: 6)
        // Leaving after a stationary hover records the exit time as activity, rather
        // than counting the whole dwell as idle (the previous polling driver did so).
        if wasHovering && !hovering && store.mode == .expanded { store.interact() }
        store.tick(hovering: hovering, moved: moved)
        updateGeometry(display: display)
        panel.ignoresMouseEvents = !(pointerDown != nil || nativeDragNearby || store.geometry.containsPanelPoint(point))
        if store.mode != .expanded || !store.islandEditing {
            panel.textInputEnabled = false
            if panel.isKeyWindow { panel.resignKey() }
        }
        motion.animationPaused = store.mode == .hidden || store.suspended
        if moved && store.mode != .hidden {
            store.gaze = CGPoint(x: tanh((cursor.x - display.frame.midX) / 260),
                y: tanh((display.frame.maxY - cursor.y - store.geometry.topOffset - 90) / 200))
        }
        lastMouse = cursor
        updateFlight()
        trackPrivateDeadlines()
        scheduleWake()
        observeStore()
    }
    private func trackPrivateDeadlines() {
        let now = store.now
        if store.interaction.emote != lastEmote || store.interaction.dizzy != lastDizzy || store.interaction.waving != lastWave {
            interactionWake = now + (store.interaction.dizzy ? 3.3 : (store.interaction.emote == .annoyed ? 0.8 : 1.2))
            lastEmote = store.interaction.emote; lastDizzy = store.interaction.dizzy; lastWave = store.interaction.waving
            if lastEmote == nil && !lastDizzy && !lastWave { interactionWake = nil }
        }
        if lastContent != store.expanded.content {
            lastContent = store.expanded.content
            if case .view(.note, _) = store.expanded.content { noteWake = now + 2 } else { noteWake = nil }
        }
        if let hoverWake, hoverWake <= now { self.hoverWake = nil }
        if let interactionWake, interactionWake <= now { self.interactionWake = nil }
        if let noteWake, noteWake <= now { self.noteWake = nil }
    }
    private func scheduleWake() {
        let now = store.now
        var delays: [Double] = []
        if let display = currentDisplay, store.geometry != targetGeometry(for: display) || flightStart != nil { delays.append(1.0 / 60) }
        if let delay = IslandWakePolicy.nextDelay(model: store.expanded, now: now, hovering: hovering) { delays.append(delay) }
        if store.mode == .expanded && !hovering && store.expanded.countdownFraction < 1 && store.expanded.countdownFraction > 0 { delays.append(0.1) }
        if store.live.mode == .live, let accepted = store.live.lastAccepted { delays.append(max(0.001, accepted + 10 - now)) }
        for deadline in [hoverWake, interactionWake, noteWake].compactMap({ $0 }) { delays.append(max(0.001, deadline - now)) }
        guard let delay = delays.min() else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.driverWakeCount += 1; self.drive()
            }
        }
        timer.tolerance = min(0.01, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func targetGeometry(for display: DisplayDescriptor) -> IslandGeometry {
        IslandGeometry(display: display, mode: store.mode, hasContexts: !store.contexts.isEmpty, presentation: store.presentation)
    }
    private func updateGeometry(display: DisplayDescriptor) {
        let target = targetGeometry(for: display), now = store.now
        if target != animationTarget {
            animationStart = now; animationFrom = store.geometry; animationTarget = target
            opening = target.size.width > store.geometry.size.width
        }
        guard store.geometry != target else { return }
        let progress = min(1, max(0, (now - animationStart) / (opening ? 0.52 : 0.34)))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || progress >= 1 { store.geometry = target }
        else { store.geometry = IslandAvatarLayout.geometry(from: animationFrom ?? store.geometry, to: target,
            fraction: IslandAvatarLayout.transitionFraction(progress, opening: opening)) }
    }
    private func avatarClick() {
        guard !suspended, !stopped else { return }
        store.interact()
        if store.mode == .expanded { store.interaction.slap() } else { store.open() }
        drive()
    }
    private func avatarDown(_ point: CGPoint) {
        guard !suspended, !stopped, !store.desktopVisible else { return }
        finishFlight()
        pointerDown = point
        dragOffset = CGPoint(x: point.x - motion.avatarFrame.midX, y: point.y - motion.avatarFrame.midY)
        store.interact(); drive()
    }
    private func avatarDragged(_ point: CGPoint) {
        guard let down = pointerDown, !suspended else { return }
        if !motion.avatarDragging {
            guard IslandWakePolicy.beginsDrag(from: down, to: point) else { return }
            store.avatarDragging = true; motion.avatarDragging = true
            store.interaction.hover(false); hoverWake = nil
            store.interaction.play(.surprised)
            let ghost = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 90, height: 90),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            ghost.isOpaque = false; ghost.backgroundColor = .clear; ghost.hasShadow = false
            ghost.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
            ghost.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            ghost.hidesOnDeactivate = false; ghost.ignoresMouseEvents = true
            ghost.contentView = NSHostingView(rootView: IslandDragGhost(store: store))
            self.ghost = ghost
        }
        ghost?.setFrameOrigin(CGPoint(x: point.x - dragOffset.x - 45, y: point.y - dragOffset.y - 45))
        ghost?.orderFrontRegardless()
        drive(mouse: point, moved: point != lastMouse)
    }
    private func avatarUp(_ point: CGPoint) {
        guard pointerDown != nil else { return }
        pointerDown = nil
        guard motion.avatarDragging else { avatarClick(); return }
        if visibleFrame.contains(point) {
            returnGhostHome()
        } else if let desktop = store.desktop {
            // DesktopZeroController is the sole persisted desktop placement owner.
            // It clamps to the display and owns alert retraction. No AX/window content.
            desktop.show(at: CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
            finishFlight()
        } else { returnGhostHome() }
        store.interact(); drive()
    }
    private func returnGhostHome() {
        guard let ghost else { finishFlight(); return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finishFlight(); return }
        flightOrigin = ghost.frame.origin; flightStart = store.now
    }
    private func updateFlight() {
        guard let flightStart, let ghost else { return }
        let t = min(1, max(0, (store.now - flightStart) / 0.42))
        let f = 1 - pow(1 - t, 3)
        let destination = CGPoint(x: motion.avatarFrame.midX - 45, y: motion.avatarFrame.midY - 45)
        ghost.setFrameOrigin(CGPoint(x: flightOrigin.x + (destination.x - flightOrigin.x) * f,
                                    y: flightOrigin.y + (destination.y - flightOrigin.y) * f))
        if t >= 1 { finishFlight() }
    }
    private func finishFlight() {
        ghost?.orderOut(nil); ghost?.contentView = nil; ghost = nil
        flightStart = nil; motion.avatarDragging = false; store.avatarDragging = false
    }
    private func cancelDrag() { pointerDown = nil; finishFlight() }

    private func fileDrag(_ info: any NSDraggingInfo, entering: Bool) -> NSDragOperation {
        guard !suspended, !stopped, !motion.avatarDragging,
              store.canMutate, store.supportsUploads,
              info.draggingSourceOperationMask.contains(.copy),
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            endFileDrag(); return []
        }
        if entering { fileTarget = store.target }
        guard fileTarget == store.target else { endFileDrag(); return [] }
        let point = info.draggingLocation
        let proximity = CGRect(x: 140, y: 320 - store.geometry.topOffset - store.geometry.size.height - 26,
                               width: 440, height: store.geometry.size.height + 26)
        let inIsland = store.geometry.containsPanelPoint(CGPoint(x: point.x, y: 320 - point.y))
        guard proximity.contains(point) || inIsland else { endFileDrag(); return [] }
        nativeDragNearby = true; motion.fileHover = true
        // Keep staging explicit. The upload screen does not claim progress/delivery,
        // and no bytes are read until performDragOperation supplies this drag's URLs.
        if case .view(.upload, _) = store.expanded.content { }
        else if store.expanded.attention.entries.isEmpty {
            _ = store.expanded.open(.upload, context: store.focusedIdentity, now: store.now)
        }
        drive()
        return .copy
    }
    private func dropFiles(_ info: any NSDraggingInfo) -> Bool {
        guard !fileDrag(info, entering: false).isEmpty, let target = fileTarget,
              target == store.target,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              (1...8).contains(urls.count), urls.allSatisfy(\.isFileURL) else { endFileDrag(); return false }
        endFileDrag()
        store.stageFiles(urls, target: target)
        drive()
        return store.transfer.phase == .staged
    }
    private func endFileDrag() {
        nativeDragNearby = false; motion.fileHover = false; fileTarget = nil
        let point = NSEvent.mouseLocation
        panel.ignoresMouseEvents = !(pointerDown != nil || store.geometry.containsPanelPoint(
            CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)))
    }
    func shutdown() {
        guard !stopped else { return }
        stopped = true; observationGeneration += 1
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        cancelDrag(); endFileDrag(); motion.animationPaused = true
        motion.pointerDown = { _ in }; motion.pointerDragged = { _ in }; motion.pointerUp = { _ in }
        motion.hover = { _ in }; motion.press = {}; motion.wardrobe = {}
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.orderOut(nil)
    }
    func diagnostics() -> [String: Any] {
        ["driverTimerActive": timer != nil, "driverWakeCount": driverWakeCount, "nativeGhostVisible": ghost?.isVisible ?? false, "fileHover": motion.fileHover, "panelWidth": panel.frame.width, "panelHeight": panel.frame.height,
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
