import AppKit
import Foundation
import NotchCore

/// Compile with app sources excluding A0NotchApp.swift and the real NotchCore.
/// Native parent owns execution under its build lock; never include in app target.
@main
struct IslandDriverChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "a0.notch.island-driver.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IslandStore(defaults: defaults, arguments: [])
        let controller = IslandWindowController(store: store)
        defer { controller.shutdown() }
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        check(!controller.panel.canBecomeMain, "island never becomes main")
        controller.enableTextInput()
        check(!controller.panel.canBecomeKey, "hidden cannot request key")
        store.open()
        controller.enableTextInput()
        check(!controller.panel.canBecomeKey, "ordinary expansion cannot request key")
        store.islandEditing = true
        controller.enableTextInput()
        check(controller.panel.canBecomeKey, "explicit expanded composer can become key")
        controller.motion.avatarFrame = controller.visibleFrame
        let point = CGPoint(x: controller.visibleFrame.midX, y: controller.visibleFrame.midY)
        controller.motion.pointerDown(point)
        controller.motion.pointerDragged(CGPoint(x: point.x + 7, y: point.y))
        check(!controller.motion.avatarDragging, "seven points is not a drag")
        controller.motion.pointerDragged(CGPoint(x: point.x + 8, y: point.y))
        check(controller.motion.avatarDragging, "beyond seven creates ghost")
        check(controller.diagnostics()["nativeGhostVisible"] as? Bool == true, "native ghost is visible")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(store.suspended && !controller.panel.isVisible, "sleep hides and suspends")
        check(!controller.motion.avatarDragging, "sleep cancels captured drag")
        check(controller.diagnostics()["driverTimerActive"] as? Bool == false, "sleep stops timer")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(store.suspended, "screen wake cannot override system sleep")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(!store.suspended && controller.panel.isVisible, "last wake restores panel")
        let desktop = DesktopZeroController(wardrobe: store.wardrobe, defaults: defaults,
            callbacks: .init(islandFrame: { controller.visibleFrame }))
        store.desktop = desktop
        defer { desktop.shutdown() }
        controller.motion.avatarFrame = controller.visibleFrame
        let home = CGPoint(x: controller.visibleFrame.midX, y: controller.visibleFrame.midY)
        let away = CGPoint(x: home.x + 200, y: home.y - 200)
        controller.motion.pointerDown(home)
        controller.motion.pointerDragged(away)
        controller.motion.pointerUp(away)
        check(desktop.isVisible && desktop.wantsDesktop, "drop hands off to real desktop owner")
        check(!controller.motion.avatarDragging, "desktop handoff releases ghost")
        check(controller.diagnostics()["nativeGhostVisible"] as? Bool == false, "no duplicate ghost")
        desktop.shutdown(); store.desktop = nil
        controller.motion.pointerDown(home)
        controller.motion.pointerDragged(away)
        controller.motion.pointerUp(away)
        check(controller.motion.avatarDragging, "missing desktop returns with flight")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.55))
        check(!controller.motion.avatarDragging, "return flight releases ghost after 420ms")
        check(IslandAvatarLayout.transitionFraction(0, opening: true) == 0, "opening start")
        check(IslandAvatarLayout.transitionFraction(1, opening: true) == 1, "opening end")
        check(IslandAvatarLayout.transitionFraction(0.65, opening: true) > 1, "opening light overshoot")
        for step in 0...100 {
            let f = IslandAvatarLayout.transitionFraction(Double(step) / 100, opening: false)
            check(f >= 0 && f <= 1, "close never overshoots")
        }
        for width in [440.0, 560.0, 640.0] {
            let compact = IslandAvatarLayout.pose(main: true, index: 0, count: 4, width: width,
                height: 32, inset: 0, expansion: 0, overview: true, hidden: false, hasNotch: true, peek: false)
            check(compact.center == CGPoint(x: 27, y: 16) && compact.side == 34, "compact main endpoint")
            let expanded = IslandAvatarLayout.pose(main: true, index: 0, count: 4, width: width,
                height: 216, inset: 32, expansion: 1, overview: true, hidden: false, hasNotch: true, peek: false)
            check(expanded.center == CGPoint(x: 65, y: 120) && expanded.side == 96, "expanded main clears notch")
            let grid = (0..<4).map { IslandAvatarLayout.pose(main: false, index: $0, count: 4, width: width,
                height: 216, inset: 0, expansion: 1, overview: true, hidden: false, hasNotch: true, peek: false).center }
            check(Set(grid.map { "\($0.x),\($0.y)" }).count == 4, "grid positions distinct")
        }
        controller.shutdown()
        check(controller.diagnostics()["driverTimerActive"] as? Bool == false, "shutdown cancels timer")
        check(!controller.panel.isVisible && controller.motion.animationPaused, "shutdown pauses renderer")
        print("IslandDriverChecks passed")
    }
}
