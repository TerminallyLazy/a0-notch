import XCTest
@testable import NotchCore

final class IslandWakePolicyTests: XCTestCase {
    func testHiddenIdleHasNoWake() {
        var model = ExpandedPresentationModel(now: 0)
        model.tick(now: 0, isHovering: false, mouseMoved: false)
        XCTAssertNil(IslandWakePolicy.nextDelay(model: model, now: 0, hovering: false))
    }
    func testPeekAndLeaveDeadlines() throws {
        var model = ExpandedPresentationModel(now: 0)
        model.tick(now: 0, isHovering: true, mouseMoved: true)
        XCTAssertEqual(model.mode, .peek)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 0, hovering: true)), 0.65, accuracy: 0.00001)
        model.tick(now: 0.1, isHovering: false, mouseMoved: true)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 0.1, hovering: false)), 0.6, accuracy: 0.00001)
    }
    func testCountdownBoundaryThenClose() throws {
        var model = ExpandedPresentationModel(now: 0)
        model.open(.overview, now: 0)
        model.tick(now: 0, isHovering: false, mouseMoved: false)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 0, hovering: false)), 50, accuracy: 0.00001)
        model.tick(now: 55, isHovering: false, mouseMoved: false)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 55, hovering: false)), 5, accuracy: 0.00001)
    }
    func testStationaryHoverStillHasAbsenceDeadline() throws {
        var model = ExpandedPresentationModel(now: 0)
        model.open(.overview, now: 0)
        model.tick(now: 0, isHovering: true, mouseMoved: true)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 0, hovering: true)), 180, accuracy: 0.00001)
    }
    func testCompletionAndProtectedAlert() throws {
        let context = ProductContextIdentity(generation: UUID(), contextID: "test", incarnation: "one")
        let event = ProductEventIdentity(context: context, eventID: "done")
        var model = ExpandedPresentationModel(now: 0)
        model.reconcile(currentContexts: [context], hasActivity: true, now: 0)
        XCTAssertTrue(model.enqueueCompletion(event, now: 0))
        model.tick(now: 1, isHovering: false, mouseMoved: false)
        XCTAssertEqual(try XCTUnwrap(IslandWakePolicy.nextDelay(model: model, now: 1, hovering: false)), 4.2, accuracy: 0.00001)
        let alert = ProductEventIdentity(context: context, eventID: "attention")
        _ = model.enqueueAttention(.init(id: alert, kind: .intervention), now: 1)
        XCTAssertNil(IslandWakePolicy.nextDelay(model: model, now: 1, hovering: false))
    }
    func testStrictEuclideanDragThreshold() {
        XCTAssertFalse(IslandWakePolicy.beginsDrag(from: .zero, to: CGPoint(x: 7, y: 0)))
        XCTAssertFalse(IslandWakePolicy.beginsDrag(from: .zero, to: CGPoint(x: 4, y: 5)))
        XCTAssertTrue(IslandWakePolicy.beginsDrag(from: .zero, to: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(IslandWakePolicy.beginsDrag(from: CGPoint(x: -100, y: 40), to: CGPoint(x: -107.01, y: 40)))
    }
}
