import Foundation
import CoreGraphics
import XCTest
import NotchCore

final class IslandGeometryTests: XCTestCase {
    private func display(notched: Bool = true, height: Double = 32) -> DisplayDescriptor {
        DisplayDescriptor(id: "test", frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
                          hasNotch: notched, notchWidth: 184, notchHeight: height)
    }

    func testNotchedCollapsedSizesUseActualNotch() {
        XCTAssertEqual(IslandGeometry(display: display(), mode: .hidden, hasContexts: false).size,
                       CGSize(width: 184, height: 32))
        XCTAssertEqual(IslandGeometry(display: display(), mode: .peek, hasContexts: false).size,
                       CGSize(width: 248, height: 32))
        XCTAssertEqual(IslandGeometry(display: display(), mode: .compact, hasContexts: true).size,
                       CGSize(width: 288, height: 32))
    }

    func testExpandedSizeDependsOnContextPresence() {
        XCTAssertEqual(IslandGeometry(display: display(), mode: .expanded, hasContexts: true).size,
                       CGSize(width: 640, height: 248))
        XCTAssertEqual(IslandGeometry(display: display(), mode: .expanded, hasContexts: false).size,
                       CGSize(width: 640, height: 206))
    }

    func testNotchlessBarWidthsAndMaximumHeight() {
        let screen = display(notched: false, height: 30)
        XCTAssertEqual(IslandGeometry(display: screen, mode: .hidden, hasContexts: false).size,
                       CGSize(width: 80, height: 24))
        XCTAssertEqual(IslandGeometry(display: screen, mode: .peek, hasContexts: false).size,
                       CGSize(width: 144, height: 24))
        XCTAssertEqual(IslandGeometry(display: screen, mode: .compact, hasContexts: true).size,
                       CGSize(width: 240, height: 24))
    }

    func testShortMenuBarCapsHeight() {
        let geometry = IslandGeometry(display: display(notched: false, height: 20), mode: .hidden, hasContexts: false)
        XCTAssertEqual(geometry.size.height, 20)
    }

    func testMissingMenuBarMeasurementUses24Points() {
        let geometry = IslandGeometry(display: display(notched: false, height: 0), mode: .hidden, hasContexts: false)
        XCTAssertEqual(geometry.size.height, 24)
    }

    func testTopCornersAreSquareAtZeroMargin() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        XCTAssertTrue(geometry.contains(point: .zero, margin: 0))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 640, y: 0), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: -0.01, y: 0), margin: 0))
    }

    func testRoundedBottomRejectsBoundingBoxCorners() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 0, y: 248), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 640, y: 248), margin: 0))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 320, y: 248), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 320, y: 248.01), margin: 0))
    }

    func testRoundedBottomUsesCircularArcNotRectangularApproximation() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        // Radius 30; left center (30, 218). A 3:4:5 triangle gives an exact arc point.
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 12, y: 242), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 11.99, y: 242), margin: 0))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 628, y: 242), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 628.01, y: 242), margin: 0))
    }

    func testCollapsedBottomRadiusIs14Points() {
        let geometry = IslandGeometry(display: display(), mode: .hidden, hasContexts: false)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 0, y: 18), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 0, y: 18.01), margin: 0))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 14, y: 32), margin: 0))
    }

    func testDefaultMarginIncludesSixPointsButNotMore() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: -6, y: 40)))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: -6.01, y: 40)))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 320, y: 254)))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 320, y: 254.01)))
    }

    func testMarginPreservesRoundedBottomExclusion() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        XCTAssertFalse(geometry.contains(point: CGPoint(x: -6, y: 254)))
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 30, y: 254)))
    }

    func testNoNotchlessHoverRegionBelowBarEvenWithLargeMargin() {
        for mode in [IslandMode.hidden, .peek, .compact] {
            let geometry = IslandGeometry(display: display(notched: false), mode: mode, hasContexts: true)
            let center = geometry.size.width / 2
            XCTAssertTrue(geometry.contains(point: CGPoint(x: center, y: 24)))
            XCTAssertFalse(geometry.contains(point: CGPoint(x: center, y: 24.001)))
            XCTAssertFalse(geometry.contains(point: CGPoint(x: center, y: 25), margin: 100))
        }
    }

    func testNotchlessExpandedContentRemainsInteractiveBelowMenuBar() {
        let geometry = IslandGeometry(display: display(notched: false), mode: .expanded, hasContexts: true)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 320, y: 180)))
    }

    func testNegativeMarginDoesNotInvertHitRegion() {
        let geometry = IslandGeometry(display: display(), mode: .hidden, hasContexts: false)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 0, y: 0), margin: -10))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: -1, y: 0), margin: -10))
    }

    func testNonfinitePointIsNotInteractive() {
        let geometry = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        XCTAssertFalse(geometry.contains(point: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 0, y: CGFloat.infinity)))
    }
}

extension IslandGeometryTests {
    func testAnimatedGeometryUsesPresentedSizeInsteadOfTarget() {
        let geometry = IslandGeometry(size: CGSize(width: 400, height: 100), bottomRadius: 22, restrictBelow: false)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 200, y: 99), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 500, y: 90), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 1, y: 99), margin: 0))
    }
    func testAnimatedGeometrySeparatesHoverMarginFromClickInterception() {
        let geometry = IslandGeometry(size: CGSize(width: 240, height: 24), bottomRadius: 14, restrictBelow: true)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: -4, y: 2), margin: 6))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: -4, y: 2), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 120, y: 25), margin: 6))
    }
    func testAnimatedRadiusIsClampedToHeight() {
        let geometry = IslandGeometry(size: CGSize(width: 80, height: 24), bottomRadius: 100, restrictBelow: true)
        XCTAssertTrue(geometry.contains(point: CGPoint(x: 24, y: 24), margin: 0))
        XCTAssertFalse(geometry.contains(point: CGPoint(x: 0, y: 24), margin: 0))
    }
}
