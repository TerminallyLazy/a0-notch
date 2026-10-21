import Foundation
import XCTest
@testable import NotchCore

final class FileTransferStateTests: XCTestCase {
    private typealias Transfer = FileTransferState
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let selection = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let fileID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    private func access(context: String = "chat", incarnation: String = "inc-1",
                        generation: UUID? = nil, selection: UUID? = nil,
                        permitted: Bool = true) -> Transfer.Access {
        let generation = generation ?? self.generation
        return Transfer.Access(
            target: ChatTarget(context: context, generation: generation, selection: selection ?? self.selection,
                               incarnation: incarnation),
            context: ProductContextIdentity(generation: generation, contextID: context, incarnation: incarnation),
            isPermitted: permitted)
    }

    private func file(id: UUID? = nil, path: String = "/tmp/input.txt",
                      bytes: Int64? = nil) throws -> Transfer.File {
        try Transfer.File(id: id ?? fileID, url: URL(fileURLWithPath: path), byteCount: bytes)
    }

    private func receipt(id: UUID? = nil) throws -> Transfer.Receipt {
        try Transfer.Receipt(files: [Transfer.DeliveredFile(fileID: id ?? fileID, reference: "attachment-1")])
    }

    private func staged() throws -> (Transfer, Transfer.Operation) {
        var state = Transfer()
        let operation = try state.stage(files: [file()], operationID: operationID, access: access())
        return (state, operation)
    }

    private func uploading() throws -> (Transfer, Transfer.Operation) {
        var (state, operation) = try staged()
        XCTAssertTrue(state.start(operation, access: access()))
        return (state, operation)
    }

    private func contradictoryAccess(targetIncarnation: String?) -> Transfer.Access {
        Transfer.Access(target: ChatTarget(context: "chat", generation: generation, selection: selection,
                                           incarnation: targetIncarnation),
                        context: access().context, isPermitted: true)
    }

    private var invalidAccesses: [Transfer.Access?] {
        [nil, access(permitted: false), access(context: "other"), access(context: ""),
         access(incarnation: ""), access(incarnation: "inc-2"),
         access(generation: otherID), access(selection: otherID),
         contradictoryAccess(targetIncarnation: nil), contradictoryAccess(targetIncarnation: "inc-2"),
         Transfer.Access(target: access().target,
                         context: ProductContextIdentity(generation: otherID, contextID: "chat", incarnation: "inc-1"),
                         isPermitted: true),
         Transfer.Access(target: access().target,
                         context: ProductContextIdentity(generation: generation, contextID: "other", incarnation: "inc-1"),
                         isPermitted: true)]
    }

