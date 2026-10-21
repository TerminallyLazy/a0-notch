import Foundation
import NotchCore

/// A single persistent render tree consumes the same geometry as the native hit test.
/// Context identity is never a layout position: a focus change moves the existing node.
enum IslandAvatarLayout {
    /// Solve cubic-bezier x for time; y may exceed one only for opening.
    static func transitionFraction(_ progress: Double, opening: Bool) -> Double {
        let p = min(1, max(0, progress))
        if p == 0 || p == 1 { return p }
        let x1 = opening ? 0.32 : 0.45, x2 = opening ? 0.42 : 0.2
        let y1 = opening ? 1.22 : 0.0
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if cubic(mid, x1, x2) < p { low = mid } else { high = mid }
        }
        return cubic((low + high) / 2, y1, 1)
    }
    static func geometry(from: IslandGeometry, to: IslandGeometry, fraction: Double) -> IslandGeometry {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return IslandGeometry(size: CGSize(width: mix(from.size.width, to.size.width), height: mix(from.size.height, to.size.height)),
            bottomRadius: mix(from.bottomRadius, to.bottomRadius), restrictBelow: to.restrictBelow,
            topRadius: mix(from.topRadius, to.topRadius), topOffset: mix(from.topOffset, to.topOffset))
    }
    struct Pose: Equatable {
        var center: CGPoint
        var side: Double
        var opacity: Double
    }
    static func expansion(height: Double, collapsedHeight: Double, expandedHeight: Double) -> Double {
        min(1.04, max(0, (height - collapsedHeight) / max(1, expandedHeight - collapsedHeight)))
    }
    static func pose(main: Bool, index: Int, count: Int, width: Double, height: Double,
                     inset: Double, expansion: Double, overview: Bool, hidden: Bool,
                     hasNotch: Bool, peek: Bool) -> Pose {
        let p = min(1.04, max(0, expansion))
        let compact = CGPoint(x: main ? (hidden ? width / 2 : peek ? 19 : 27) : width - 27 + (count == 1 ? 0 : (index % 2 == 0 ? -6 : 6)),
                              y: main ? min(height, 36) / 2 : min(height, 32) / 2 + (count > 2 ? (index < 2 ? -6 : 6) : 0))
        let expanded = CGPoint(x: main ? 65 : overview ? width - 74 + Double(index % 2) * 36 : width - 31,
                               y: main ? inset + 88 : inset + 58 + Double(overview ? index / 2 : index) * (overview ? 36 : 24))
        return Pose(center: CGPoint(x: compact.x + (expanded.x - compact.x) * p,
                                    y: compact.y + (expanded.y - compact.y) * p),
                    side: (main ? (peek ? 30.0 : 34.0) : 16.0) * (1 - p) + (main ? 96 : 28) * p,
                    opacity: hidden ? (main && !hasNotch ? 1 : p) : (peek && !main ? 0 : 1))
    }
}
