import Foundation

/// Composes IslandStateMachine rather than replacing its hover/presence policy.
/// Owns no timers, networking, content, focus activation or context removal. Feed one
/// monotonic clock to every method. Queue arrival is metadata, not chat selection.
public struct ExpandedPresentationModel {
    public enum View: String, CaseIterable, Sendable {
        case overview, empty, prompt, working, result, upload, uploading, choose, note
    }
    public enum Content: Equatable, Sendable {
        case view(View, ProductContextIdentity?)
        case attention(AttentionQueue.Entry)
        case finished(ProductEventIdentity)
    }
    public static let completionDuration: TimeInterval = 5.2
    public private(set) var attention = AttentionQueue()
    public private(set) var machine: IslandStateMachine
    public private(set) var content: Content = .view(.empty, nil)
    public var mode: IslandMode { machine.mode }
    public var countdownFraction: Double { isProtected ? 1 : machine.countdownFraction }
    public var completionRemaining: TimeInterval? { completions.first?.remaining }
    public var pendingCompletions: [ProductEventIdentity] { completions.map(\.id) }
    private struct Completion { let id: ProductEventIdentity; var remaining: TimeInterval }
    private var completions: [Completion] = []
    private var seenCompletions: Set<ProductEventIdentity> = []
    private var expired: [ProductEventIdentity] = []
    private var clock: TimeInterval
    private var completionDeadline: TimeInterval?
    private var ordinary: Content = .view(.empty, nil)
    private var protectedLastUpdate = false
    private var isProtected: Bool { attention.requiresAttention || !completions.isEmpty }

    public init(now: TimeInterval = 0) {
        let start = now.isFinite ? now : 0
        clock = start; machine = IslandStateMachine(now: start)
    }

    /// Nonfinite or negative preferences are rejected atomically.
    @discardableResult
    public mutating func configure(autoCloseSeconds: TimeInterval, absenceSeconds: TimeInterval) -> Bool {
        guard autoCloseSeconds.isFinite, absenceSeconds.isFinite,
              autoCloseSeconds >= 0, absenceSeconds >= 0 else { return false }
        machine.autoCloseSeconds = autoCloseSeconds; machine.absenceSeconds = absenceSeconds
        return true
    }

    /// Supply the entire live set, never just pinned/selected contexts. Empty set on
    /// disconnect/stale clears all queued metadata and invalidates context-bound views.
    public mutating func reconcile(currentContexts: Set<ProductContextIdentity>, hasActivity: Bool,
                                   now: TimeInterval) {
        advance(now)
        attention.reconcile(currentContexts: currentContexts)
        let current = attention.currentContexts
        let previousCompletion = completions.first?.id
        completions.removeAll { !current.contains($0.id.context) }
        if previousCompletion != completions.first?.id { completionDeadline = nil }
        seenCompletions = seenCompletions.filter { current.contains($0.context) }
        expired.removeAll { !current.contains($0.context) }
        if case .view(_, let target) = ordinary, let target, !current.contains(target) {
            ordinary = .view(current.isEmpty ? .empty : .overview, nil)
        }
        if case .view(.empty, nil) = ordinary, !current.isEmpty { ordinary = .view(.overview, nil) }
        if current.isEmpty { ordinary = .view(.empty, nil) }
        machine.hasActivity = hasActivity && !current.isEmpty
        synchronize()
    }

    @discardableResult
    public mutating func enqueueAttention(_ entry: AttentionQueue.Entry, now: TimeInterval) -> AttentionQueue.EnqueueResult {
        advance(now)
        let result = attention.enqueue(entry)
        synchronize()
        return result
    }

    @discardableResult
    public mutating func resolveAttention(_ id: ProductEventIdentity, now: TimeInterval) -> Bool {
        advance(now)
        let resolved = attention.resolve(id)
        synchronize()
        return resolved
    }

    /// Duplicates cannot restart presentation. An alert preempts completion, even for
    /// the same context; completion never implies an intervention was answered.
    @discardableResult
    public mutating func enqueueCompletion(_ id: ProductEventIdentity, now: TimeInterval) -> Bool {
        advance(now)
        guard id.isValid, attention.currentContexts.contains(id.context),
              seenCompletions.insert(id).inserted else { synchronize(); return false }
        completions.append(Completion(id: id, remaining: Self.completionDuration))
        synchronize()
        return true
    }

    /// User navigation only. Context-specific views require exact current identity.
    /// Alerts cannot be navigated away from; resolve an exact event explicitly first.
    @discardableResult
    public mutating func open(_ view: View, context: ProductContextIdentity? = nil, now: TimeInterval) -> Bool {
        advance(now)
        guard !attention.requiresAttention,
              context.map({ attention.currentContexts.contains($0) }) ?? true else { synchronize(); return false }
        // Explicit navigation dismisses presentation, never removes a live context.
        completions = []; completionDeadline = nil
        ordinary = .view(view, context)
        synchronize()
        machine.open(now: clock)
        return true
    }

    /// Escape is a dismissal request, not an answer. Unresolved alerts stay open.
    @discardableResult
    public mutating func close(now: TimeInterval) -> Bool {
        advance(now)
        guard !attention.requiresAttention else { synchronize(); return false }
        completions = []; completionDeadline = nil
        synchronize()
        machine.close(now: clock)
        return true
    }

    public mutating func interact(now: TimeInterval) {
        advance(now)
        machine.interact(now: clock)
        synchronize()
    }

    public mutating func tick(now: TimeInterval, isHovering: Bool, mouseMoved: Bool) {
        advance(now)
        synchronize()
        machine.tick(now: clock, isHovering: isHovering, mouseMoved: mouseMoved)
        content = attention.first.map(Content.attention) ?? completions.first.map { .finished($0.id) } ?? ordinary
    }

    /// One-shot exact IDs after 5.2 seconds of visible completion presentation. The
    /// adapter may reset transient UI, but must independently check current activity and
    /// pin policy before removing anything. Never delete an authoritative discovered chat.
    public mutating func takeExpiredCompletions() -> [ProductEventIdentity] {
        let result = expired; expired = []; return result
    }

    private mutating func advance(_ now: TimeInterval) {
        if now.isFinite { clock = max(clock, now) }
        // Only the rendered head accrues time. A delayed tick cannot consume completions
        // that have never been shown. Alert time never consumes the completion budget.
        if !attention.requiresAttention, !completions.isEmpty, let deadline = completionDeadline {
            completions[0].remaining = max(0, deadline - clock)
            if clock >= deadline {
                expired.append(completions.removeFirst().id)
                completionDeadline = nil
            }
        }
    }

    private mutating func synchronize() {
        if attention.requiresAttention || completions.isEmpty { completionDeadline = nil }
        else if completionDeadline == nil { completionDeadline = clock + completions[0].remaining }
        if isProtected {
            if !protectedLastUpdate { machine.showAttention(now: clock) }
        } else if protectedLastUpdate {
            machine.close(now: clock)
        }
        protectedLastUpdate = isProtected
        content = attention.first.map(Content.attention) ?? completions.first.map { .finished($0.id) } ?? ordinary
    }
}
