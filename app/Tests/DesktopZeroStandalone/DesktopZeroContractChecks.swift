// TEST-ONLY contract stubs. These do not validate the production ZeroView/ZeroWardrobe.
// Compile only via scripts/test-desktop-zero-controller.sh, never in the app target.
import AppKit
import Observation
import SwiftUI

public enum ZeroCharacterState { case idle, working, thinking, searching, delegating, waiting, question, error, finished, sleeping, dizzy }
public enum ZeroEmote { case love, surprised, proud, wink, yawn, content, annoyed }
public enum ZeroOutfit { case auto, none, partyHat, beanie, crown, witchHat, santaHat, bunnyEars, bow, sunglasses, roundGlasses, scarf, haloRing }
@MainActor @Observable public final class ZeroWardrobe {
    public private(set) var selected: ZeroOutfit = .none
    public func resolved(at: Date = Date()) -> ZeroOutfit { selected }
    public func select(_ value: ZeroOutfit) { selected = value }
}
struct ZeroView: View {
    let tint: Color
    var gaze: CGPoint = .zero
    var animated = true
    var happy = false
    var state: ZeroCharacterState = .idle
    var emote: ZeroEmote?
    var outfit: ZeroOutfit = .none
    var paused = false
    var waving = false
    var frameTime: TimeInterval?
    var body: some View { Color.clear }
}

