import AppKit
import Observation
import SwiftUI

/// Injected by IslandWindowController. IslandView owns one persistent avatar layer:
/// overlay IslandAvatarInput(motion: motion), render fileHover, and hide its drawing
/// (not the input view) while avatarDragging. Coordinates are global AppKit points.
@MainActor @Observable
final class IslandMotionState {
    var avatarDragging = false
    var fileHover = false
    var animationPaused = true
    @ObservationIgnored var avatarFrame: CGRect = .zero
    @ObservationIgnored var pointerDown: (CGPoint) -> Void = { _ in }
    @ObservationIgnored var pointerDragged: (CGPoint) -> Void = { _ in }
    @ObservationIgnored var pointerUp: (CGPoint) -> Void = { _ in }
    @ObservationIgnored var hover: (Bool) -> Void = { _ in }
    @ObservationIgnored var wardrobe: () -> Void = {}
    @ObservationIgnored var press: () -> Void = {}
}

struct IslandAvatarInput: NSViewRepresentable {
    let motion: IslandMotionState
    func makeNSView(context: Context) -> IslandAvatarInputView { IslandAvatarInputView(motion: motion) }
    func updateNSView(_ view: IslandAvatarInputView, context: Context) { view.publishFrame() }
}

final class IslandAvatarInputView: NSView {
    let motion: IslandMotionState
    private var tracking: NSTrackingArea?
    init(motion: IslandMotionState) {
        self.motion = motion
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Zero")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); publishFrame() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); publishFrame() }
    func publishFrame() {
        guard let window else { return }
        motion.avatarFrame = window.convertToScreen(convert(bounds, to: nil))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { motion.hover(true) }
    override func mouseExited(with event: NSEvent) { motion.hover(false) }
    override func mouseDown(with event: NSEvent) { publishFrame(); motion.pointerDown(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { motion.pointerDragged(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { motion.pointerUp(NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) { motion.wardrobe() }
    override func accessibilityPerformPress() -> Bool { motion.press(); return true }
}

/// Native destination receives only the current drag's pasteboard; never samples
/// the general pasteboard or installs an event tap. Transparent regions are nil
/// except for a currently captured file-drag proximity session.
final class IslandDestinationView: NSView {
    var acceptsPoint: (CGPoint) -> Bool = { _ in false }
    var entered: (any NSDraggingInfo) -> NSDragOperation = { _ in [] }
    var updated: (any NSDraggingInfo) -> NSDragOperation = { _ in [] }
    var exited: () -> Void = {}
    var dropped: (any NSDraggingInfo) -> Bool = { _ in false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPoint(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { entered(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updated(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { exited() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { exited() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !updated(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropped(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

struct IslandHostedContent: View {
    let store: IslandStore
    let motion: IslandMotionState
    var body: some View {
        IslandView(store: store).environment(motion)
            .environment(\.zeroAnimationPaused, motion.animationPaused)
    }
}

struct IslandDragGhost: View {
    let store: IslandStore
    var body: some View {
        ZeroView(tint: store.tint, gaze: store.gaze, animated: true,
                 state: store.characterState, emote: .surprised,
                 outfit: store.wardrobe.resolved(), paused: store.suspended)
            .frame(width: 90, height: 90)
    }
}
