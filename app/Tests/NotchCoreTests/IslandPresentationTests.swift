import XCTest
import CoreGraphics
import NotchCore

final class IslandPresentationTests: XCTestCase {
    private func display(notched: Bool = true) -> DisplayDescriptor {
        DisplayDescriptor(id: "test", frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
                          hasNotch: notched, notchWidth: 184, notchHeight: notched ? 32 : 24)
    }

    func testPersistedChoicesRoundTripAndInvalidFallsBackToNotch() {
        for choice in IslandPresentation.allCases {
            XCTAssertEqual(IslandPresentation(persistedValue: choice.rawValue), choice)
        }
        for invalid in [nil, "", "floating", "CAPSULE", "slim "] as [String?] {
            XCTAssertEqual(IslandPresentation(persistedValue: invalid), .notch)
        }
    }

    func testLaunchOverridesAreExplicitAndLastValidWins() {
        for choice in IslandPresentation.allCases {
            XCTAssertEqual(IslandPresentation.launchOverride(arguments: ["app", "--presentation=\(choice.rawValue)"]), choice)
        }
        XCTAssertNil(IslandPresentation.launchOverride(arguments: ["--overview", "--presentation=invalid"]))
        XCTAssertEqual(IslandPresentation.launchOverride(arguments: ["--presentation=capsule", "--presentation=slim", "--presentation=bad"]), .slim)
        XCTAssertNil(IslandPresentation.launchOverride(arguments: ["presentation=capsule"]))
    }

    func testExpandedDimensionsAndOffsetsAreDistinct() {
        let cases: [(IslandPresentation, CGSize, Double, Double)] = [
            (.notch, CGSize(width: 640, height: 248), 0, 0),
            (.capsule, CGSize(width: 560, height: 216), 42, 26),
            (.slim, CGSize(width: 440, height: 188), 38, 18)
        ]
        for (choice, size, offset, radius) in cases {
            let g = IslandGeometry(display: display(), mode: .expanded, hasContexts: true, presentation: choice)
            XCTAssertEqual(g.size, size)
            XCTAssertEqual(g.topOffset, offset)
            XCTAssertEqual(g.topRadius, radius)
            XCTAssertEqual(g.frame().midX, 360)
        }
    }

    func testDetachedChoicesClearMenuBarOnNotchlessDisplays() {
        for (choice, offset) in [(IslandPresentation.capsule, 34.0), (.slim, 30.0)] {
            for mode in IslandMode.allCases {
                let g = IslandGeometry(display: display(notched: false), mode: mode, hasContexts: true, presentation: choice)
                XCTAssertEqual(g.topOffset, offset)
                XCTAssertGreaterThan(g.topRadius, 0)
                XCTAssertFalse(g.containsPanelPoint(CGPoint(x: 360, y: offset - 0.01)))
            }
        }
    }

    func testDetachedCompactSizesAndIdleHandle() {
        for (choice, width, height) in [(IslandPresentation.capsule, 280.0, 36.0), (.slim, 224.0, 24.0)] {
            let compact = IslandGeometry(display: display(), mode: .compact, hasContexts: true, presentation: choice)
            XCTAssertEqual(compact.size, CGSize(width: width, height: height))
            let hidden = IslandGeometry(display: display(), mode: .hidden, hasContexts: false, presentation: choice)
            XCTAssertEqual(hidden.size.width, 80)
            XCTAssertEqual(hidden.size.height, height)
            XCTAssertFalse(hidden.contains(point: CGPoint(x: 40, y: height + 0.1), margin: 6))
        }
    }

    func testAllPresentationModesFitHostAndKeepTransparentMargins() {
        for notched in [false, true] {
            for choice in IslandPresentation.allCases {
                for mode in IslandMode.allCases {
                    for hasContexts in [false, true] {
                        let g = IslandGeometry(display: display(notched: notched), mode: mode, hasContexts: hasContexts, presentation: choice)
                        XCTAssertLessThanOrEqual(g.frame().maxY, 320)
                        XCTAssertGreaterThan(g.frame().minX, 0)
                        XCTAssertFalse(g.containsPanelPoint(CGPoint(x: 1, y: 1)))
                        XCTAssertTrue(g.containsPanelPoint(CGPoint(x: 360, y: g.frame().midY)))
                    }
                }
            }
        }
    }

    func testRoundedTopCornersRejectInvisibleBoundsAndMatchCircularArc() {
        let g = IslandGeometry(size: CGSize(width: 200, height: 100), bottomRadius: 30,
                               restrictBelow: false, topRadius: 30, topOffset: 40)
        XCTAssertFalse(g.contains(point: .zero, margin: 0))
        XCTAssertFalse(g.contains(point: CGPoint(x: 200, y: 0), margin: 0))
        // Circle centered at (30,30), radius 30; 18² + 24² = 30².
        XCTAssertTrue(g.contains(point: CGPoint(x: 12, y: 6), margin: 0))
        XCTAssertFalse(g.contains(point: CGPoint(x: 11.99, y: 6), margin: 0))
        XCTAssertTrue(g.contains(point: CGPoint(x: 188, y: 6), margin: 0))
        XCTAssertFalse(g.contains(point: CGPoint(x: 188.01, y: 6), margin: 0))
    }

