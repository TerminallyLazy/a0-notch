import Foundation
import XCTest
import NotchCore

final class IslandStateMachineTests: XCTestCase {
    func testInitialStateIsHiddenAndDefaultsMatchSpecification() {
        let state = IslandStateMachine()
        XCTAssertEqual(state.mode, .hidden)
        XCTAssertFalse(state.hasActivity)
        XCTAssertEqual(state.autoCloseSeconds, 60)
        XCTAssertEqual(state.absenceSeconds, 180)
        XCTAssertEqual(state.countdownFraction, 1)
    }

    func testHiddenHoverPeeksImmediately() {
        var state = IslandStateMachine()
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        XCTAssertEqual(state.mode, .peek)
    }

    func testPeekExpandsAt650MillisecondsNotBefore() {
        var state = IslandStateMachine()
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        state.tick(now: 0.649, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .peek)
        state.tick(now: 0.650, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testPeekLeavesAfter600MillisecondsNotBefore() {
        var state = IslandStateMachine()
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        state.tick(now: 0.25, isHovering: false, mouseMoved: true)
        state.tick(now: 0.849, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .peek)
        state.tick(now: 0.85, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testPeekReentryCancelsLeaveAndRestartsContinuousHoverDelay() {
        var state = IslandStateMachine()
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        state.tick(now: 0.25, isHovering: false, mouseMoved: true)
        state.tick(now: 0.5, isHovering: true, mouseMoved: true)
        state.tick(now: 1.149, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .peek)
        state.tick(now: 1.15, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testActivityBecomesCompactOnNextTick() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 0, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
    }

    func testActivityEndingHidesCompactMode() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 0, isHovering: false, mouseMoved: false)
        state.hasActivity = false
        state.tick(now: 1, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testCompactHoverExpandsAt200MillisecondsNotBefore() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        state.tick(now: 0.199, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
        state.tick(now: 0.200, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testCompactHoverExitResetsDelay() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 0, isHovering: true, mouseMoved: true)
        state.tick(now: 0.1, isHovering: false, mouseMoved: true)
        state.tick(now: 1, isHovering: true, mouseMoved: true)
        state.tick(now: 1.199, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
        state.tick(now: 1.2, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testExpandedDoesNotCloseOnPointerExit() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.tick(now: 1, isHovering: false, mouseMoved: true)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testExpandedAutoClosesExactlyAtTimeout() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.tick(now: 59.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 60, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testAutoCloseReturnsToCompactWhenActivityContinues() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.open(now: 0)
        state.tick(now: 60, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
    }

    func testHoverResetsExpandedInactivityClock() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.tick(now: 59, isHovering: true, mouseMoved: false)
        state.tick(now: 118.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 119, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testExplicitInteractionResetsInactivityClock() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.interact(now: 55)
        state.tick(now: 114.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 115, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testMouseMovementOutsideIslandDoesNotResetOpenInactivity() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.tick(now: 59, isHovering: false, mouseMoved: true)
        state.tick(now: 60, isHovering: false, mouseMoved: true)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testCountdownBeginsOnlyInFinalTenSeconds() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.tick(now: 49, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 1)
        state.tick(now: 50, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 1)
        state.tick(now: 55, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 0.5, accuracy: 0.000001)
        state.tick(now: 59.9, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 0.01, accuracy: 0.000001)
        state.interact(now: 59.9)
        XCTAssertEqual(state.countdownFraction, 1)
    }

    func testCustomAutoCloseTimeoutAndCountdown() {
        var state = IslandStateMachine()
        state.autoCloseSeconds = 8
        state.open(now: 10)
        XCTAssertEqual(state.countdownFraction, 0.8, accuracy: 0.000001)
        state.tick(now: 17, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 0.1, accuracy: 0.000001)
        state.tick(now: 18, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
        XCTAssertEqual(state.countdownFraction, 1)
    }

    func testAbsenceHidesAtExactBoundaryDespiteActivity() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 179.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
        state.tick(now: 180, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testMouseMovementWakesAbsentActiveIsland() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.tick(now: 180, isHovering: false, mouseMoved: false)
        state.tick(now: 181, isHovering: false, mouseMoved: true)
        XCTAssertEqual(state.mode, .compact)
    }

    func testMouseWakeWithoutActivityStaysHiddenOutsideIsland() {
        var state = IslandStateMachine()
        state.tick(now: 180, isHovering: false, mouseMoved: false)
        state.tick(now: 181, isHovering: false, mouseMoved: true)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testCustomAbsenceTimeoutAlsoHidesExpandedMode() {
        var state = IslandStateMachine()
        state.absenceSeconds = 5
        state.open(now: 0)
        state.tick(now: 4.999, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 5, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testCloseSuppressesHiddenHoverUntilExit() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.close(now: 1)
        state.tick(now: 2, isHovering: true, mouseMoved: true)
        state.tick(now: 3, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
        state.tick(now: 4, isHovering: false, mouseMoved: true)
        state.tick(now: 5, isHovering: true, mouseMoved: true)
        XCTAssertEqual(state.mode, .peek)
    }

    func testCloseSuppressesCompactHoverUntilExit() {
        var state = IslandStateMachine()
        state.hasActivity = true
        state.open(now: 0)
        state.close(now: 1)
        state.tick(now: 2, isHovering: true, mouseMoved: true)
        state.tick(now: 3, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .compact)
        state.tick(now: 4, isHovering: false, mouseMoved: true)
        state.tick(now: 5, isHovering: true, mouseMoved: true)
        state.tick(now: 5.2, isHovering: true, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testExplicitOpenOverridesCloseSuppression() {
        var state = IslandStateMachine()
        state.open(now: 0)
        state.close(now: 1)
        state.open(now: 2)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testForceSetsEveryModeAndResetsExpandedDeadline() {
        var state = IslandStateMachine()
        for mode in IslandMode.allCases {
            state.force(mode: mode, now: 10)
            XCTAssertEqual(state.mode, mode)
        }
        state.tick(now: 69.999, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 70, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }

    func testBackwardsTimestampCannotExtendCountdown() {
        var state = IslandStateMachine(now: 100)
        state.open(now: 100)
        state.tick(now: 155, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 0.5)
        state.tick(now: 150, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.countdownFraction, 0.5)
    }
}

extension IslandStateMachineTests {
    func testFinishedClosesAfterFivePointTwoSeconds() {
        var state = IslandStateMachine(now: 0)
        state.showFinished(now: 1)
        state.tick(now: 6.19, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 6.21, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }
    func testErrorSurvivesAbsenceUntilExplicitDismissal() {
        var state = IslandStateMachine(now: 0)
        state.showAttention(now: 1)
        state.tick(now: 500, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.showFinished(now: 501)
        XCTAssertTrue(state.attentionRequired)
        state.close(now: 502)
        XCTAssertEqual(state.mode, .hidden)
        XCTAssertFalse(state.attentionRequired)
    }
    func testInteractionCancelsFinishedDeadline() {
        var state = IslandStateMachine(now: 0)
        state.showFinished(now: 1)
        state.interact(now: 3)
        state.tick(now: 7, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .expanded)
        state.tick(now: 63, isHovering: false, mouseMoved: false)
        XCTAssertEqual(state.mode, .hidden)
    }
}
