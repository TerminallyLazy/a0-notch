import Foundation
import XCTest
import NotchCore

final class AttentionQueueTests: XCTestCase {
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let nextGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let selection = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let nextSelection = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    private func context(_ id: String = "A", incarnation: String = "inc-1",
                         generation: UUID? = nil) -> ProductContextIdentity {
        ProductContextIdentity(generation: generation ?? self.generation,
                               contextID: id, incarnation: incarnation)
    }

    private func event(_ id: String = "event-1", context: ProductContextIdentity? = nil) -> ProductEventIdentity {
        ProductEventIdentity(context: context ?? self.context(), eventID: id)
    }

    private func entry(_ id: String = "event-1", context: ProductContextIdentity? = nil,
                       kind: AttentionQueue.Kind = .intervention) -> AttentionQueue.Entry {
        AttentionQueue.Entry(id: event(id, context: context), kind: kind)
    }

    private func target(_ context: ProductContextIdentity, selection: UUID? = nil) -> ChatTarget {
        ChatTarget(context: context.contextID, generation: context.generation,
                   selection: selection ?? self.selection, incarnation: context.incarnation)
    }

    func testIdentityValidityAndAllHashComponents() {
        let original = event()
        let variants: Set<ProductEventIdentity> = [original, event("event-2"),
            event(context: context("B")), event(context: context(incarnation: "inc-2")),
            event(context: context(generation: nextGeneration))]
        XCTAssertEqual(variants.count, 5)
        XCTAssertTrue(original.isValid)
        XCTAssertFalse(context("").isValid)
        XCTAssertFalse(context(incarnation: "").isValid)
        XCTAssertFalse(event("").isValid)
        XCTAssertFalse(event(context: context("")).isValid)
        XCTAssertFalse(event(context: context(incarnation: "")).isValid)
        XCTAssertTrue(context().matches(target(context())))
        XCTAssertFalse(context().matches(target(context("B"))))
        XCTAssertFalse(context().matches(target(context(generation: nextGeneration))))
    }

    func testEmptyQueueRejectsUnavailableAndInvalidEventsWithoutRememberingThem() {
        var queue = AttentionQueue()
        XCTAssertNil(queue.first)
        XCTAssertFalse(queue.requiresAttention)
        XCTAssertTrue(queue.currentContexts.isEmpty)
        XCTAssertEqual(queue.enqueue(entry()), .unavailable)
        XCTAssertFalse(queue.resolve(event()))
        queue.reconcile(currentContexts: [context()])
        XCTAssertEqual(queue.enqueue(entry("")), .unavailable)
        XCTAssertEqual(queue.enqueue(entry(context: context("B"))), .unavailable)
        XCTAssertEqual(queue.enqueue(entry(context: context(incarnation: ""))), .unavailable)
        XCTAssertEqual(queue.enqueue(entry()), .accepted)
        XCTAssertEqual(queue.entries, [entry()])
    }