@main @MainActor
private enum DesktopZeroContractChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String,
                      file: StaticString = #file, line: UInt = #line) {
        precondition(value(), message, file: file, line: line)
        count += 1
    }
    static func main() {
        geometry()
        lifecycle()
        if CommandLine.arguments.contains("--panel") { panel() }
        print("PASS: \(count) desktop checks; ZeroView/ZeroWardrobe are TEST STUBS, not integrated rendering.")
    }
    static func geometry() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        check(DesktopZeroGeometry.size == CGSize(width: 120, height: 120), "fixed panel size")
        check(DesktopZeroGeometry.clamp(CGPoint(x: -100, y: -100), to: [screen]) == CGPoint(x: -24, y: -24), "24-point lower allowance")
        check(DesktopZeroGeometry.clamp(CGPoint(x: 2000, y: 2000), to: [screen]) == CGPoint(x: 904, y: 604), "whole panel upper allowance")
        let left = CGRect(x: -1000, y: 100, width: 900, height: 600)
        check(DesktopZeroGeometry.clamp(CGPoint(x: -800, y: 200), to: [screen, left]) == CGPoint(x: -800, y: 200), "negative-origin display")
        check(DesktopZeroGeometry.clamp(CGPoint(x: -800, y: 200), to: [screen]) == CGPoint(x: -24, y: 200), "unplugged display recovery")
        check(DesktopZeroGeometry.clamp(CGPoint(x: CGFloat.nan, y: CGFloat.infinity), to: [screen]) == .zero, "non-finite persisted values")
        check(DesktopZeroGeometry.clamp(CGPoint(x: 2, y: 3), to: []) == CGPoint(x: 2, y: 3), "no screen fallback")
        let frame = CGRect(x: -40, y: 20, width: 120, height: 120)
        check(DesktopZeroGeometry.bodyContains(CGPoint(x: 20, y: 80), frame: frame), "body center hits")
        check(!DesktopZeroGeometry.bodyContains(CGPoint(x: -39, y: 21), frame: frame), "transparent corner misses")
        check(DesktopZeroGeometry.bodyContains(CGPoint(x: 48.7, y: 80), frame: frame), "inside body radius")
        check(!DesktopZeroGeometry.bodyContains(CGPoint(x: 48.9, y: 80), frame: frame), "outside body radius")
        check(!DesktopZeroGeometry.crossesDragThreshold(CGPoint(x: 7, y: 0)), "exact threshold is not drag")
        check(DesktopZeroGeometry.crossesDragThreshold(CGPoint(x: 7.01, y: 0)), "beyond threshold is drag")
        check(DesktopZeroGeometry.crossesDragThreshold(CGPoint(x: -5, y: -5)), "Euclidean diagonal threshold")
    }
    static func lifecycle() {
        var life = DesktopZeroLifecycle(desired: true, now: 0)
        check(life.framesPerSecond == 30, "active rate")
        life.updateSleep(now: 119.99, cursorDistance: 151, interacting: false)
        check(!life.sleeping, "not before two minutes")
        life.updateSleep(now: 120, cursorDistance: 150, interacting: false)
        check(!life.sleeping, "exact distance boundary stays awake")
        life.updateSleep(now: 120, cursorDistance: 150.01, interacting: false)
        check(life.sleeping && life.framesPerSecond == 10, "sleep rate")
        life.updateSleep(now: 121, cursorDistance: 300, interacting: true)
        check(!life.sleeping, "interaction wakes")
        life.activity(now: 130)
        life.updateSleep(now: 249, cursorDistance: 300, interacting: false)
        check(!life.sleeping, "agent activity resets idle clock")
        check(life.beginAlert(id: "a", now: 250), "first alert")
        check(!life.beginAlert(id: "a", now: 251), "duplicate alert idempotent")
        check(!life.retractIfDue(now: 250.449), "no early retraction")
        check(!life.beginAlert(id: "b", now: 250.2), "overlapping alert does not reset deadline")
        check(life.retractIfDue(now: 250.45), "450ms retraction")
        check(life.desired && !life.presentable && life.framesPerSecond == 0, "retraction preserves desire, stops sampling")
        life.resolveAlert(id: "missing")
        life.resolveAlert(id: "a")
        check(!life.presentable, "remaining alert prevents return")
        life.resolveAlert(id: "b")
        check(life.presentable, "last resolution restores desired desktop")
        _ = life.beginAlert(id: "quick", now: 300)
        life.resolveAlert(id: "quick")
        check(!life.retractIfDue(now: 301) && life.presentable, "resolution cancels pending retraction")
        _ = life.beginAlert(id: "cancel", now: 310)
        life.setDesired(false)
        life.resolveAlert(id: "cancel")
        check(!life.presentable && !life.desired, "user return overrides automatic restoration")
        life.setDesired(true)
        life.suspensions.insert("screen")
        life.suspensions.insert("lock")
        check(life.framesPerSecond == 0, "suspend stops sampling")
        life.suspensions.remove("screen")
        check(life.suspended, "screen wake cannot bypass lock")
        life.suspensions.remove("lock")
        check(!life.suspended && life.framesPerSecond == 30, "all reasons cleared resumes")
        _ = life.beginAlert(id: "hidden", now: 400)
        life.setDesired(true)
        check(!life.presentable && life.alertDeadline == nil, "install during alert remains hidden")
        life.resolveAlert(id: "hidden")
        check(life.presentable, "install restores after alert resolves")
    }
    /// Opt-in AppKit smoke checks. No shared app build; transient panel can become visible.
    static func panel() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "a0.desktop.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var returns: [DesktopZeroController.ReturnReason] = []
        var visibility: [Bool] = []
        var wardrobe = 0
        var sound = 0
        var controller: DesktopZeroController? = DesktopZeroController(wardrobe: ZeroWardrobe(), defaults: defaults,
            callbacks: .init(islandFrame: { nil }, returnedHome: { returns.append($0) },
                             visibilityChanged: { visibility.append($0) },
                             wardrobeRequested: { wardrobe += 1 }, soundToggleRequested: { sound += 1 }))
        weak var weakController = controller
        check(!controller!.isVisible && !controller!.wantsDesktop, "construction is hidden")
        controller!.show(at: CGPoint(x: 300, y: 300))
        check(controller!.isVisible && defaults.bool(forKey: "zeroOnDesktop"), "show persists desire")
        check(controller!.frame.size == CGSize(width: 120, height: 120), "native size")
        let window = app.windows.first { $0.title == "Zero on the desktop" }!
        check(window.styleMask.contains(.nonactivatingPanel), "nonactivating style")
        check(!window.canBecomeKey && !window.canBecomeMain, "never key or main")
        check(window.level == .floating && !window.isOpaque && !window.hasShadow, "floating transparent panel")
        let surface = window.contentView!
        check(surface.hitTest(CGPoint(x: 1, y: 1)) == nil, "native corner hit test")
        check(surface.hitTest(CGPoint(x: 60, y: 60)) === surface, "native center hit test")
        let actions = surface.accessibilityCustomActions()!
        check(actions.map(\.name) == ["Return to notch", "Wardrobe", "Toggle sound"], "three accessible actions")
        for action in actions.dropFirst() { check(action.handler?() == true, "accessible action handled") }
        check(wardrobe == 1 && sound == 1, "accessible wardrobe/sound callbacks")
        controller!.beginAlert(id: "first")
        pump(0.2)
        check(controller!.isVisible, "native alert grace period")
        controller!.resolveAlert(id: "first")
        pump(0.35)
        check(controller!.isVisible && returns.isEmpty, "native quick resolution cancels")
        controller!.beginAlert(id: "second")
        pump(0.55)
        check(!controller!.isVisible && returns == [.alert], "native delayed alert return")
        check(defaults.bool(forKey: "zeroOnDesktop"), "native alert preserves preference")
        controller!.resolveAlert(id: "second")
        check(controller!.isVisible, "native resolution restores")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        check(controller!.isSuspended && !controller!.isVisible, "native screen sleep")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(!controller!.isSuspended && controller!.isVisible, "native screen wake")
        check(surface.accessibilityPerformPress(), "accessible primary action")
        check(!controller!.isVisible && !defaults.bool(forKey: "zeroOnDesktop"), "user return clears desire")
        check(returns == [.alert, .user], "reasoned return callbacks")
        controller!.shutdown()
        controller!.shutdown()
        controller!.show()
        check(!controller!.isVisible, "shutdown terminal and idempotent")
        controller = nil
        check(weakController == nil, "timer/observer/view closures do not retain controller")
        weakController = nil // Release the weak slot only after testing deallocation.
        check(visibility == [true, false, true, false, true, false], "visibility events are transition-only")
        print("PASS: opt-in native AppKit panel, accessibility, alerts, persistence and teardown smoke checks")
    }
    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
