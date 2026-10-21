import Foundation
import XCTest
import NotchCore

final class ExpandedPresentationModelTests: XCTestCase {
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let nextGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

    private func context(_ id: String = "A", incarnation: String = "inc-1",
                         generation: UUID? = nil) -> ProductContextIdentity {
        ProductContextIdentity(generation: generation ?? self.generation,
                               contextID: id, incarnation: incarnation)
    }

    private func event(_ id: String = "done", context: ProductContextIdentity? = nil) -> ProductEventIdentity {
        ProductEventIdentity(context: context ?? self.context(), eventID: id)
    }

    private func alert(_ id: String = "alert", context: ProductContextIdentity? = nil,
                       kind: AttentionQueue.Kind = .intervention) -> AttentionQueue.Entry {
        AttentionQueue.Entry(id: event(id, context: context), kind: kind)
    }

    private func live(now: TimeInterval = 0, activity: Bool = true) -> ExpandedPresentationModel {
        var model = ExpandedPresentationModel(now: now)
        model.reconcile(currentContexts: [context(), context("B")], hasActivity: activity, now: now)
        return model
    }

    private func assertRemaining(_ model: ExpandedPresentationModel, _ expected: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let remaining = model.completionRemaining else {
            XCTFail("Expected a pending completion", file: file, line: line)
            return
        }
        XCTAssertEqual(remaining, expected, accuracy: 0.000000001, file: file, line: line)
    }

    func testInitialStateAndAuthoritativeDiscoveryDoNotAutomaticallyOpen() {
        var model = ExpandedPresentationModel()
        XCTAssertEqual(model.mode, .hidden)
        XCTAssertEqual(model.content, .view(.empty, nil))
        XCTAssertEqual(model.countdownFraction, 1)
        XCTAssertEqual(ExpandedPresentationModel.completionDuration, 5.2)
        XCTAssertNil(model.completionRemaining)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.reconcile(currentContexts: [context()], hasActivity: true, now: 0)
        XCTAssertEqual(model.content, .view(.overview, nil))
        XCTAssertEqual(model.mode, .hidden)
        model.tick(now: 0, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .compact)
    }

