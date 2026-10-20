import Foundation

/// Deterministic interaction policy. Supply monotonic timestamps from one clock.
/// Activity mutations are reconciled on the next tick; this type owns no timers.
public struct IslandStateMachine {
    public private(set) var mode: IslandMode = .hidden
    public var hasActivity: Bool = false
    public var autoCloseSeconds: TimeInterval = 60
    public var absenceSeconds: TimeInterval = 180
    public private(set) var attentionRequired = false
    private var finishDeadline: TimeInterval?

    private var clock: TimeInterval
    private var lastMovement: TimeInterval
    private var lastInteraction: TimeInterval
    private var hoverStarted: TimeInterval?
    private var peekLeft: TimeInterval?
    private var suppressHoverUntilExit = false

    public init(now: TimeInterval = 0) {
        let start = now.isFinite ? now : 0
        clock = start
        lastMovement = start
        lastInteraction = start
    }

    public var countdownFraction: Double {
        guard mode == .expanded, !attentionRequired else { return 1 }
        let remaining = max(0, autoCloseSeconds) - (clock - lastInteraction)
        return min(1, max(0, remaining / 10))
    }

    public mutating func tick(now: TimeInterval, isHovering: Bool, mouseMoved: Bool) {
        advanceClock(to: now)
        if mouseMoved { lastMovement = clock }
        if !isHovering {
            hoverStarted = nil
            suppressHoverUntilExit = false
        }

        if isAbsent {
            if attentionRequired { transition(to: .expanded); return }
            transition(to: .hidden)
            return
        }

        if mode == .expanded {
            if attentionRequired { return }
            if let deadline = finishDeadline {
                if isHovering { finishDeadline = nil; lastInteraction = clock }
                else if clock >= deadline { finishDeadline = nil; close(now: clock) }
                return
            }
            if isHovering { lastInteraction = clock }
            if !isHovering && clock >= lastInteraction + max(0, autoCloseSeconds) {
                close(now: clock)
            }
            return
        }

        if mode == .hidden && hasActivity {
            transition(to: .compact)
        } else if mode == .compact && !hasActivity {
            transition(to: .hidden)
        }

        guard !suppressHoverUntilExit else { return }
        switch mode {
        case .hidden:
            if isHovering {
                transition(to: .peek)
                hoverStarted = clock
            }
        case .peek:
            if isHovering {
                peekLeft = nil
                if hoverStarted == nil { hoverStarted = clock }
                if let start = hoverStarted, clock >= start + 0.650 {
                    open(now: clock)
                }
            } else {
                if peekLeft == nil { peekLeft = clock }
                if let left = peekLeft, clock >= left + 0.600 {
                    transition(to: restingMode)
                }
            }
        case .compact:
            if isHovering {
                if hoverStarted == nil { hoverStarted = clock }
                if let start = hoverStarted, clock >= start + 0.200 {
                    open(now: clock)
                }
            }
        case .expanded:
            break
        }
    }

    public mutating func open(now: TimeInterval) {
        interact(now: now)
        suppressHoverUntilExit = false
        transition(to: .expanded)
    }

    public mutating func close(now: TimeInterval) {
        attentionRequired = false
        finishDeadline = nil
        advanceClock(to: now)
        transition(to: restingMode)
        suppressHoverUntilExit = true
    }

    /// Real error events remain open until explicit dismissal; never activate a window.
    public mutating func showAttention(now: TimeInterval) {
        open(now: now)
        attentionRequired = true
        finishDeadline = nil
    }

    public mutating func showFinished(now: TimeInterval) {
        guard !attentionRequired else { return }
        open(now: now)
        finishDeadline = clock + 5.2
    }

    /// Immediate mode override used by deterministic policy tests.
    public mutating func force(mode: IslandMode, now: TimeInterval) {
        interact(now: now)
        suppressHoverUntilExit = false
        transition(to: mode)
    }

    /// Call for island clicks/typing. These explicit interactions also prove presence.
    public mutating func interact(now: TimeInterval) {
        advanceClock(to: now)
        lastInteraction = clock
        finishDeadline = nil
        lastMovement = clock
    }

    private var isAbsent: Bool {
        clock >= lastMovement + max(0, absenceSeconds)
    }

    private var restingMode: IslandMode {
        hasActivity && !isAbsent ? .compact : .hidden
    }

    private mutating func transition(to next: IslandMode) {
        mode = next
        hoverStarted = nil
        peekLeft = nil
    }

    private mutating func advanceClock(to now: TimeInterval) {
        if now.isFinite { clock = max(clock, now) }
    }
}