    func testInitialStateAndStagingDoNotStartUpload() throws {
        var state = Transfer()
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.operation)
        XCTAssertTrue(state.files.isEmpty)
        XCTAssertNil(state.progress.fraction)
        XCTAssertFalse(state.invalidateIfNeeded(access: nil))
        let operation = try state.stage(files: [file(bytes: 12)], operationID: operationID, access: access())
        XCTAssertEqual(state.phase, .staged)
        XCTAssertEqual(operation.id, operationID)
        XCTAssertEqual(operation.context, access().context)
        XCTAssertEqual(operation.target, access().target)
        XCTAssertEqual(state.files.first?.byteCount, 12)
        XCTAssertNil(state.progress.totalBytes, "File size must not become request-body size")
        XCTAssertEqual(state.progress.bytesSent, 0)
        XCTAssertNil(state.nextAction)
        let before = state
        XCTAssertFalse(state.reportProgress(operation, bytesSent: 1, totalBytes: nil, access: access()))
        XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
        XCTAssertFalse(state.fail(.ambiguous("early"), operation: operation, access: access()))
        XCTAssertNil(state.choose(.askAboutFiles, operation: operation, access: access()))
        XCTAssertEqual(state, before)
    }

    func testFileAndReceiptValidation() throws {
        XCTAssertThrowsError(try Transfer.File(id: fileID, url: XCTUnwrap(URL(string: "https://example.org/file"))))
        XCTAssertThrowsError(try file(bytes: -1))
        XCTAssertNoThrow(try file(bytes: 0))
        XCTAssertNoThrow(try file(bytes: Int64.max))
        for reference in ["", "  \n", "bad\nreference", "bad\u{0000}reference"] {
            XCTAssertThrowsError(try Transfer.DeliveredFile(fileID: fileID, reference: reference))
        }
        XCTAssertThrowsError(try Transfer.Receipt(files: []))
        let delivered = try Transfer.DeliveredFile(fileID: fileID, reference: "one")
        XCTAssertThrowsError(try Transfer.Receipt(files: [delivered, delivered]))
        XCTAssertThrowsError(try Transfer.Receipt(files: [delivered,
            Transfer.DeliveredFile(fileID: otherID, reference: "one")]))
        XCTAssertThrowsError(try Transfer.Receipt(files: [delivered,
            Transfer.DeliveredFile(fileID: fileID, reference: "two")]))
    }

    func testInvalidStagingPreservesExistingState() throws {
        var (state, _) = try staged()
        let before = state
        for invalid in [nil, access(permitted: false), access(context: ""), access(incarnation: "")] as [Transfer.Access?] {
            XCTAssertThrowsError(try state.stage(files: [file()], operationID: otherID, access: invalid)) {
                XCTAssertEqual($0 as? Transfer.ValidationError, .invalidTarget)
            }
            XCTAssertEqual(state, before)
        }
        XCTAssertThrowsError(try state.stage(files: [], operationID: otherID, access: access()))
        XCTAssertThrowsError(try state.stage(files: [file(), file(path: "/tmp/second")], operationID: otherID, access: access()))
        XCTAssertThrowsError(try state.stage(files: [file(), file(id: otherID, path: "/tmp/sub/../input.txt")],
                                            operationID: otherID, access: access()))
        XCTAssertEqual(state, before)
    }

    func testStartRequiresCurrentExactAccessAndOnlyRunsOnce() throws {
        var (state, operation) = try staged()
        let before = state
        for invalid in invalidAccesses {
            XCTAssertFalse(state.start(operation, access: invalid))
            XCTAssertEqual(state, before)
        }
        XCTAssertTrue(state.start(operation, access: access()))
        XCTAssertFalse(state.start(operation, access: access()))
        let running = state
        XCTAssertThrowsError(try state.stage(files: [file()], operationID: otherID, access: access())) {
            XCTAssertEqual($0 as? Transfer.ValidationError, .uploadInFlight)
        }
        XCTAssertEqual(state, running)
    }

    func testEveryCallbackRejectsWrongOrMissingTargetWithoutMutation() throws {
        var (state, operation) = try uploading()
        let before = state
        for invalid in invalidAccesses {
            XCTAssertFalse(state.reportProgress(operation, bytesSent: 1, totalBytes: 10, access: invalid))
            XCTAssertFalse(try state.receive(receipt(), operation: operation, access: invalid))
            XCTAssertFalse(state.fail(.definite("rejected"), operation: operation, access: invalid))
            XCTAssertFalse(state.fail(.ambiguous("lost"), operation: operation, access: invalid))
            XCTAssertEqual(state, before)
        }
    }

    func testSelectionAndIncarnationInvalidationAreSticky() throws {
        for invalid in invalidAccesses {
            var (state, operation) = try uploading()
            XCTAssertTrue(state.invalidateIfNeeded(access: invalid))
            XCTAssertEqual(state.phase, .cancelled(.remoteOutcomeUnknown))
            XCTAssertFalse(state.invalidateIfNeeded(access: invalid))
            XCTAssertFalse(state.start(operation, access: access()))
            XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
        }
        var (stagedState, _) = try staged()
        XCTAssertFalse(stagedState.invalidateIfNeeded(access: access()))
        XCTAssertTrue(stagedState.invalidateIfNeeded(access: nil))
        XCTAssertEqual(stagedState.phase, .cancelled(.notStarted))
    }

    func testReplacementRejectsAllOldOperationsEvenWithSameUUID() throws {
        var (state, old) = try uploading()
        XCTAssertTrue(state.cancel(old))
        let current = try state.stage(files: [file()], operationID: operationID, access: access())
        XCTAssertEqual(old.id, current.id)
        XCTAssertNotEqual(old.revision, current.revision)
        let before = state
        XCTAssertFalse(state.start(old, access: access()))
        XCTAssertFalse(state.cancel(old))
        XCTAssertEqual(state, before)
        XCTAssertTrue(state.start(current, access: access()))
        let running = state
        XCTAssertFalse(state.reportProgress(old, bytesSent: 9, totalBytes: 10, access: access()))
        XCTAssertFalse(try state.receive(receipt(), operation: old, access: access()))
        XCTAssertFalse(state.fail(.definite("old"), operation: old, access: access()))
        XCTAssertFalse(state.fail(.ambiguous("old"), operation: old, access: access()))
        XCTAssertNil(state.choose(.openInChat, operation: old, access: access()))
        XCTAssertEqual(state, running)
        XCTAssertTrue(try state.receive(receipt(), operation: current, access: access()))
    }

    func testStagedReplacementAndValueCopyIsolation() throws {
        var (state, old) = try staged()
        let copy = state
        let new = try state.stage(files: [file(id: otherID, path: "/tmp/other")],
                                  operationID: otherID, access: access(context: "other"))
        XCTAssertEqual(copy.operation, old)
        XCTAssertEqual(copy.files.first?.id, fileID)
        XCTAssertEqual(state.operation, new)
        XCTAssertFalse(state.start(old, access: access()))
        XCTAssertTrue(state.start(new, access: access(context: "other")))
    }

    func testUnknownTotalAndMonotonicRealProgress() throws {
        var (state, operation) = try uploading()
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 7, totalBytes: nil, access: access()))
        XCTAssertNil(state.progress.fraction)
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 7, totalBytes: 10, access: access()))
        XCTAssertEqual(try XCTUnwrap(state.progress.fraction), 0.7, accuracy: 0.000001)
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 8, totalBytes: nil, access: access()))
        XCTAssertEqual(state.progress.totalBytes, 10)
        let before = state
        for (bytes, total) in [(-1, 10), (7, 10), (11, 10), (8, -1), (8, 9), (8, 11)] as [(Int64, Int64)] {
            XCTAssertFalse(state.reportProgress(operation, bytesSent: bytes, totalBytes: total, access: access()))
            XCTAssertEqual(state, before)
        }
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 10, totalBytes: 10, access: access()))
        XCTAssertEqual(state.progress.fraction, 1)
        XCTAssertEqual(state.phase, .uploading, "100% bytes is not a delivery receipt")
    }

    func testUnknownTotalCannotBecomeSmallerThanSentBytes() throws {
        var (state, operation) = try uploading()
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 8, totalBytes: nil, access: access()))
        let before = state
        XCTAssertFalse(state.reportProgress(operation, bytesSent: 8, totalBytes: 7, access: access()))
        XCTAssertEqual(state, before)
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 8, totalBytes: 8, access: access()))
    }

    func testZeroAndMaximumByteBoundaries() throws {
        var (state, operation) = try uploading()
        XCTAssertFalse(state.reportProgress(operation, bytesSent: Int64.min, totalBytes: nil, access: access()))
        XCTAssertFalse(state.reportProgress(operation, bytesSent: 0, totalBytes: Int64.min, access: access()))
        XCTAssertTrue(state.reportProgress(operation, bytesSent: 0, totalBytes: 0, access: access()))
        XCTAssertNil(state.progress.fraction)
        XCTAssertFalse(state.reportProgress(operation, bytesSent: 1, totalBytes: 0, access: access()))
        XCTAssertTrue(try state.receive(receipt(), operation: operation, access: access()))
        var (large, largeOperation) = try uploading()
        XCTAssertTrue(large.reportProgress(largeOperation, bytesSent: Int64.max, totalBytes: nil, access: access()))
        XCTAssertNil(large.progress.fraction)
        XCTAssertTrue(large.reportProgress(largeOperation, bytesSent: Int64.max, totalBytes: Int64.max, access: access()))
        XCTAssertEqual(large.progress.bytesSent, Int64.max)
        XCTAssertEqual(large.progress.fraction, 1)
    }

    func testCancellationNeverClaimsRemoteRollbackAndIgnoresLateCallbacks() throws {
        for started in [false, true] {
            var (state, operation) = try staged()
            if started { XCTAssertTrue(state.start(operation, access: access())) }
            XCTAssertTrue(state.cancel(operation))
            XCTAssertEqual(state.phase, .cancelled(started ? .remoteOutcomeUnknown : .notStarted))
            let before = state
            XCTAssertFalse(state.cancel(operation))
            XCTAssertFalse(state.reportProgress(operation, bytesSent: 10, totalBytes: 10, access: access()))
            XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
            XCTAssertFalse(state.fail(.ambiguous("late"), operation: operation, access: access()))
            XCTAssertNil(state.choose(.askAboutFiles, operation: operation, access: access()))
            XCTAssertEqual(state, before)
        }
    }

    func testFailureAndAmbiguityAreTerminalWithoutRetry() throws {
        for failure in [Transfer.Failure.definite("denied"), .ambiguous("connection lost")] {
            var (state, operation) = try uploading()
            XCTAssertTrue(state.fail(failure, operation: operation, access: access()))
            switch failure {
            case .definite(let reason): XCTAssertEqual(state.phase, .failed(reason))
            case .ambiguous(let reason): XCTAssertEqual(state.phase, .ambiguous(reason))
            }
            let before = state
            XCTAssertFalse(state.start(operation, access: access()))
            XCTAssertFalse(state.cancel(operation))
            XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
            XCTAssertFalse(state.fail(.definite("late"), operation: operation, access: access()))
            XCTAssertFalse(state.reportProgress(operation, bytesSent: 1, totalBytes: nil, access: access()))
            XCTAssertNil(state.choose(.openInChat, operation: operation, access: access()))
            XCTAssertEqual(state, before)
            let explicitNew = try state.stage(files: [file()], operationID: otherID, access: access())
            XCTAssertNotEqual(explicitNew, operation)
            XCTAssertEqual(state.phase, .staged, "Even explicit restaging must not start transport")
        }
    }

    func testReceiptMustAccountForExactlyEveryStagedFile() throws {
        var state = Transfer()
        let operation = try state.stage(files: [file(), file(id: otherID, path: "/tmp/second")],
                                        operationID: operationID, access: access())
        XCTAssertTrue(state.start(operation, access: access()))
        let before = state
        XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
        XCTAssertFalse(try state.receive(receipt(id: operationID), operation: operation, access: access()))
        XCTAssertEqual(state, before)
        let full = try Transfer.Receipt(files: [
            Transfer.DeliveredFile(fileID: otherID, reference: "second"),
            Transfer.DeliveredFile(fileID: fileID, reference: "first")])
        XCTAssertTrue(state.receive(full, operation: operation, access: access()))
        XCTAssertEqual(state.phase, .result(full))
        XCTAssertEqual(state.progress.bytesSent, 0, "Receipt must not fabricate transport progress")
        XCTAssertNil(state.progress.totalBytes)
        XCTAssertNil(state.nextAction)
        let completed = state
        XCTAssertFalse(state.receive(full, operation: operation, access: access()))
        XCTAssertFalse(state.fail(.ambiguous("late"), operation: operation, access: access()))
        XCTAssertFalse(state.cancel(operation))
        XCTAssertFalse(state.reportProgress(operation, bytesSent: 1, totalBytes: 1, access: access()))
        XCTAssertEqual(state, completed)
    }

    func testStagingRejectsNilAndContradictoryTargetIncarnation() throws {
        var (state, _) = try staged()
        let before = state
        for incarnation in [nil, "", "inc-2"] as [String?] {
            XCTAssertThrowsError(try state.stage(files: [file()], operationID: otherID,
                                                 access: contradictoryAccess(targetIncarnation: incarnation))) {
                XCTAssertEqual($0 as? Transfer.ValidationError, .invalidTarget)
            }
            XCTAssertEqual(state, before)
        }
    }

    func testRevocationClearsCompletedContentAndCannotResurrectIt() throws {
        for invalid in invalidAccesses {
            var (state, operation) = try uploading()
            XCTAssertTrue(state.reportProgress(operation, bytesSent: 10, totalBytes: 10, access: access()))
            XCTAssertTrue(try state.receive(receipt(), operation: operation, access: access()))
            XCTAssertNotNil(state.choose(.askAboutFiles, operation: operation, access: access()))
            let completed = state
            XCTAssertFalse(state.invalidateIfNeeded(access: access()))
            XCTAssertEqual(state, completed)
            XCTAssertTrue(state.invalidateIfNeeded(access: invalid))
            XCTAssertEqual(state.phase, .revoked(.delivered), "Delivery must not be relabeled as cancellation")
            XCTAssertNil(state.operation)
            XCTAssertTrue(state.files.isEmpty)
            XCTAssertEqual(state.progress.bytesSent, 0)
            XCTAssertNil(state.progress.totalBytes)
            XCTAssertNil(state.nextAction)
            let cleared = state
            XCTAssertFalse(state.invalidateIfNeeded(access: invalid))
            XCTAssertFalse(state.start(operation, access: access()))
            XCTAssertFalse(try state.receive(receipt(), operation: operation, access: access()))
            XCTAssertFalse(state.fail(.ambiguous("late sensitive detail"), operation: operation, access: access()))
            XCTAssertFalse(state.reportProgress(operation, bytesSent: 10, totalBytes: 10, access: access()))
            XCTAssertNil(state.choose(.openInChat, operation: operation, access: access()))
            XCTAssertEqual(state, cleared)
            let replacement = try state.stage(files: [file()], operationID: operationID, access: access())
            XCTAssertNotEqual(replacement.revision, operation.revision)
            XCTAssertFalse(state.start(operation, access: access()))
        }
    }

    func testRevocationClearsSensitiveContentWithoutChangingCancellationCertainty() throws {
        for started in [false, true] {
            for alreadyCancelled in [false, true] {
                var (state, operation) = try staged()
                if started {
                    XCTAssertTrue(state.start(operation, access: access()))
                    XCTAssertTrue(state.reportProgress(operation, bytesSent: 7, totalBytes: 10, access: access()))
                }
                if alreadyCancelled { XCTAssertTrue(state.cancel(operation)) }
                XCTAssertTrue(state.invalidateIfNeeded(access: nil))
                XCTAssertEqual(state.phase, .cancelled(started ? .remoteOutcomeUnknown : .notStarted))
                XCTAssertNil(state.operation)
                XCTAssertTrue(state.files.isEmpty)
                XCTAssertEqual(state.progress.bytesSent, 0)
                XCTAssertNil(state.progress.totalBytes)
                XCTAssertNil(state.nextAction)
            }
        }
    }

    func testRevocationRedactsFailureDetailsButPreservesAmbiguity() throws {
        let cases: [(Transfer.Failure, Transfer.RevokedOutcome)] = [
            (.definite("sensitive file path"), .definiteFailure),
            (.ambiguous("sensitive attachment reference"), .ambiguous)]
        for (failure, outcome) in cases {
            var (state, operation) = try uploading()
            XCTAssertTrue(state.fail(failure, operation: operation, access: access()))
            XCTAssertTrue(state.invalidateIfNeeded(access: access(permitted: false)))
            XCTAssertEqual(state.phase, .revoked(outcome))
            XCTAssertNil(state.operation)
            XCTAssertTrue(state.files.isEmpty)
            XCTAssertNil(state.nextAction)
            XCTAssertFalse(state.start(operation, access: access()))
        }
    }

    func testNextActionRequiresReceiptExplicitChoiceAndFreshExactTarget() throws {
        for action in [Transfer.NextAction.askAboutFiles, .openInChat] {
            var (state, operation) = try uploading()
            XCTAssertNil(state.choose(action, operation: operation, access: access()))
            let delivered = try receipt()
            XCTAssertTrue(state.receive(delivered, operation: operation, access: access()))
            let before = state
            for invalid in invalidAccesses {
                XCTAssertNil(state.choose(action, operation: operation, access: invalid))
                XCTAssertEqual(state, before)
            }
            let request = try XCTUnwrap(state.choose(action, operation: operation, access: access()))
            XCTAssertEqual(request.operation, operation)
            XCTAssertEqual(request.receipt, delivered)
            XCTAssertEqual(request.action, action)
            XCTAssertEqual(state.nextAction, action)
            XCTAssertEqual(state.phase, .result(delivered))
            XCTAssertNil(state.choose(action, operation: operation, access: access()))
            _ = try state.stage(files: [file()], operationID: otherID, access: access())
            XCTAssertNil(state.nextAction)
            XCTAssertEqual(state.progress.bytesSent, 0)
        }
    }
}
