import Foundation

/// Appearance is independent of which display hosts the island.
public enum IslandPresentation: String, CaseIterable, Sendable {
    case notch, capsule, slim

    public init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? .notch
    }

    public var title: String {
        switch self {
        case .notch: "Notch"
        case .capsule: "Floating Capsule"
        case .slim: "Slim Bar"
        }
    }

    public var expandedWidth: Double {
        switch self {
        case .notch: 640
        case .capsule: 560
        case .slim: 440
        }
    }

    public func contentHeight(hasContexts: Bool) -> Double {
        if self == .slim { return hasContexts ? 188 : 166 }
        return hasContexts ? 216 : 174
    }

    /// Last valid override wins. Invalid flags never mutate or mask saved preferences.
    public static func launchOverride(arguments: [String]) -> Self? {
        arguments.compactMap { argument in
            guard argument.hasPrefix("--presentation=") else { return nil }
            return Self(rawValue: String(argument.dropFirst("--presentation=".count)))
        }.last
    }
}