    func testCompletionExpiresAtExactlyFivePointTwoVisibleSecondsOnce() {
        var model = live()
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        XCTAssertEqual(model.content, .finished(event()))
        XCTAssertEqual(model.mode, .expanded)
        assertRemaining(model, 5.2)
        model.tick(now: 5.199, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .finished(event()))
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 5.2, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        XCTAssertNil(model.completionRemaining)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertEqual(model.content, .view(.overview, nil))
        XCTAssertEqual(model.mode, .compact)
        XCTAssertFalse(model.machine.attentionRequired)
        model.tick(now: 5.2, isHovering: false, mouseMoved: false)
        model.tick(now: 100, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        XCTAssertEqual(model.attention.currentContexts, [context(), context("B")],
                       "Expiration is presentation-only, never authoritative chat deletion")
    }

    func testCompletionExactDeadlineIsIndependentOfNonzeroClockOrigin() {
        var model = live(now: 10)
        XCTAssertTrue(model.enqueueCompletion(event(), now: 10))
        // Regression: subtracting 15.2 - 10 leaves 5.199999999999999,
        // so strict remaining <= 0 can miss the specified deadline.
        model.tick(now: 15.2, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        XCTAssertNil(model.completionRemaining)
        XCTAssertEqual(model.mode, .compact)
    }

    func testCompletionBehindTwoFIFOAlertsGetsItsFullVisibleBudget() {
        var model = live()
        let first = alert("first"), second = alert("second", context: context("B"), kind: .question)
        XCTAssertEqual(model.enqueueAttention(first, now: 0), .accepted)
        XCTAssertEqual(model.enqueueAttention(second, now: 1), .accepted)
        XCTAssertTrue(model.enqueueCompletion(event(), now: 2))
        model.tick(now: 500, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .attention(first))
        XCTAssertEqual(model.mode, .expanded)
        XCTAssertEqual(model.countdownFraction, 1)
        assertRemaining(model, 5.2)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        XCTAssertTrue(model.resolveAttention(first.id, now: 501))
        XCTAssertEqual(model.content, .attention(second))
        model.tick(now: 1000, isHovering: false, mouseMoved: false)
        assertRemaining(model, 5.2)
        XCTAssertTrue(model.resolveAttention(second.id, now: 1000))
        XCTAssertEqual(model.content, .finished(event()))
        XCTAssertEqual(model.mode, .expanded)
        model.tick(now: 1005.199, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .finished(event()))
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 1005.201, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        XCTAssertEqual(model.mode, .hidden, "No actual user movement occurred during the long alert")
    }

    func testMidCompletionPreemptionPreservesRemainingAcrossTwoAlerts() {
        var model = live()
        let first = alert("first"), second = alert("second", context: context("B"), kind: .error)
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        XCTAssertEqual(model.enqueueAttention(first, now: 2), .accepted)
        assertRemaining(model, 3.2)
        XCTAssertEqual(model.enqueueAttention(second, now: 3), .accepted)
        XCTAssertFalse(model.close(now: 4), "Escape must neither answer the alert nor discard completion")
        XCTAssertFalse(model.open(.prompt, context: context("B"), now: 5))
        model.interact(now: 6)
        model.tick(now: 10, isHovering: true, mouseMoved: true)
        assertRemaining(model, 3.2)
        XCTAssertEqual(model.content, .attention(first))
        XCTAssertTrue(model.resolveAttention(first.id, now: 11))
        XCTAssertEqual(model.content, .attention(second))
        XCTAssertFalse(model.resolveAttention(first.id, now: 12))
        XCTAssertEqual(model.content, .attention(second))
        XCTAssertTrue(model.resolveAttention(second.id, now: 20))
        XCTAssertEqual(model.content, .finished(event()))
        assertRemaining(model, 3.2)
        model.tick(now: 23.199, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 23.201, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        XCTAssertTrue(model.attention.entries.isEmpty)
    }

    func testAlertsRejectDuplicatesAndWrongResolutionWithoutReplacingHead() {
        var model = live()
        let first = alert(), second = alert("second", context: context("B"), kind: .error)
        XCTAssertEqual(model.enqueueAttention(first, now: 0), .accepted)
        XCTAssertEqual(model.enqueueAttention(second, now: 0), .accepted)
        XCTAssertEqual(model.enqueueAttention(alert(kind: .question), now: 1), .duplicate)
        for wrong in [event("unknown"), event("alert", context: context("B")),
                      event("alert", context: context(incarnation: "inc-2")),
                      event("alert", context: context(generation: nextGeneration))] {
            XCTAssertFalse(model.resolveAttention(wrong, now: 1))
            XCTAssertEqual(model.content, .attention(first))
            XCTAssertEqual(model.attention.entries, [first, second])
        }
        XCTAssertTrue(model.resolveAttention(first.id, now: 2))
        XCTAssertEqual(model.enqueueAttention(first, now: 3), .duplicate)
        XCTAssertEqual(model.content, .attention(second))
        XCTAssertTrue(model.resolveAttention(second.id, now: 4))
        XCTAssertFalse(model.machine.attentionRequired)
        XCTAssertEqual(model.mode, .compact)
    }

    func testAbsentUserAlertOpensAndEscapeCannotResolveIt() {
        var model = live()
        model.tick(now: 180, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .hidden)
        XCTAssertEqual(model.enqueueAttention(alert(), now: 200), .accepted)
        XCTAssertEqual(model.mode, .expanded)
        model.tick(now: 1000, isHovering: false, mouseMoved: false)
        XCTAssertFalse(model.close(now: 1000))
        XCTAssertEqual(model.content, .attention(alert()))
        XCTAssertEqual(model.attention.entries, [alert()])
        XCTAssertEqual(model.mode, .expanded)
        XCTAssertEqual(model.countdownFraction, 1)
        XCTAssertTrue(model.resolveAttention(event("alert"), now: 1001))
        XCTAssertEqual(model.mode, .hidden)
    }

    func testDelayedTickConsumesOnlyRenderedHeadAndPreservesCompletionFIFO() {
        var model = live()
        let first = event("one"), second = event("two", context: context("B")), third = event("three")
        for id in [first, second, third] { XCTAssertTrue(model.enqueueCompletion(id, now: 0)) }
        XCTAssertEqual(model.pendingCompletions, [first, second, third])
        model.tick(now: 100, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [first])
        XCTAssertEqual(model.content, .finished(second))
        XCTAssertEqual(model.pendingCompletions, [second, third])
        assertRemaining(model, 5.2)
        model.tick(now: 100, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 106, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [second])
        XCTAssertEqual(model.content, .finished(third))
        assertRemaining(model, 5.2)
        model.tick(now: 112, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [third])
        XCTAssertTrue(model.pendingCompletions.isEmpty)
    }

    func testDuplicateCompletionCannotRestartBudgetOrReplayAfterExpiry() {
        var model = live()
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        XCTAssertFalse(model.enqueueCompletion(event(), now: 2))
        assertRemaining(model, 3.2)
        model.tick(now: 6, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        model.reconcile(currentContexts: [context(), context("B")], hasActivity: true, now: 6)
        XCTAssertFalse(model.enqueueCompletion(event(), now: 7))
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        XCTAssertTrue(model.enqueueCompletion(event(context: context("B")), now: 7),
                      "Event IDs are scoped to full context identity")
    }

    func testCompletionDoesNotResolveAlertEvenWithIdenticalEventID() {
        var model = live()
        let intervention = alert("shared")
        XCTAssertEqual(model.enqueueAttention(intervention, now: 0), .accepted)
        XCTAssertTrue(model.enqueueCompletion(intervention.id, now: 1))
        model.tick(now: 20, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.attention.entries, [intervention])
        XCTAssertEqual(model.content, .attention(intervention))
        assertRemaining(model, 5.2)
        XCTAssertTrue(model.resolveAttention(intervention.id, now: 20))
        XCTAssertEqual(model.content, .finished(intervention.id))
    }

    func testHoverAndInteractionDoNotExtendCompletionVisibleBudget() {
        var model = live()
        XCTAssertTrue(model.configure(autoCloseSeconds: 1, absenceSeconds: 1))
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        model.tick(now: 2, isHovering: true, mouseMoved: true)
        model.interact(now: 3)
        model.tick(now: 5, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .expanded, "Completion remains protected from absence and auto-close")
        XCTAssertEqual(model.countdownFraction, 1)
        assertRemaining(model, 0.2)
        model.tick(now: 6, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        XCTAssertEqual(model.mode, .hidden)
    }

    func testUserNavigationAndEscapeDismissCompletionWithoutExpiryOrReplay() {
        for navigate in [false, true] {
            var model = live()
            XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
            XCTAssertTrue(model.enqueueCompletion(event("second"), now: 0))
            if navigate {
                XCTAssertTrue(model.open(.prompt, context: context("B"), now: 1))
                XCTAssertEqual(model.content, .view(.prompt, context("B")))
                XCTAssertEqual(model.mode, .expanded)
            } else {
                XCTAssertTrue(model.close(now: 1))
                XCTAssertEqual(model.mode, .compact)
            }
            XCTAssertTrue(model.pendingCompletions.isEmpty)
            XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
            XCTAssertFalse(model.enqueueCompletion(event(), now: 2))
            XCTAssertFalse(model.enqueueCompletion(event("second"), now: 2))
            XCTAssertEqual(model.attention.currentContexts.count, 2)
            model.tick(now: 100, isHovering: false, mouseMoved: false)
            XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        }
    }

    func testRemovedIncarnationClearsAlertsCompletionsAndContextBoundView() {
        var model = live()
        XCTAssertTrue(model.open(.result, context: context(), now: 0))
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        XCTAssertEqual(model.enqueueAttention(alert(), now: 1), .accepted)
        let replacement = context(incarnation: "inc-2")
        model.reconcile(currentContexts: [replacement, context("B")], hasActivity: true, now: 2)
        XCTAssertTrue(model.attention.entries.isEmpty)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        XCTAssertEqual(model.content, .view(.overview, nil))
        XCTAssertFalse(model.enqueueCompletion(event(), now: 2))
        XCTAssertEqual(model.enqueueAttention(alert(), now: 2), .unavailable)
        XCTAssertFalse(model.resolveAttention(event("alert"), now: 2))
        XCTAssertFalse(model.open(.result, context: context(), now: 2))
        XCTAssertTrue(model.enqueueCompletion(event(context: replacement), now: 2))
        XCTAssertEqual(model.content, .finished(event(context: replacement)))
    }

    func testRemovalOfHeadPreservesOtherContextsAndDoesNotChargeUnseenCompletion() {
        var model = live()
        let second = event("second", context: context("B"))
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        XCTAssertTrue(model.enqueueCompletion(second, now: 0))
        model.reconcile(currentContexts: [context("B")], hasActivity: true, now: 2)
        XCTAssertEqual(model.pendingCompletions, [second])
        XCTAssertEqual(model.content, .finished(second))
        assertRemaining(model, 5.2)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 7.199, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 7.201, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [second])
    }

    func testRemovingVisibleCompletionGivesSuccessorFullFivePointTwoSeconds() {
        var model = live(now: 10)
        let first = event("first"), second = event("second", context: context("B"))
        XCTAssertTrue(model.enqueueCompletion(first, now: 10))
        XCTAssertTrue(model.enqueueCompletion(second, now: 10))
        model.tick(now: 14, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .finished(first))
        assertRemaining(model, 1.2)

        model.reconcile(currentContexts: [context("B")], hasActivity: true, now: 14)
        XCTAssertEqual(model.pendingCompletions, [second])
        XCTAssertEqual(model.content, .finished(second))
        XCTAssertEqual(model.mode, .expanded)
        assertRemaining(model, 5.2)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)

        // The removed head's deadline was 15.2; the new head must not inherit it.
        model.tick(now: 15.2, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .finished(second))
        assertRemaining(model, 4)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 19.199, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.content, .finished(second))
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 19.2, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [second])
        XCTAssertNil(model.completionRemaining)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertEqual(model.mode, .compact)
        model.tick(now: 30, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
    }

    func testDisconnectDropsAllMetadataAndReconnectRequiresNewGeneration() {
        var model = live()
        XCTAssertTrue(model.open(.working, context: context(), now: 0))
        XCTAssertEqual(model.enqueueAttention(alert(), now: 0), .accepted)
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        model.reconcile(currentContexts: [], hasActivity: true, now: 1)
        XCTAssertEqual(model.content, .view(.empty, nil))
        XCTAssertEqual(model.mode, .hidden)
        XCTAssertFalse(model.machine.hasActivity)
        XCTAssertFalse(model.machine.attentionRequired)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertTrue(model.attention.entries.isEmpty)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        let reconnected = context(generation: nextGeneration)
        model.reconcile(currentContexts: [reconnected], hasActivity: true, now: 2)
        XCTAssertFalse(model.enqueueCompletion(event(), now: 2))
        XCTAssertEqual(model.enqueueAttention(alert(), now: 2), .unavailable)
        XCTAssertFalse(model.resolveAttention(event("alert"), now: 2))
        XCTAssertTrue(model.enqueueCompletion(event(context: reconnected), now: 2))
    }

    func testExpiredNotificationIsDiscardedWhenItsIncarnationIsRemovedBeforeDrain() {
        var model = live()
        XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
        model.tick(now: 6, isHovering: false, mouseMoved: false)
        model.reconcile(currentContexts: [context(incarnation: "inc-2")], hasActivity: true, now: 6)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty,
                      "An old completion must not reset a recreated context")
    }

    func testInvalidOrUnavailableEventsDoNotOpenOrDisturbOrdinaryContent() {
        var model = live()
        XCTAssertTrue(model.open(.prompt, context: context(), now: 0))
        for invalid in [event(""), event(context: context("missing")),
                        event(context: context(incarnation: "inc-2")),
                        event(context: context(generation: nextGeneration))] {
            XCTAssertFalse(model.enqueueCompletion(invalid, now: 1))
            XCTAssertEqual(model.enqueueAttention(.init(id: invalid, kind: .error), now: 1), .unavailable)
            XCTAssertEqual(model.content, .view(.prompt, context()))
            XCTAssertFalse(model.machine.attentionRequired)
        }
    }

    func testAllOrdinaryViewsSupportExplicitNavigationAndRejectUnavailableContext() {
        var model = live()
        for view in ExpandedPresentationModel.View.allCases {
            XCTAssertTrue(model.open(view, context: context(), now: 0))
            XCTAssertEqual(model.content, .view(view, context()))
            XCTAssertEqual(model.mode, .expanded)
            XCTAssertFalse(model.open(.result, context: context("missing"), now: 0))
            XCTAssertEqual(model.content, .view(view, context()))
        }
    }

    func testInvalidAndBackwardsClocksCannotSpendOrRestoreCompletionBudget() {
        var model = live(now: 10)
        XCTAssertTrue(model.enqueueCompletion(event(), now: 10))
        model.tick(now: 12, isHovering: false, mouseMoved: false)
        assertRemaining(model, 3.2)
        for now in [Double.nan, .infinity, -.infinity, -100, 10, 11, 12] {
            model.tick(now: now, isHovering: false, mouseMoved: false)
            assertRemaining(model, 3.2)
            XCTAssertEqual(model.content, .finished(event()))
            XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        }
        model.tick(now: 15.199, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
        model.tick(now: 15.201, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        model.tick(now: 12, isHovering: false, mouseMoved: false)
        XCTAssertTrue(model.takeExpiredCompletions().isEmpty)
    }

    func testInvalidInitialClocksNormalizeToZero() {
        for initial in [Double.nan, .infinity, -.infinity] {
            var model = live(now: initial)
            XCTAssertTrue(model.enqueueCompletion(event(), now: 0))
            model.tick(now: 5, isHovering: false, mouseMoved: false)
            assertRemaining(model, 0.2)
            model.tick(now: 6, isHovering: false, mouseMoved: false)
            XCTAssertEqual(model.takeExpiredCompletions(), [event()])
        }
    }

    func testConfigureRejectsInvalidPreferencesAtomicallyAndAcceptsZero() {
        var model = live()
        XCTAssertTrue(model.configure(autoCloseSeconds: 30, absenceSeconds: 90))
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(model.configure(autoCloseSeconds: invalid, absenceSeconds: 1))
            XCTAssertEqual(model.machine.autoCloseSeconds, 30)
            XCTAssertEqual(model.machine.absenceSeconds, 90)
            XCTAssertFalse(model.configure(autoCloseSeconds: 1, absenceSeconds: invalid))
            XCTAssertEqual(model.machine.autoCloseSeconds, 30)
            XCTAssertEqual(model.machine.absenceSeconds, 90)
        }
        XCTAssertTrue(model.configure(autoCloseSeconds: 0, absenceSeconds: 0))
        XCTAssertTrue(model.open(.prompt, now: 0))
        model.tick(now: 0, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .hidden)
        XCTAssertEqual(model.enqueueAttention(alert(), now: 0), .accepted)
        model.tick(now: 100, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .expanded)
    }

    func testOrdinaryAutoCloseCountdownAndPointerExitUseExistingMachine() {
        var model = live()
        XCTAssertTrue(model.open(.prompt, context: context(), now: 0))
        model.tick(now: 1, isHovering: false, mouseMoved: true)
        XCTAssertEqual(model.mode, .expanded)
        model.tick(now: 50, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.countdownFraction, 1)
        model.tick(now: 55, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.countdownFraction, 0.5, accuracy: 0.000001)
        model.tick(now: 54, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.countdownFraction, 0.5, accuracy: 0.000001)
        model.tick(now: 59.999, isHovering: false, mouseMoved: true)
        XCTAssertEqual(model.mode, .expanded)
        model.tick(now: 60, isHovering: false, mouseMoved: true)
        XCTAssertEqual(model.mode, .compact, "Outside movement is presence, not island interaction")
    }

    func testOrdinaryHoverAndExplicitInteractionResetAutoClose() {
        for useHover in [false, true] {
            var model = live()
            XCTAssertTrue(model.open(.prompt, now: 0))
            if useHover { model.tick(now: 50, isHovering: true, mouseMoved: false) }
            else { model.interact(now: 50) }
            model.tick(now: 109.999, isHovering: false, mouseMoved: false)
            XCTAssertEqual(model.mode, .expanded)
            model.tick(now: 110, isHovering: false, mouseMoved: false)
            XCTAssertEqual(model.mode, .compact)
        }
    }

    func testOrdinaryAbsenceAndMouseWakeUseExistingMachine() {
        var model = live()
        model.tick(now: 179.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .compact)
        model.tick(now: 180, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .hidden)
        model.tick(now: 181, isHovering: false, mouseMoved: true)
        XCTAssertEqual(model.mode, .compact)
        XCTAssertTrue(model.configure(autoCloseSeconds: 60, absenceSeconds: 5))
        XCTAssertTrue(model.open(.prompt, now: 182))
        model.tick(now: 186.999, isHovering: true, mouseMoved: false)
        XCTAssertEqual(model.mode, .expanded)
        model.tick(now: 187, isHovering: true, mouseMoved: false)
        XCTAssertEqual(model.mode, .hidden)
    }

    func testOrdinaryHiddenAndCompactHoverThresholdsAndEscapeSuppression() {
        var hidden = ExpandedPresentationModel()
        hidden.tick(now: 0, isHovering: true, mouseMoved: true)
        XCTAssertEqual(hidden.mode, .peek)
        hidden.tick(now: 0.649, isHovering: true, mouseMoved: false)
        XCTAssertEqual(hidden.mode, .peek)
        hidden.tick(now: 0.650, isHovering: true, mouseMoved: false)
        XCTAssertEqual(hidden.mode, .expanded)
        XCTAssertEqual(hidden.content, .view(.empty, nil))
        XCTAssertTrue(hidden.close(now: 1))
        hidden.tick(now: 2, isHovering: true, mouseMoved: true)
        XCTAssertEqual(hidden.mode, .hidden)
        hidden.tick(now: 3, isHovering: false, mouseMoved: true)
        hidden.tick(now: 4, isHovering: true, mouseMoved: true)
        XCTAssertEqual(hidden.mode, .peek)

        var compact = live()
        compact.tick(now: 0, isHovering: true, mouseMoved: true)
        compact.tick(now: 0.199, isHovering: true, mouseMoved: false)
        XCTAssertEqual(compact.mode, .compact)
        compact.tick(now: 0.200, isHovering: true, mouseMoved: false)
        XCTAssertEqual(compact.mode, .expanded)
        XCTAssertTrue(compact.close(now: 1))
        compact.tick(now: 2, isHovering: true, mouseMoved: true)
        XCTAssertEqual(compact.mode, .compact)
        compact.tick(now: 3, isHovering: false, mouseMoved: true)
        compact.tick(now: 4, isHovering: true, mouseMoved: true)
        compact.tick(now: 4.201, isHovering: true, mouseMoved: false)
        XCTAssertEqual(compact.mode, .expanded)
    }

    func testPeekExitStillUsesSixHundredMillisecondGrace() {
        var model = ExpandedPresentationModel()
        model.tick(now: 0, isHovering: true, mouseMoved: true)
        model.tick(now: 1, isHovering: false, mouseMoved: true)
        model.tick(now: 1.599, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .peek)
        model.tick(now: 1.6, isHovering: false, mouseMoved: false)
        XCTAssertEqual(model.mode, .hidden)
    }
}