    func testAnimationInterpolatesOffsetCornersAndBoundsWithoutGhostRegions() {
        let source = IslandGeometry(display: display(), mode: .expanded, hasContexts: true)
        let target = IslandGeometry(display: display(), mode: .expanded, hasContexts: true, presentation: .capsule)
        let halfway = source.interpolated(to: target, fraction: 0.5)
        XCTAssertEqual(halfway.size, CGSize(width: 600, height: 232))
        XCTAssertEqual(halfway.topOffset, 21)
        XCTAssertEqual(halfway.topRadius, 13)
        XCTAssertEqual(halfway.bottomRadius, 28)
        XCTAssertFalse(halfway.containsPanelPoint(CGPoint(x: 360, y: 20.9)))
        XCTAssertFalse(halfway.containsPanelPoint(CGPoint(x: 50, y: 100)))
        XCTAssertFalse(halfway.containsPanelPoint(CGPoint(x: 60, y: 21)))
        XCTAssertTrue(halfway.containsPanelPoint(CGPoint(x: 360, y: 22)))
        XCTAssertEqual(source.interpolated(to: target, fraction: -1), source)
        XCTAssertEqual(source.interpolated(to: target, fraction: 2), target)
    }

    func testSafeContentOriginClearsHardwareCutoutThroughoutTransition() {
        for sourceChoice in IslandPresentation.allCases {
            for targetChoice in IslandPresentation.allCases {
                let a = IslandGeometry(display: display(), mode: .expanded, hasContexts: true, presentation: sourceChoice)
                let b = IslandGeometry(display: display(), mode: .expanded, hasContexts: true, presentation: targetChoice)
                for step in 0...10 {
                    let g = a.interpolated(to: b, fraction: Double(step) / 10)
                    XCTAssertGreaterThanOrEqual(g.topOffset + g.contentTopInset(hardwareNotchHeight: 32), 32)
                }
            }
        }
    }

    func testDrawnPathAndAnalyticHitTestAgreeAtIntermediateFrames() {
        let a = IslandGeometry(display: display(), mode: .compact, hasContexts: true)
        for choice in IslandPresentation.allCases {
            let b = IslandGeometry(display: display(), mode: .expanded, hasContexts: true, presentation: choice)
            for step in 0...10 {
                let g = a.interpolated(to: b, fraction: Double(step) / 10)
                for x in stride(from: -1.37, to: g.size.width + 2, by: 7.0) {
                    for y in stride(from: -1.37, to: g.size.height + 2, by: 7.0) {
                        let point = CGPoint(x: x, y: y)
                        XCTAssertEqual(g.path.contains(point), g.contains(point: point, margin: 0), "\(choice) frame \(step), \(point)")
                    }
                }
            }
        }
    }
}

extension IslandPresentationTests {
    func testAttachedNotchRetainsHoverGraceBelowHardwareBar() {
        let g = IslandGeometry(display: display(), mode: .compact, hasContexts: true)
        XCTAssertTrue(g.contains(point: CGPoint(x: 144, y: 38), margin: 6))
        XCTAssertFalse(g.contains(point: CGPoint(x: 144, y: 38.01), margin: 6))
        XCTAssertFalse(g.contains(point: CGPoint(x: 144, y: 32.01), margin: 0))
    }

    func testEmptyDimensionsRespectEachPresentationAndHardwareInset() {
        for (choice, height) in [(IslandPresentation.notch, 206.0), (.capsule, 174.0), (.slim, 166.0)] {
            let g = IslandGeometry(display: display(), mode: .expanded, hasContexts: false, presentation: choice)
            XCTAssertEqual(g.size.height, height)
            XCTAssertEqual(g.size.width, choice.expandedWidth)
        }
        let g = IslandGeometry(display: display(notched: false), mode: .expanded, hasContexts: false)
        XCTAssertEqual(g.size, CGSize(width: 640, height: 174))
    }

    func testInterpolationRetainsExactEndpointsAcrossDifferentHoverPolicies() {
        let a = IslandGeometry(display: display(), mode: .compact, hasContexts: true)
        let b = IslandGeometry(display: display(), mode: .compact, hasContexts: true, presentation: .capsule)
        XCTAssertNotEqual(a.restrictBelow, b.restrictBelow)
        XCTAssertEqual(a.interpolated(to: b, fraction: 0), a)
        XCTAssertEqual(a.interpolated(to: b, fraction: 1), b)
    }
}
