import Foundation
import CoreGraphics

/// Predict a semantic wakeup using a disposable copy of the actual policy. No polling
/// clock and no duplicate hover/absence state machine. Call after a real tick.
public enum IslandWakePolicy {
    public static func nextDelay(model: ExpandedPresentationModel, now: TimeInterval,
                                 hovering: Bool) -> TimeInterval? {
        guard now.isFinite else { return nil }
        let horizon = max(model.machine.absenceSeconds, model.machine.autoCloseSeconds, 5.2) + 1
        func changes(at delay: Double) -> Bool {
            var future = model
            future.tick(now: now + delay, isHovering: hovering, mouseMoved: false)
            return future.mode != model.mode || future.content != model.content
                || (model.countdownFraction >= 1 && future.countdownFraction < 1)
        }
        // Completion can finish and restore the same view before the horizon; probe
        // its explicit remaining budget as well as the ordinary policy horizon.
        var upper = horizon
        if let remaining = model.completionRemaining, model.attention.entries.isEmpty {
            upper = min(upper, max(0, remaining))
        }
        guard changes(at: upper) else { return nil }
        var lower = 0.0
        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if changes(at: middle) { upper = middle } else { lower = middle }
        }
        return max(0.001, upper)
    }

    public static func beginsDrag(from: CGPoint, to: CGPoint) -> Bool {
        hypot(to.x - from.x, to.y - from.y) > 7
    }
}
