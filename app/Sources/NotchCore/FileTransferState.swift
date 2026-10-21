import Foundation

/// Pure presentation/coordination state. No filesystem access, transport, clock, retries or sends.
/// Serialize mutations in the owner. Before every transition, the adapter must recheck HTTP/auth,
/// LiveSessionState.permits, selection revision and authoritative context incarnation.
public struct FileTransferState: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidFile, invalidReceipt, invalidTarget, emptyFiles, duplicateFile
        case uploadInFlight, operationRevisionExhausted
    }

    public struct File: Equatable, Sendable {
        public let id: UUID
        public let url: URL
        /// File content size, if actually known. Not the multipart/request byte total.
        public let byteCount: Int64?

        public init(id: UUID, url: URL, byteCount: Int64? = nil) throws {
            guard url.isFileURL, !url.lastPathComponent.isEmpty,
                  byteCount.map({ $0 >= 0 }) ?? true else { throw ValidationError.invalidFile }
            self.id = id
            self.url = url
            self.byteCount = byteCount
        }
    }

    /// A current adapter assertion, not an authorization capability. Never cache across awaits.
    /// Pass nil when selection, freshness or incarnation cannot be established.
    public struct Access: Equatable, Sendable {
        public let target: ChatTarget
        public let context: ProductContextIdentity
        public let isPermitted: Bool

        public init(target: ChatTarget, context: ProductContextIdentity, isPermitted: Bool) {
            self.target = target
            self.context = context
            self.isPermitted = isPermitted
        }

        fileprivate var isValid: Bool { isPermitted && context.matches(target) }
    }

    /// Capture this entire value before dispatch. UUID alone is insufficient for a callback.
    public struct Operation: Equatable, Sendable {
        public let id: UUID
        public let revision: UInt64
        public let target: ChatTarget
        public let context: ProductContextIdentity
        fileprivate init(id: UUID, revision: UInt64, access: Access) {
            self.id = id
            self.revision = revision
            target = access.target
            context = access.context
        }
    }

    public struct Progress: Equatable, Sendable {
        /// Cumulative request-body bytes reported by transport, never an estimate or timer.
        public let bytesSent: Int64
        public let totalBytes: Int64?
        /// Unknown and zero totals are indeterminate; receipt, not 100%, means success.
        public var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return Double(bytesSent) / Double(totalBytes)
        }
        fileprivate init(bytesSent: Int64, totalBytes: Int64?) {
            self.bytesSent = bytesSent
            self.totalBytes = totalBytes
        }
    }

    public struct DeliveredFile: Equatable, Sendable {
        public let fileID: UUID
        /// Opaque server-issued attachment reference, not a URL to open or a path to execute.
        public let reference: String
        public init(fileID: UUID, reference: String) throws {
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw ValidationError.invalidReceipt }
            self.fileID = fileID
            self.reference = reference
        }
    }

    public struct Receipt: Equatable, Sendable {
        public let files: [DeliveredFile]
        public init(files: [DeliveredFile]) throws {
            guard !files.isEmpty, Set(files.map(\.fileID)).count == files.count,
                  Set(files.map(\.reference)).count == files.count else {
                throw ValidationError.invalidReceipt
            }
            self.files = files
        }
    }

    public enum Cancellation: Equatable, Sendable {
        case notStarted
        /// Local cancellation stops accepting callbacks; it does not promise remote rollback.
        case remoteOutcomeUnknown
    }

    public enum Failure: Equatable, Sendable {
        /// Use only when the adapter can prove no remote write occurred.
        case definite(String)
        /// Timeout, connection loss, partial receipt or any unproven write outcome.
        case ambiguous(String)
    }

    /// Non-sensitive historical outcome retained after access revocation.
    public enum RevokedOutcome: Equatable, Sendable {
        case delivered, definiteFailure, ambiguous
    }

    public enum Phase: Equatable, Sendable {
        case empty, staged, uploading
        case cancelled(Cancellation)
        case result(Receipt)
        case failed(String)
        case ambiguous(String)
        case revoked(RevokedOutcome)
    }

    public enum NextAction: Equatable, Sendable { case askAboutFiles, openInChat }

    /// User intent only. Consuming this value must not automatically submit a chat message.
    /// The integrator must revalidate access again before opening a composer or chat.
    public struct ActionRequest: Equatable, Sendable {
        public let operation: Operation
        public let receipt: Receipt
        public let action: NextAction
        fileprivate init(operation: Operation, receipt: Receipt, action: NextAction) {
            self.operation = operation
            self.receipt = receipt
            self.action = action
        }
    }

    public private(set) var phase: Phase = .empty
    public private(set) var operation: Operation?
    public private(set) var files: [File] = []
    public private(set) var progress = Progress(bytesSent: 0, totalBytes: nil)
    public private(set) var nextAction: NextAction?
    private var revision: UInt64 = 0

    public init() {}

    /// Explicit user staging/replacement only. Cancel an in-flight upload before replacing it.
    /// Invalid requests throw without modifying the existing state. IDs may be reused safely
    /// within this model's lifetime because the model-owned revision never repeats.
    @discardableResult
    public mutating func stage(files: [File], operationID: UUID, access: Access?) throws -> Operation {
        guard let access, access.isValid else { throw ValidationError.invalidTarget }
        guard phase != .uploading else { throw ValidationError.uploadInFlight }
        guard !files.isEmpty else { throw ValidationError.emptyFiles }
        guard Set(files.map(\.id)).count == files.count,
              Set(files.map { $0.url.standardizedFileURL }).count == files.count else {
            throw ValidationError.duplicateFile
        }
        guard revision < UInt64.max else { throw ValidationError.operationRevisionExhausted }
        revision += 1
        let operation = Operation(id: operationID, revision: revision, access: access)
        self.operation = operation
        self.files = files
        progress = Progress(bytesSent: 0, totalBytes: nil)
        nextAction = nil
        phase = .staged
        return operation
    }

    /// Call immediately before handing the write to transport, not after an await.
    @discardableResult
    public mutating func start(_ operation: Operation, access: Access?) -> Bool {
        guard phase == .staged, accepts(operation, access: access) else { return false }
        phase = .uploading
        return true
    }

    /// nil total means "not supplied" and preserves a previously known total. Once known,
    /// the request total is immutable. Regressions, negatives and over-total counts are rejected.
    @discardableResult
    public mutating func reportProgress(_ operation: Operation, bytesSent: Int64,
                                        totalBytes: Int64?, access: Access?) -> Bool {
        guard phase == .uploading, accepts(operation, access: access),
              bytesSent >= progress.bytesSent else { return false }
        if let totalBytes {
            guard totalBytes >= 0, progress.totalBytes.map({ $0 == totalBytes }) ?? true else { return false }
        }
        let total = totalBytes ?? progress.totalBytes
        guard total.map({ bytesSent <= $0 }) ?? true else { return false }
        progress = Progress(bytesSent: bytesSent, totalBytes: total)
        return true
    }

    /// Only a full, authoritative receipt is success. Partial/malformed responses must instead
    /// be classified by the adapter as ambiguous. Receipt does not synthesize byte progress.
    @discardableResult
    public mutating func receive(_ receipt: Receipt, operation: Operation, access: Access?) -> Bool {
        guard phase == .uploading, accepts(operation, access: access),
              Set(receipt.files.map(\.fileID)) == Set(files.map(\.id)) else { return false }
        phase = .result(receipt)
        return true
    }

    @discardableResult
    public mutating func fail(_ failure: Failure, operation: Operation, access: Access?) -> Bool {
        guard phase == .uploading, accepts(operation, access: access) else { return false }
        switch failure {
        case .definite(let message): phase = .failed(message)
        case .ambiguous(let message): phase = .ambiguous(message)
        }
        return true
    }

    /// Always available locally, including after access is revoked. Owner cancels the transport
    /// task separately. Late completion cannot turn a cancellation into success.
    @discardableResult
    public mutating func cancel(_ operation: Operation) -> Bool {
        guard self.operation == operation else { return false }
        switch phase {
        case .staged: phase = .cancelled(.notStarted)
        case .uploading: phase = .cancelled(.remoteOutcomeUnknown)
        default: return false
        }
        return true
    }

    /// Call on selection/session/incarnation/freshness changes, even without pending callbacks.
    /// Clears sensitive content in every phase, retaining only honest outcome metadata.
    /// Does not cancel remote work or erase copies already held by the integrator; discard those
    /// copies and any ActionRequest on revocation too. Capture the transport handle separately.
    @discardableResult
    public mutating func invalidateIfNeeded(access: Access?) -> Bool {
        guard let operation, !accepts(operation, access: access) else { return false }
        switch phase {
        case .staged: phase = .cancelled(.notStarted)
        case .uploading: phase = .cancelled(.remoteOutcomeUnknown)
        case .result: phase = .revoked(.delivered)
        case .failed: phase = .revoked(.definiteFailure)
        case .ambiguous: phase = .revoked(.ambiguous)
        case .empty, .cancelled, .revoked: break
        }
        self.operation = nil
        files = []
        progress = Progress(bytesSent: 0, totalBytes: nil)
        nextAction = nil
        return true
    }

    /// One explicit next action per receipt. There is deliberately no automatic send or retry.
    public mutating func choose(_ action: NextAction, operation: Operation,
                                access: Access?) -> ActionRequest? {
        guard accepts(operation, access: access), nextAction == nil,
              case .result(let receipt) = phase else { return nil }
        nextAction = action
        return ActionRequest(operation: operation, receipt: receipt, action: action)
    }

    private func accepts(_ operation: Operation, access: Access?) -> Bool {
        guard self.operation == operation, let access, access.isValid else { return false }
        return access.target == operation.target && access.context == operation.context
    }
}