    func testFIFOAcrossContextsAndKindsDoesNotCoalesceDistinctEvents() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context(), context("B")])
        let expected = [entry("a"), entry("b", context: context("B"), kind: .error),
                        entry("c", kind: .question)]
        for item in expected { XCTAssertEqual(queue.enqueue(item), .accepted) }
        XCTAssertEqual(queue.entries, expected)
        for item in expected {
            XCTAssertEqual(queue.first, item)
            XCTAssertTrue(queue.requiresAttention)
            XCTAssertTrue(queue.resolve(item.id))
        }
        XCTAssertNil(queue.first)
        XCTAssertFalse(queue.requiresAttention)
    }

    func testDuplicateEventCannotChangeKindPositionOrReturnAfterResolution() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context()])
        XCTAssertEqual(queue.enqueue(entry("first")), .accepted)
        XCTAssertEqual(queue.enqueue(entry("second")), .accepted)
        XCTAssertEqual(queue.enqueue(entry("first", kind: .error)), .duplicate)
        XCTAssertEqual(queue.entries, [entry("first"), entry("second")])
        XCTAssertTrue(queue.resolve(event("first")))
        queue.reconcile(currentContexts: [context()])
        XCTAssertEqual(queue.enqueue(entry("first", kind: .question)), .duplicate)
        XCTAssertFalse(queue.resolve(event("first")))
        XCTAssertEqual(queue.entries, [entry("second")])
    }

    func testResolveRequiresExactContextIncarnationGenerationAndEvent() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context(), context("B")])
        XCTAssertEqual(queue.enqueue(entry()), .accepted)
        for wrong in [event("other"), event(context: context("B")),
                      event(context: context(incarnation: "inc-2")),
                      event(context: context(generation: nextGeneration))] {
            XCTAssertFalse(queue.resolve(wrong))
            XCTAssertEqual(queue.entries, [entry()])
        }
        // Resolution is exact, not implicitly a pop of the head.
        XCTAssertEqual(queue.enqueue(entry("second")), .accepted)
        XCTAssertTrue(queue.resolve(event("second")))
        XCTAssertEqual(queue.first, entry())
        XCTAssertTrue(queue.resolve(event()))
    }

    func testSameEventIDInDifferentContextsIsNotDuplicate() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context(), context("B")])
        XCTAssertEqual(queue.enqueue(entry()), .accepted)
        XCTAssertEqual(queue.enqueue(entry(context: context("B"))), .accepted)
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertTrue(queue.resolve(event()))
        XCTAssertEqual(queue.first?.id.context, context("B"))
    }

    func testRemovalAndRecreationRejectOldIncarnationAndPermitNewEventIdentity() {
        var queue = AttentionQueue()
        let replacement = context(incarnation: "inc-2")
        queue.reconcile(currentContexts: [context(), context("B")])
        XCTAssertEqual(queue.enqueue(entry()), .accepted)
        XCTAssertEqual(queue.enqueue(entry(context: context("B"))), .accepted)
        queue.reconcile(currentContexts: [replacement, context("B")])
        XCTAssertEqual(queue.entries, [entry(context: context("B"))])
        XCTAssertEqual(queue.enqueue(entry()), .unavailable)
        XCTAssertFalse(queue.resolve(event()))
        XCTAssertEqual(queue.enqueue(entry(context: replacement)), .accepted)
        XCTAssertEqual(queue.entries.map(\.id.context), [context("B"), replacement])
    }

    func testDisconnectAndReconnectDoNotRestorePendingOldGeneration() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context()])
        XCTAssertEqual(queue.enqueue(entry()), .accepted)
        queue.reconcile(currentContexts: [])
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertFalse(queue.requiresAttention)
        let reconnected = context(generation: nextGeneration)
        queue.reconcile(currentContexts: [reconnected])
        XCTAssertEqual(queue.enqueue(entry()), .unavailable)
        XCTAssertFalse(queue.resolve(event()))
        XCTAssertEqual(queue.enqueue(entry(context: reconnected)), .accepted)
    }

    func testAmbiguousIncarnationsOrGenerationsFailClosedOnlyForAffectedContext() {
        for conflicting in [context(incarnation: "inc-2"), context(generation: nextGeneration)] {
            var queue = AttentionQueue()
            queue.reconcile(currentContexts: [context(), context("B")])
            XCTAssertEqual(queue.enqueue(entry()), .accepted)
            XCTAssertEqual(queue.enqueue(entry(context: context("B"))), .accepted)
            queue.reconcile(currentContexts: [context(), conflicting, context("B"), context("")])
            XCTAssertEqual(queue.currentContexts, [context("B")])
            XCTAssertEqual(queue.entries, [entry(context: context("B"))])
            XCTAssertEqual(queue.enqueue(entry()), .unavailable)
            XCTAssertEqual(queue.enqueue(entry(context: conflicting)), .unavailable)
        }
    }

    func testUnresolvedEntriesAreNotEvictedByAnImplicitQueueCap() {
        var queue = AttentionQueue()
        queue.reconcile(currentContexts: [context()])
        let expected = (0..<129).map { entry("event-\($0)") }
        for item in expected { XCTAssertEqual(queue.enqueue(item), .accepted) }
        XCTAssertEqual(queue.entries, expected)
    }

    func testExplicitSelectionABAAndReselectionInvalidateCapturedPermits() throws {
        var gate = SelectedContentGate()
        let a = context(), b = context("B")
        let current: Set<ProductContextIdentity> = [a, b]
        XCTAssertNil(gate.selection)
        let firstA = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: current))
        XCTAssertTrue(gate.permits(firstA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
        let selectedB = try XCTUnwrap(gate.select(b, target: target(b), currentContexts: current))
        XCTAssertFalse(gate.permits(firstA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
        // Reuse the external token deliberately: the gate must also own a revision.
        let secondA = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: current))
        XCTAssertNotEqual(firstA, secondA)
        XCTAssertFalse(gate.permits(firstA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
        XCTAssertFalse(gate.permits(selectedB, currentTarget: target(b), currentContexts: current, sessionPermits: true))
        XCTAssertTrue(gate.permits(secondA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
        let thirdA = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: current))
        XCTAssertNotEqual(secondA, thirdA)
        XCTAssertFalse(gate.permits(secondA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
        gate.clear()
        XCTAssertNil(gate.selection)
        XCTAssertFalse(gate.permits(thirdA, currentTarget: target(a), currentContexts: current, sessionPermits: true))
    }

    func testPermitRejectsChangedSelectionGenerationIncarnationRemovalAndFreshness() throws {
        var gate = SelectedContentGate()
        let a = context(), originalTarget = target(context())
        let permit = try XCTUnwrap(gate.select(a, target: originalTarget, currentContexts: [a]))
        for changedTarget in [target(a, selection: nextSelection), target(context("B")),
                              target(context(generation: nextGeneration)), target(context(incarnation: "inc-2"))] {
            XCTAssertFalse(gate.permits(permit, currentTarget: changedTarget, currentContexts: [a], sessionPermits: true))
        }
        let unavailableContexts: [Set<ProductContextIdentity>] = [[], [context("B")],
            [context(incarnation: "inc-2")], [context(generation: nextGeneration)]]
        for changedContexts in unavailableContexts {
            XCTAssertFalse(gate.permits(permit, currentTarget: originalTarget,
                                        currentContexts: changedContexts, sessionPermits: true))
        }
        XCTAssertFalse(gate.permits(permit, currentTarget: originalTarget, currentContexts: [a], sessionPermits: false))
        XCTAssertTrue(gate.permits(permit, currentTarget: originalTarget, currentContexts: [a], sessionPermits: true))
    }

    func testInvalidSelectionFailsClosedAndRevokesPreviousPermit() throws {
        let a = context()
        for invalidTarget in [target(context("B")), target(context(generation: nextGeneration))] {
            var gate = SelectedContentGate()
            let permit = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: [a]))
            XCTAssertNil(gate.select(a, target: invalidTarget, currentContexts: [a]))
            XCTAssertNil(gate.selection)
            XCTAssertFalse(gate.permits(permit, currentTarget: target(a), currentContexts: [a], sessionPermits: true))
        }
        var gate = SelectedContentGate()
        XCTAssertNil(gate.select(a, target: target(a), currentContexts: []))
        for invalid in [context(""), context(incarnation: "")] {
            XCTAssertNil(gate.select(invalid, target: target(invalid), currentContexts: [invalid]))
        }
    }

    func testContradictoryTargetIncarnationCannotAuthorizeSelectedContent() {
        // Privacy regression: a current metadata identity must not bless a target for
        // another incarnation, even if the caller independently permits that target.
        let a = context()
        let staleTarget = target(context(incarnation: "old-incarnation"))
        XCTAssertFalse(a.matches(staleTarget))
        var gate = SelectedContentGate()
        XCTAssertNil(gate.select(a, target: staleTarget, currentContexts: [a]))
        XCTAssertNil(gate.selection)
    }

    func testNilTargetIncarnationIsRejectedAndRevokesExistingSelection() throws {
        let a = context()
        let missingIncarnation = ChatTarget(context: a.contextID, generation: a.generation,
                                            selection: selection, incarnation: nil)
        XCTAssertFalse(a.matches(missingIncarnation))
        var gate = SelectedContentGate()
        let previous = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: [a]))
        XCTAssertFalse(gate.permits(previous, currentTarget: missingIncarnation,
                                    currentContexts: [a], sessionPermits: true))
        XCTAssertNil(gate.select(a, target: missingIncarnation, currentContexts: [a]))
        XCTAssertNil(gate.selection)
        XCTAssertFalse(gate.permits(previous, currentTarget: target(a),
                                    currentContexts: [a], sessionPermits: true),
                       "Rejected selection must not leave an older private-content permit usable")
    }

    func testFreshnessIsRecheckedBeforeDisplayingAnAlreadyAuthorizedResponse() throws {
        let json = """
        {"ok":true,"schema_version":1,"server_epoch":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
         "cursor":1,"reset":false,
         "contexts":[{"id":"A","name":"A","incarnation":"00000000-0000-0000-0000-000000000010","state":"idle","tool":"","running":false}],
         "events":[],"dropped":{"overflow":0,"contention":0,"invalid":0,"no_consumer":0}}
        """
        var session = LiveSessionState()
        let liveGeneration = session.begin()
        XCTAssertTrue(try session.accept(LiveEnvelope.decode(Data(json.utf8)), generation: liveGeneration, now: 10))
        let a = context(incarnation: "00000000-0000-0000-0000-000000000010", generation: liveGeneration)
        let capturedTarget = target(a)
        var gate = SelectedContentGate()
        let permit = try XCTUnwrap(gate.select(a, target: capturedTarget, currentContexts: [a]))
        for now in [10.0, 19.999] {
            XCTAssertTrue(gate.permits(permit, currentTarget: capturedTarget, currentContexts: [a],
                sessionPermits: session.permits(capturedTarget, selected: "A", selection: selection, now: now)))
        }
        for now in [20.0, 9.0, .nan, .infinity, -.infinity] {
            XCTAssertFalse(gate.permits(permit, currentTarget: capturedTarget, currentContexts: [a],
                sessionPermits: session.permits(capturedTarget, selected: "A", selection: selection, now: now)))
        }
        session.clear()
        XCTAssertFalse(gate.permits(permit, currentTarget: capturedTarget, currentContexts: [a],
            sessionPermits: session.permits(capturedTarget, selected: "A", selection: selection, now: 11)))
    }

    func testAlertArrivalResolutionAndCompletionNeverSelectPrivateChatContent() throws {
        let a = context(), b = context("B")
        var model = ExpandedPresentationModel()
        var gate = SelectedContentGate()
        model.reconcile(currentContexts: [a, b], hasActivity: true, now: 0)
        XCTAssertEqual(model.enqueueAttention(entry(context: b), now: 0), .accepted)
        XCTAssertNil(gate.selection)
        let permit = try XCTUnwrap(gate.select(a, target: target(a), currentContexts: [a, b]))
        XCTAssertTrue(model.enqueueCompletion(event("done", context: b), now: 1))
        XCTAssertTrue(model.resolveAttention(event(context: b), now: 2))
        model.tick(now: 8, isHovering: false, mouseMoved: false)
        XCTAssertEqual(gate.selection, permit)
        XCTAssertFalse(gate.permits(permit, currentTarget: target(b), currentContexts: [a, b], sessionPermits: true))
    }
}
