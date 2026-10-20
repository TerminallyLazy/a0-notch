import Foundation
import CoreGraphics

public enum IslandMode: String, CaseIterable, Sendable {
    case hidden, peek, compact, expanded
}

public struct DisplayDescriptor: Equatable, Sendable {
    public let id: String
    public let frame: CGRect
    public let hasNotch: Bool
    public let notchWidth: Double
    /// On notchless displays, supply the menu-bar height (zero uses 24 pt).
    public let notchHeight: Double

    public init(id: String, frame: CGRect, hasNotch: Bool, notchWidth: Double, notchHeight: Double) {
        self.id = id
        self.frame = frame
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }
}

public enum IslandDisplayChoice: Equatable {
    case notch, menuBar, followMouse, display(String)

    public init(rawValue: String) {
        switch rawValue {
        case "notch": self = .notch
        case "menuBar": self = .menuBar
        case "followMouse": self = .followMouse
        default:
            let prefix = "display:"
            if rawValue.hasPrefix(prefix), rawValue.count > prefix.count {
                self = .display(String(rawValue.dropFirst(prefix.count)))
            } else {
                self = .notch
            }
        }
    }

    public var rawValue: String {
        switch self {
        case .notch: return "notch"
        case .menuBar: return "menuBar"
        case .followMouse: return "followMouse"
        case .display(let id): return "display:\(id)"
        }
    }
}

public enum IslandDisplayResolver {
    /// Preserve NSScreen.screens ordering: the first display owns the menu bar.
    public static func resolve(
        choice: IslandDisplayChoice,
        displays: [DisplayDescriptor],
        mainID: String?,
        cursor: CGPoint,
        currentID: String?,
        mode: IslandMode,
        isDragging: Bool
    ) -> DisplayDescriptor? {
        let main = displays.first { $0.id == mainID }
        let fallback = displays.first { $0.hasNotch } ?? main ?? displays.first
        switch choice {
        case .notch:
            return fallback
        case .menuBar:
            return displays.first
        case .display(let id):
            return displays.first { $0.id == id } ?? fallback
        case .followMouse:
            let current = displays.first { $0.id == currentID }
            if isDragging || mode == .peek || mode == .expanded {
                if let current { return current }
            }
            // Half-open frames provide deterministic ownership at shared edges.
            return displays.first { display in
                cursor.x >= display.frame.minX && cursor.x < display.frame.maxX
                    && cursor.y >= display.frame.minY && cursor.y < display.frame.maxY
            } ?? current ?? fallback
        }
    }
}
