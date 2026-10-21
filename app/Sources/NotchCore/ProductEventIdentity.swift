import Foundation

/// Adapter-owned identity, not a new wire DTO. Use the accepted session generation and
/// authoritative context incarnation; never infer incarnation from names or array positions.
/// If the server cannot provide incarnation, the adapter must invalidate conservatively.
public struct ProductContextIdentity: Hashable, Sendable {
    public let generation: UUID
    public let contextID: String
    public let incarnation: String

    public init(generation: UUID, contextID: String, incarnation: String) {
        self.generation = generation
        self.contextID = contextID
        self.incarnation = incarnation
    }

    public var isValid: Bool { !contextID.isEmpty && !incarnation.isEmpty }

    /// Additional identity check only. LiveSessionState.permits, freshness and selection
    /// revision checks still belong to the caller before/after every asynchronous operation.
    public func matches(_ target: ChatTarget) -> Bool {
        isValid && target.generation == generation && target.context == contextID
            && target.incarnation == incarnation
    }
}

public struct ProductEventIdentity: Hashable, Sendable {
    public let context: ProductContextIdentity
    public let eventID: String
    public init(context: ProductContextIdentity, eventID: String) {
        self.context = context
        self.eventID = eventID
    }
    public var isValid: Bool { context.isValid && !eventID.isEmpty }
}
