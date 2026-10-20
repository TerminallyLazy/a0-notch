import Foundation
import CoreGraphics

/// One presented silhouette for native hit testing and SwiftUI rendering.
public struct IslandGeometry: Equatable {
    public let size: CGSize
    public let bottomRadius: Double
    public let topRadius: Double
    public let topOffset: Double
    public let restrictBelow: Bool

    public init(size: CGSize, bottomRadius: Double, restrictBelow: Bool,
                topRadius: Double = 0, topOffset: Double = 0) {
        self.size = size
        let top = max(0, min(topRadius, Double(size.width) / 2, Double(size.height) / 2))
        self.topRadius = top
        self.bottomRadius = max(0, min(bottomRadius, Double(size.width) / 2, Double(size.height) - top))
        self.topOffset = max(0, topOffset)
        self.restrictBelow = restrictBelow
    }

    public init(display: DisplayDescriptor, mode: IslandMode, hasContexts: Bool,
                presentation: IslandPresentation = .notch) {
        let menuHeight = display.notchHeight > 0 ? display.notchHeight : 24
        let attached = presentation == .notch
        let offset = attached ? 0 : menuHeight + (presentation == .capsule ? 10 : 6)
        let width: Double
        let height: Double
        if mode == .expanded {
            width = presentation.expandedWidth
            height = presentation.contentHeight(hasContexts: hasContexts) + (attached && display.hasNotch ? menuHeight : 0)
        } else if attached && display.hasNotch {
            let notchWidth = max(0, display.notchWidth)
            switch mode {
            case .hidden: width = notchWidth
            case .peek: width = notchWidth + 64
            case .compact: width = notchWidth + 104
            case .expanded: width = presentation.expandedWidth
            }
            height = max(0, display.notchHeight)
        } else {
            switch mode {
            case .hidden: width = 80
            case .peek: width = presentation == .capsule ? 160 : 144
            case .compact: width = presentation == .capsule ? 280 : (presentation == .slim ? 224 : 240)
            case .expanded: width = presentation.expandedWidth
            }
            height = attached ? min(24, menuHeight) : (presentation == .capsule ? 36 : 24)
        }
        let radius = mode == .expanded ? (presentation == .slim ? 18.0 : (attached ? 30.0 : 26.0)) : (attached ? 14.0 : height / 2)
        self.init(size: CGSize(width: width, height: height), bottomRadius: radius,
                  restrictBelow: mode != .expanded && (!attached || !display.hasNotch), topRadius: attached ? 0 : radius, topOffset: offset)
    }

    /// Interpolation is bounded; the rendering and hit-test loop consume this same value.
    public func interpolated(to target: Self, fraction: Double) -> Self {
        let f = min(1, max(0, fraction))
        if f == 0 { return self }
        if f == 1 { return target }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return Self(size: CGSize(width: mix(size.width, target.size.width), height: mix(size.height, target.size.height)),
                    bottomRadius: mix(bottomRadius, target.bottomRadius), restrictBelow: target.restrictBelow,
                    topRadius: mix(topRadius, target.topRadius), topOffset: mix(topOffset, target.topOffset))
    }

    public func contentTopInset(hardwareNotchHeight: Double) -> Double {
        max(0, hardwareNotchHeight - topOffset)
    }

    public func frame(panelWidth: Double = 720) -> CGRect {
        CGRect(x: (panelWidth - size.width) / 2, y: topOffset, width: size.width, height: size.height)
    }

    public func containsPanelPoint(_ point: CGPoint, panelWidth: Double = 720, margin: Double = 0) -> Bool {
        let rect = frame(panelWidth: panelWidth)
        return contains(point: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY), margin: margin)
    }

    /// Local top-left coordinates. Only hover has a margin; clicks use zero.
    public func contains(point: CGPoint, margin: Double = 6) -> Bool {
        let width = Double(size.width), height = Double(size.height)
        let x = Double(point.x), y = Double(point.y)
        guard width > 0, height > 0, x.isFinite, y.isFinite, margin.isFinite else { return false }
        let padding = max(0, margin)
        guard x >= -padding, x <= width + padding, y >= -padding, y <= height + padding else { return false }
        if restrictBelow && y > height { return false }
        let radius: Double, centerY: Double
        if topRadius > 0 && y < topRadius {
            radius = topRadius; centerY = topRadius
        } else if y > height - bottomRadius {
            radius = bottomRadius; centerY = height - bottomRadius
        } else { return true }
        let centerX: Double
        if x < radius { centerX = radius }
        else if x > width - radius { centerX = width - radius }
        else { return true }
        let dx = x - centerX, dy = y - centerY
        return dx * dx + dy * dy <= (radius + padding) * (radius + padding)
    }

    /// Circular corners, not continuous/squircle corners: identical to contains().
    public var path: CGPath {
        let p = CGMutablePath()
        let w = Double(size.width), h = Double(size.height), t = topRadius, b = bottomRadius
        p.move(to: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: w - t, y: 0))
        if t > 0 { p.addArc(center: CGPoint(x: w - t, y: t), radius: t, startAngle: -.pi / 2, endAngle: 0, clockwise: false) }
        p.addLine(to: CGPoint(x: w, y: h - b))
        if b > 0 { p.addArc(center: CGPoint(x: w - b, y: h - b), radius: b, startAngle: 0, endAngle: .pi / 2, clockwise: false) }
        p.addLine(to: CGPoint(x: b, y: h))
        if b > 0 { p.addArc(center: CGPoint(x: b, y: h - b), radius: b, startAngle: .pi / 2, endAngle: .pi, clockwise: false) }
        p.addLine(to: CGPoint(x: 0, y: t))
        if t > 0 { p.addArc(center: CGPoint(x: t, y: t), radius: t, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false) }
        p.closeSubpath()
        return p
    }
}
