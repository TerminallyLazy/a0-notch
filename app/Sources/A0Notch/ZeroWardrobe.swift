import Foundation
import Observation
import SwiftUI

public enum ZeroOutfit: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto, none, partyHat, beanie, crown, witchHat, santaHat, bunnyEars
    case bow, sunglasses, roundGlasses, scarf, haloRing
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: "Seasonal (automatic)"
        case .none: "No accessories"
        case .partyHat: "Party hat"
        case .beanie: "Beanie"
        case .crown: "Crown"
        case .witchHat: "Witch hat"
        case .santaHat: "Santa hat"
        case .bunnyEars: "Bunny ears"
        case .bow: "Bow"
        case .sunglasses: "Sunglasses"
        case .roundGlasses: "Round glasses"
        case .scarf: "Scarf"
        case .haloRing: "Zero halo"
        }
    }
    /// Deliberately explicit, locale-independent Gregorian seasonal windows.
    /// Spring ears use March 20–April 7, not a claim to compute religious holidays.
    public static func seasonal(at date: Date, timeZone: TimeZone = .current) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return .none }
        switch (month, day) {
        case (1, 1...3), (12, 31): return .partyHat
        case (12, 15...30): return .santaHat
        case (10, 24...31): return .witchHat
        case (3, 20...31), (4, 1...7): return .bunnyEars
        case (2, 14): return .bow
        case (1...2, _), (12, _): return .beanie
        default: return .none
        }
    }
}

@MainActor @Observable
public final class ZeroWardrobe {
    public private(set) var selected: ZeroOutfit
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "zeroOutfit") {
        self.defaults = defaults
        self.key = key
        selected = defaults.string(forKey: key).flatMap(ZeroOutfit.init(rawValue:)) ?? .auto
        // Unknown/deprecated IDs migrate once; valid IDs remain unchanged.
        defaults.set(selected.rawValue, forKey: key)
    }
    public func select(_ outfit: ZeroOutfit) {
        selected = outfit
        defaults.set(outfit.rawValue, forKey: key)
    }
    public func resolved(at date: Date = Date()) -> ZeroOutfit {
        selected == .auto ? .seasonal(at: date) : selected
    }
}

/// Embeddable in a popover, settings or a context menu; selection never sends agent input.
public struct WardrobeView: View {
    private let wardrobe: ZeroWardrobe
    private let onSelection: (ZeroOutfit) -> Void
    public init(wardrobe: ZeroWardrobe, onSelection: @escaping (ZeroOutfit) -> Void = { _ in }) {
        self.wardrobe = wardrobe
        self.onSelection = onSelection
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zero’s wardrobe").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ZeroOutfit.allCases) { outfit in
                    Button {
                        wardrobe.select(outfit)
                        onSelection(outfit)
                    } label: {
                        HStack {
                            Text(outfit.title)
                            Spacer(minLength: 2)
                            if wardrobe.selected == outfit { Image(systemName: "checkmark") }
                        }.frame(minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .tint(wardrobe.selected == outfit ? Color(red: 207/255, green: 102/255, blue: 121/255) : .gray)
                    .accessibilityLabel(outfit.title)
                    .accessibilityAddTraits(wardrobe.selected == outfit ? .isSelected : [])
                }
            }
        }.padding(14).frame(width: 330)
    }
}

