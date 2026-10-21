import Foundation

/// Metadata-only FIFO. An enqueue, selection, dismissal or completion never sends input
/// and never authorizes a history request. Serialize mutations in the owning store.
public struct AttentionQueue: Sendable {
    public enum Kind: String, Sendable { case intervention, question, error }
    public struct Entry: Equatable, Sendable {
        public let id: ProductEventIdentity
        public let kind: Kind
        public init(id: ProductEventIdentity, kind: Kind) { self.id = id; self.kind = kind }
    }
    public enum EnqueueResult: Equatable, Sendable { case accepted, duplicate, unavailable }

    public private(set) var entries: [Entry] = []
    public private(set) var currentContexts: Set<ProductContextIdentity> = []
    // Tombstones are retained for each currently available incarnation. The owner must
    // only feed events after its protocol cursor check. No unresolved entry is evicted.
    private var seen: Set<ProductEventIdentity> = []
    public var first: Entry? { entries.first }
    public var requiresAttention: Bool { !entries.isEmpty }
    public init() {}

    /// Authoritative, already validated snapshot. Removing/replacing a context drops its
    /// pending metadata. Disconnect/staleness must call this with an empty set. A snapshot
    /// containing two incarnations of one context fails closed for that context.
    public mutating func reconcile(currentContexts: Set<ProductContextIdentity>) {
        let counts = Dictionary(grouping: currentContexts.filter(\.isValid), by: \.contextID)
        self.currentContexts = Set(counts.values.compactMap { $0.count == 1 ? $0.first : nil })
        entries.removeAll { !self.currentContexts.contains($0.id.context) }
        seen = seen.filter { self.currentContexts.contains($0.context) }
    }

    @discardableResult
    public mutating func enqueue(_ entry: Entry) -> EnqueueResult {
        guard entry.id.isValid, currentContexts.contains(entry.id.context) else { return .unavailable }
        guard seen.insert(entry.id).inserted else { return .duplicate }
        entries.append(entry)
        return .accepted
    }

    /// Exact event only, not "whatever is currently first". Use after an acknowledged
    /// explicit reply, authoritative resolution, or explicit user dismissal. This is
    /// local bookkeeping, never an acknowledgement sent to the agent.
    @discardableResult
    public mutating func resolve(_ id: ProductEventIdentity) -> Bool {
        guard currentContexts.contains(id.context), let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        entries.remove(at: index)
        return true
    }
}

/// Explicit selected-chat content gate, layered on top of the existing ChatTarget.
/// Never call select from alert arrival, completion, discovery, pinning or alias changes.
/// This type owns no content and returns no network/action effects.
public struct SelectedContentGate: Sendable {
    public struct Permit: Equatable, Sendable {
        public let context: ProductContextIdentity
        public let target: ChatTarget
        fileprivate let revision: UInt64
    }
    public private(set) var selection: Permit?
    private var revision: UInt64 = 0
    public init() {}

    /// Explicit user selection; caller supplies the existing selection revision token.
    /// Always invalidates prior permits, including A -> B -> A and reselection of A.
    @discardableResult
    public mutating func select(_ context: ProductContextIdentity, target: ChatTarget,
                                currentContexts: Set<ProductContextIdentity>) -> Permit? {
        clear()
        guard context.matches(target), currentContexts.contains(context) else { return nil }
        let permit = Permit(context: context, target: target, revision: revision)
        selection = permit
        return permit
    }

    public mutating func clear() { revision &+= 1; selection = nil }

    /// Reevaluate before requesting AND before displaying a response. The supplied
    /// freshness decision must come from LiveSessionState.permits at the current time.
    public func permits(_ captured: Permit, currentTarget: ChatTarget,
                        currentContexts: Set<ProductContextIdentity>, sessionPermits: Bool) -> Bool {
        sessionPermits && selection == captured && captured.target == currentTarget
            && captured.context.matches(currentTarget) && currentContexts.contains(captured.context)
    }
}
