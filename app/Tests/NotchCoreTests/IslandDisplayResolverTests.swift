import Foundation
import CoreGraphics
import XCTest
import NotchCore

final class IslandDisplayResolverTests: XCTestCase {
    private var menu: DisplayDescriptor {
        DisplayDescriptor(id: "menu", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                          hasNotch: false, notchWidth: 0, notchHeight: 24)
    }
    private var notch: DisplayDescriptor {
        DisplayDescriptor(id: "notch", frame: CGRect(x: -1512, y: -100, width: 1512, height: 982),
                          hasNotch: true, notchWidth: 184, notchHeight: 32)
    }
    private var lower: DisplayDescriptor {
        DisplayDescriptor(id: "lower", frame: CGRect(x: 0, y: -900, width: 1440, height: 900),
                          hasNotch: false, notchWidth: 0, notchHeight: 22)
    }

    private func resolve(_ choice: IslandDisplayChoice, displays: [DisplayDescriptor]? = nil,
                         main: String? = "menu", cursor: CGPoint = .zero,
                         current: String? = nil, mode: IslandMode = .hidden,
                         dragging: Bool = false) -> DisplayDescriptor? {
        IslandDisplayResolver.resolve(choice: choice, displays: displays ?? [menu, notch, lower],
                                      mainID: main, cursor: cursor, currentID: current,
                                      mode: mode, isDragging: dragging)
    }

    func testDisplayChoiceRoundTripsAllSupportedChoices() {
        for choice in [IslandDisplayChoice.notch, .menuBar, .followMouse, .display("stable-uuid")] {
            XCTAssertEqual(IslandDisplayChoice(rawValue: choice.rawValue), choice)
        }
    }

    func testMalformedChoiceDefaultsToNotch() {
        for raw in ["", "display:", "unknown", "MenuBar"] {
            XCTAssertEqual(IslandDisplayChoice(rawValue: raw), .notch)
        }
    }

    func testNotchPreferredOverMain() {
        XCTAssertEqual(resolve(.notch), notch)
    }

    func testNoNotchUsesMainRatherThanFirstDisplay() {
        XCTAssertEqual(resolve(.notch, displays: [menu, lower], main: "lower"), lower)
    }

    func testMissingMainUsesFirstDisplay() {
        XCTAssertEqual(resolve(.notch, displays: [lower, menu], main: "missing"), lower)
    }

    func testMenuBarUsesArrayOrderRatherThanMainID() {
        XCTAssertEqual(resolve(.menuBar, main: "notch"), menu)
    }

    func testSpecificConnectedDisplayWinsOverNotch() {
        XCTAssertEqual(resolve(.display("lower")), lower)
    }

    func testDisconnectedSpecificDisplayFallsBackToNotch() {
        XCTAssertEqual(resolve(.display("missing")), notch)
    }

    func testDisconnectedSpecificDisplayFallsBackToMainWithoutNotch() {
        XCTAssertEqual(resolve(.display("missing"), displays: [menu, lower], main: "lower"), lower)
    }

    func testReconnectedSpecificDisplayIsSelectedAgain() {
        let choice = IslandDisplayChoice.display("lower")
        XCTAssertEqual(resolve(choice, displays: [menu, notch]), notch)
        XCTAssertEqual(resolve(choice), lower)
        XCTAssertEqual(choice.rawValue, "display:lower")
    }

    func testEmptyDisplayListReturnsNilForEveryChoice() {
        for choice in [IslandDisplayChoice.notch, .menuBar, .followMouse, .display("saved")] {
            XCTAssertNil(resolve(choice, displays: []))
        }
    }

    func testFollowMouseHandlesNegativeHorizontalCoordinates() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: -1000, y: 100), current: "menu"), notch)
    }

    func testFollowMouseHandlesNegativeVerticalCoordinates() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: 500, y: -500), mode: .compact), lower)
    }

    func testSharedEdgeBelongsToDisplayBeginningAtEdge() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: 0, y: 100), current: "notch"), menu)
    }

    func testFollowMouseFreezesWhileExpanded() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: -1000, y: 100),
                               current: "menu", mode: .expanded), menu)
    }

    func testFollowMouseFreezesWhilePeeking() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: -1000, y: 100),
                               current: "menu", mode: .peek), menu)
    }

    func testFollowMouseFreezesDuringDragInCompactMode() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: -1000, y: 100),
                               current: "menu", mode: .compact, dragging: true), menu)
    }

    func testFrozenDisconnectedDisplayDoesNotPreventRecovery() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: 500, y: -500),
                               current: "removed", mode: .expanded, dragging: true), lower)
    }

    func testOffscreenCursorKeepsCurrentDisplay() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: 10000, y: 10000), current: "menu"), menu)
    }

    func testOffscreenCursorWithoutCurrentUsesNormalFallback() {
        XCTAssertEqual(resolve(.followMouse, cursor: CGPoint(x: 10000, y: 10000)), notch)
    }
}