/// Original vectors in the existing Zero 100-point character coordinate space.
/// Headwear follows the body's rigid roll; small spring offsets add cloth inertia.
enum ZeroAccessoryPainter {
    static let accent = Color(red: 207/255, green: 102/255, blue: 121/255)
    static func draw(_ outfit: ZeroOutfit, in context: GraphicsContext, time: Double, presence: Double, motion: Bool) {
        guard outfit != .none && outfit != .auto else { return }
        var c = context
        c.opacity *= presence
        let settle = motion ? sin(time * 18) * exp(-time * 7) * 3 : 0
        c.translateBy(x: settle, y: (1 - presence) * -9)
        func ellipse(_ r: CGRect, _ color: Color) { c.fill(Path(ellipseIn: r), with: .color(color)) }
        func box(_ r: CGRect, _ color: Color, _ radius: CGFloat = 2) {
            c.fill(Path(roundedRect: r, cornerRadius: radius), with: .color(color))
        }
        func polygon(_ points: [CGPoint], _ color: Color) {
            var p = Path(); p.addLines(points); p.closeSubpath(); c.fill(p, with: .color(color))
        }
        switch outfit {
        case .auto, .none: break
        case .partyHat:
            polygon([CGPoint(x: 33, y: 27), CGPoint(x: 48, y: 0), CGPoint(x: 64, y: 26)], accent)
            for i in 0..<3 { ellipse(CGRect(x: 43 + i * 4, y: 8 + i * 5, width: 3, height: 3), .white) }
            ellipse(CGRect(x: 44, y: 0, width: 7, height: 7), .yellow)
        case .beanie:
            ellipse(CGRect(x: 27, y: 9, width: 45, height: 29), Color(red: 0.17, green: 0.35, blue: 0.73))
            box(CGRect(x: 26, y: 24, width: 48, height: 8), accent, 4)
            ellipse(CGRect(x: 44, y: 3, width: 13, height: 12), accent)
            for x in stride(from: 33, through: 66, by: 6) {
                var p = Path(); p.move(to: CGPoint(x: x, y: 16)); p.addLine(to: CGPoint(x: x, y: 23))
                c.stroke(p, with: .color(.white.opacity(0.22)), lineWidth: 1)
            }
        case .crown:
            polygon([CGPoint(x: 29, y: 15), CGPoint(x: 40, y: 23), CGPoint(x: 50, y: 10), CGPoint(x: 60, y: 23), CGPoint(x: 72, y: 15), CGPoint(x: 67, y: 32), CGPoint(x: 33, y: 32)], Color(red: 0.98, green: 0.75, blue: 0.14))
            ellipse(CGRect(x: 47, y: 24, width: 6, height: 6), accent)
        case .witchHat:
            ellipse(CGRect(x: 19, y: 23, width: 63, height: 10), Color(red: 0.19, green: 0.16, blue: 0.29))
            polygon([CGPoint(x: 32, y: 27), CGPoint(x: 49, y: 1), CGPoint(x: 65, y: 7), CGPoint(x: 54, y: 9), CGPoint(x: 69, y: 27)], Color(red: 0.26, green: 0.22, blue: 0.37))
            box(CGRect(x: 35, y: 21, width: 29, height: 5), accent)
        case .santaHat:
            polygon([CGPoint(x: 28, y: 26), CGPoint(x: 42, y: 5), CGPoint(x: 63, y: 8), CGPoint(x: 73, y: 24), CGPoint(x: 58, y: 15), CGPoint(x: 66, y: 28)], accent)
            box(CGRect(x: 26, y: 25, width: 43, height: 8), .white, 4)
            ellipse(CGRect(x: 67, y: 18, width: 11, height: 11), .white)
        case .bunnyEars:
            for x in [34.0, 56.0] {
                ellipse(CGRect(x: x, y: 0, width: 12, height: 31), .white)
                ellipse(CGRect(x: x + 3, y: 4, width: 6, height: 23), accent.opacity(0.7))
            }
        case .bow:
            polygon([CGPoint(x: 61, y: 29), CGPoint(x: 48, y: 18), CGPoint(x: 47, y: 36)], accent)
            polygon([CGPoint(x: 61, y: 29), CGPoint(x: 74, y: 18), CGPoint(x: 75, y: 36)], accent)
            ellipse(CGRect(x: 57, y: 25, width: 8, height: 8), .white)
        case .sunglasses, .roundGlasses:
            let sunglasses = outfit == .sunglasses
            for x in [29.0, 54.0] {
                let lens = Path(roundedRect: CGRect(x: x, y: 41, width: 20, height: 17), cornerRadius: sunglasses ? 4 : 8.5)
                if sunglasses { c.fill(lens, with: .color(.black.opacity(0.92))) }
                c.stroke(lens, with: .color(sunglasses ? accent : Color.white.opacity(0.85)), lineWidth: 2)
            }
            var p = Path(); p.move(to: CGPoint(x: 49, y: 47)); p.addQuadCurve(to: CGPoint(x: 54, y: 47), control: CGPoint(x: 51, y: 43))
            c.stroke(p, with: .color(.white), lineWidth: 2)
        case .scarf:
            box(CGRect(x: 29, y: 71, width: 44, height: 9), accent, 4)
            var cloth = c
            cloth.translateBy(x: 62, y: 75)
            cloth.rotate(by: .radians(motion ? sin(time * 2.4) * 0.09 : 0))
            cloth.fill(Path(roundedRect: CGRect(x: -4, y: 0, width: 10, height: 19), cornerRadius: 3), with: .color(accent))
            for y in [80.0, 85.0] { box(CGRect(x: 58, y: y, width: 10, height: 2), .white.opacity(0.45), 0) }
        case .haloRing:
            let y = 12 + (motion ? sin(time * 2) * 1.5 : 0)
            let ring = Path(ellipseIn: CGRect(x: 29, y: y, width: 43, height: 10))
            var glow = c; glow.addFilter(.blur(radius: 3))
            glow.stroke(ring, with: .color(accent.opacity(0.6)), lineWidth: 4)
            c.stroke(ring, with: .color(accent), lineWidth: 1.7)
        }
    }
}
