import Foundation

/// Presentation preferences only, never an allowlist, live registry, or authorization source.
/// Scope persisted DTOs to the authenticated server/account in the owning application.
public struct ContextPreferences: Equatable, Sendable {
    public static let maximumAdditionalPins = 4
    public static let maximumAliasLength = 80
    public static let palette = ["#38BDF8", "#FBBF24", "#14B8A6", "#CF6679", "#818CF8", "#22C55E"]

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidContextID, invalidAlias, invalidColorHex, invalidPaletteIndex
        case duplicateContextID, unknownContextID, duplicatePin, tooManyPins, mainAlsoPinned
    }

    /// Immutable so neither callers nor synthesized decoding can bypass validation.
    public struct Preference: Codable, Equatable, Sendable {
        public let contextID: String
        public let paletteIndex: Int
        public let alias: String?
        public let customColorHex: String?
        public var colorHex: String { customColorHex ?? ContextPreferences.palette[paletteIndex] }

        public init(contextID: String, paletteIndex: Int, alias: String? = nil, customColorHex: String? = nil) throws {
            try ContextPreferences.validateContextID(contextID)
            guard ContextPreferences.palette.indices.contains(paletteIndex) else {
                throw ValidationError.invalidPaletteIndex
            }
            self.contextID = contextID
            self.paletteIndex = paletteIndex
            self.alias = try ContextPreferences.normalizedAlias(alias)
            self.customColorHex = try ContextPreferences.normalizedColorHex(customColorHex)
        }

        private enum CodingKeys: String, CodingKey { case contextID, paletteIndex, alias, customColorHex }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let contextID = try container.decode(String.self, forKey: .contextID)
            let paletteIndex = try container.decode(Int.self, forKey: .paletteIndex)
            let alias = try container.decodeIfPresent(String.self, forKey: .alias)
            let color = try container.decodeIfPresent(String.self, forKey: .customColorHex)
            do {
                try self.init(contextID: contextID, paletteIndex: paletteIndex, alias: alias, customColorHex: color)
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid context preference: \(error)", underlyingError: error))
            }
        }
    }

    /// Versioned storage DTO. Contains no discovered names, current availability, or live state.
    /// Preferences are encoded in ID order; pins retain explicit user order. For byte-stable JSON,
    /// also set JSONEncoder.outputFormatting to .sortedKeys.
    public struct Persistence: Codable, Equatable, Sendable {
        public static let currentVersion = 1
        public let version: Int
        public let mainContextID: String?
        public let pinnedContextIDs: [String]
        public let preferences: [Preference]

        public init() {
            version = Self.currentVersion
            mainContextID = nil
            pinnedContextIDs = []
            preferences = []
        }

        public init(preferences: [Preference], mainContextID: String? = nil, pinnedContextIDs: [String] = []) throws {
            let known = Set(preferences.map(\.contextID))
            guard known.count == preferences.count else { throw ValidationError.duplicateContextID }
            if let mainContextID {
                try ContextPreferences.validateContextID(mainContextID)
                guard known.contains(mainContextID) else { throw ValidationError.unknownContextID }
            }
            guard Set(pinnedContextIDs).count == pinnedContextIDs.count else { throw ValidationError.duplicatePin }
            guard pinnedContextIDs.count <= ContextPreferences.maximumAdditionalPins else { throw ValidationError.tooManyPins }
            for id in pinnedContextIDs {
                try ContextPreferences.validateContextID(id)
                guard known.contains(id) else { throw ValidationError.unknownContextID }
                guard id != mainContextID else { throw ValidationError.mainAlsoPinned }
            }
            version = Self.currentVersion
            self.mainContextID = mainContextID
            self.pinnedContextIDs = pinnedContextIDs
            self.preferences = preferences.sorted { $0.contextID < $1.contextID }
        }

        private enum CodingKeys: String, CodingKey { case version, mainContextID, pinnedContextIDs, preferences }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                    debugDescription: "Unsupported context preferences version.")
            }
            let preferences = try container.decode([Preference].self, forKey: .preferences)
            let main = try container.decodeIfPresent(String.self, forKey: .mainContextID)
            let pins = try container.decode([String].self, forKey: .pinnedContextIDs)
            do {
                try self.init(preferences: preferences, mainContextID: main, pinnedContextIDs: pins)
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid context preferences: \(error)", underlyingError: error))
            }
        }
    }

    public private(set) var persistence: Persistence
    /// All currently discovered IDs in locale-independent ID order, including every unpinned ID.
    public private(set) var availableContextIDs: [String] = []
    public var mainContextID: String? { persistence.mainContextID }
    /// Additional pins only. Retained unavailable pins still occupy slots until explicitly unpinned.
    public var pinnedContextIDs: [String] { persistence.pinnedContextIDs }

    /// Restoring preferences does not claim that any context is currently available.
    public init(persistence: Persistence = Persistence()) {
        self.persistence = persistence
    }

    public func preference(for contextID: String) -> Preference? {
        persistence.preferences.first { $0.contextID == contextID }
    }

    /// The supplied discovered name is opaque and returned unchanged when no alias is set.
    public func displayName(for contextID: String, discoveredName: String) -> String {
        preference(for: contextID)?.alias ?? discoveredName
    }

    /// Main first, then explicit pin order, then every other available ID in ID order.
    /// Missing saved IDs never create ghost rows. This order must not change chat selection.
    public var orderedAvailableContextIDs: [String] {
        let available = Set(availableContextIDs)
        let preferred = ([mainContextID].compactMap { $0 } + pinnedContextIDs).filter { available.contains($0) }
        let preferredSet = Set(preferred)
        return preferred + availableContextIDs.filter { !preferredSet.contains($0) }
    }

    /// Replace availability with an authoritative discovery snapshot. Removal retains alias, color,
    /// main and pins for reconnection. New IDs are sorted within each batch before assigning the
    /// palette cyclically; existing assignments never shift, including after persistence/reload.
    /// IDs are opaque: no prefix, hierarchy, numeric interpretation, trimming, or case conversion.
    public mutating func reconcile(discoveredContextIDs: [String]) throws {
        for id in discoveredContextIDs { try Self.validateContextID(id) }
        let discovered = Set(discoveredContextIDs)
        guard discovered.count == discoveredContextIDs.count else { throw ValidationError.duplicateContextID }
        let ordered = discoveredContextIDs.sorted()
        let known = Set(persistence.preferences.map(\.contextID))
        var preferences = persistence.preferences
        for id in ordered where !known.contains(id) {
            preferences.append(try Preference(contextID: id, paletteIndex: preferences.count % Self.palette.count))
        }
        let next = try Persistence(preferences: preferences, mainContextID: mainContextID, pinnedContextIDs: pinnedContextIDs)
        persistence = next
        availableContextIDs = ordered
    }

    /// Select only a previously discovered ID (or nil). Promoting a pin removes its additional pin;
    /// the old main becomes ordinary, not automatically pinned. No implicit default main is chosen.
    public mutating func setMainContextID(_ contextID: String?) throws {
        if let contextID { try requireKnown(contextID) }
        persistence = try Persistence(preferences: persistence.preferences, mainContextID: contextID,
            pinnedContextIDs: pinnedContextIDs.filter { $0 != contextID })
    }

    /// Idempotent. The main is separately retained, so pinning/unpinning it is a no-op.
    /// Saved but unavailable IDs can be unpinned without waiting for them to return.
    public mutating func setPinned(_ pinned: Bool, for contextID: String) throws {
        try requireKnown(contextID)
        guard contextID != mainContextID else { return }
        var pins = pinnedContextIDs
        if pinned {
            if !pins.contains(contextID) { pins.append(contextID) }
        } else {
            pins.removeAll { $0 == contextID }
        }
        persistence = try Persistence(preferences: persistence.preferences, mainContextID: mainContextID, pinnedContextIDs: pins)
    }

    /// nil or whitespace-only clears an alias. Trimmed aliases have at most 80 Swift Characters;
    /// control characters and Unicode line/paragraph separators are rejected, not stripped.
    public mutating func setAlias(_ alias: String?, for contextID: String) throws {
        try requireKnown(contextID)
        let preferences = try persistence.preferences.map { preference in
            preference.contextID == contextID
                ? try Preference(contextID: contextID, paletteIndex: preference.paletteIndex,
                    alias: alias, customColorHex: preference.customColorHex)
                : preference
        }
        persistence = try Persistence(preferences: preferences, mainContextID: mainContextID, pinnedContextIDs: pinnedContextIDs)
    }

    /// Exactly #RRGGBB (ASCII hex, case-insensitive input); persisted uppercase. nil restores the
    /// original assigned palette color, not a newly allocated color. No shorthand or alpha channel.
    public mutating func setColorHex(_ colorHex: String?, for contextID: String) throws {
        try requireKnown(contextID)
        let preferences = try persistence.preferences.map { preference in
            preference.contextID == contextID
                ? try Preference(contextID: contextID, paletteIndex: preference.paletteIndex,
                    alias: preference.alias, customColorHex: colorHex)
                : preference
        }
        persistence = try Persistence(preferences: preferences, mainContextID: mainContextID, pinnedContextIDs: pinnedContextIDs)
    }

    private func requireKnown(_ contextID: String) throws {
        try Self.validateContextID(contextID)
        guard preference(for: contextID) != nil else { throw ValidationError.unknownContextID }
    }

    private static func containsLineOrControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    private static func validateContextID(_ value: String) throws {
        // Match the live protocol's length boundary, without assigning meaning to the ID.
        guard !value.isEmpty, value.count <= 128, !containsLineOrControl(value) else {
            throw ValidationError.invalidContextID
        }
    }

    private static func normalizedAlias(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard !containsLineOrControl(value) else { throw ValidationError.invalidAlias }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumAliasLength else { throw ValidationError.invalidAlias }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedColorHex(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw ValidationError.invalidColorHex }
        return value.uppercased()
    }
}
