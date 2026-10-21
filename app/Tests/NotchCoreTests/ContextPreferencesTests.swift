import Foundation
import XCTest
import NotchCore

final class ContextPreferencesTests: XCTestCase {
    private typealias Model = ContextPreferences
    private typealias Failure = Model.ValidationError

    private func model(_ ids: [String] = ["a", "b", "c", "d", "e", "f", "g"]) throws -> Model {
        var value = Model()
        try value.reconcile(discoveredContextIDs: ids)
        return value
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func fixture() -> [String: Any] {
        ["version": 1, "mainContextID": "a", "pinnedContextIDs": ["b"],
         "preferences": [["contextID": "a", "paletteIndex": 0], ["contextID": "b", "paletteIndex": 1]]]
    }

    private func assertCorrupt(_ value: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try data(value)
        XCTAssertThrowsError(try JSONDecoder().decode(Model.Persistence.self, from: encoded), file: file, line: line) {
            guard case DecodingError.dataCorrupted = $0 else {
                return XCTFail("Expected dataCorrupted, got \($0)", file: file, line: line)
            }
        }
    }

    private func assertAtomicFailure(
        _ value: inout Model, _ expected: Failure,
        file: StaticString = #filePath, line: UInt = #line,
        operation: (inout Model) throws -> Void
    ) {
        let before = value
        XCTAssertThrowsError(try operation(&value), file: file, line: line) {
            XCTAssertEqual($0 as? Failure, expected, file: file, line: line)
        }
        XCTAssertEqual(value, before, file: file, line: line)
    }

    func testEmptyDefaultsAndUnknownLookup() {
        let value = Model()
        XCTAssertNil(value.mainContextID)
        XCTAssertTrue(value.pinnedContextIDs.isEmpty)
        XCTAssertTrue(value.availableContextIDs.isEmpty)
        XCTAssertTrue(value.orderedAvailableContextIDs.isEmpty)
        XCTAssertEqual(value.persistence.version, 1)
        XCTAssertTrue(value.persistence.preferences.isEmpty)
        XCTAssertNil(value.preference(for: "unknown"))
        XCTAssertEqual(value.displayName(for: "unknown", discoveredName: "  Original / 名称  "), "  Original / 名称  ")
    }

    func testDiscoveryHasNoPinOrFiveContextLimit() throws {
        let ids = (0..<1000).map { "ctx_\($0)" }
        var value = try model(ids)
        XCTAssertNil(value.mainContextID)
        XCTAssertEqual(value.availableContextIDs.count, 1000)
        XCTAssertEqual(value.availableContextIDs, ids.sorted())
        try value.setMainContextID("ctx_999")
        for id in ["ctx_8", "ctx_7", "ctx_6", "ctx_5"] { try value.setPinned(true, for: id) }
        XCTAssertEqual(Array(value.orderedAvailableContextIDs.prefix(5)), ["ctx_999", "ctx_8", "ctx_7", "ctx_6", "ctx_5"])
        XCTAssertEqual(Set(value.orderedAvailableContextIDs), Set(ids))
        XCTAssertEqual(value.orderedAvailableContextIDs.count, 1000)
    }

    func testPaletteIsCanonicalCyclicAndBatchOrderIndependent() throws {
        let expected = ["#38BDF8", "#FBBF24", "#14B8A6", "#CF6679", "#818CF8", "#22C55E", "#38BDF8"]
        var forward = try model()
        let reverse = try model(["g", "f", "e", "d", "c", "b", "a"])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.persistence.preferences.map(\.colorHex), expected)
        let before = forward
        try forward.reconcile(discoveredContextIDs: ["g", "a", "c", "e", "f", "d", "b"])
        XCTAssertEqual(forward, before)
    }

    func testPaletteDoesNotShiftForEarlierSortedNewIDsOrRemoval() throws {
        var value = try model(["z"])
        XCTAssertEqual(value.preference(for: "z")?.colorHex, "#38BDF8")
        try value.reconcile(discoveredContextIDs: ["z", "a"])
        XCTAssertEqual(value.preference(for: "a")?.colorHex, "#FBBF24")
        try value.reconcile(discoveredContextIDs: ["b"])
        XCTAssertEqual(value.preference(for: "b")?.colorHex, "#14B8A6")
        XCTAssertEqual(value.preference(for: "z")?.colorHex, "#38BDF8")
        let bytes = try JSONEncoder().encode(value.persistence)
        var restored = Model(persistence: try JSONDecoder().decode(Model.Persistence.self, from: bytes))
        try restored.reconcile(discoveredContextIDs: ["z", "c", "a"])
        XCTAssertEqual(restored.preference(for: "c")?.colorHex, "#CF6679")
        XCTAssertEqual(restored.preference(for: "a")?.colorHex, "#FBBF24")
        XCTAssertEqual(restored.preference(for: "z")?.colorHex, "#38BDF8")
    }

    func testFourAdditionalPinsWithOrWithoutMainAndAtomicOverflow() throws {
        for main in [nil, "g"] as [String?] {
            var value = try model()
            try value.setMainContextID(main)
            for id in ["d", "b", "a", "c"] { try value.setPinned(true, for: id) }
            XCTAssertEqual(value.pinnedContextIDs, ["d", "b", "a", "c"])
            assertAtomicFailure(&value, .tooManyPins) { try $0.setPinned(true, for: "e") }
            let before = value
            try value.setPinned(true, for: "d")
            try value.setPinned(false, for: "f")
            XCTAssertEqual(value, before)
            try value.setPinned(false, for: "b")
            try value.setPinned(true, for: "e")
            XCTAssertEqual(value.pinnedContextIDs, ["d", "a", "c", "e"])
        }
    }

    func testMainIsSeparateFromPinsAndPromotionFreesSlot() throws {
        var value = try model()
        try value.setMainContextID("g")
        for id in ["a", "b", "c", "d"] { try value.setPinned(true, for: id) }
        let before = value
        try value.setPinned(true, for: "g")
        try value.setPinned(false, for: "g")
        XCTAssertEqual(value, before)
        try value.setMainContextID("b")
        XCTAssertEqual(value.pinnedContextIDs, ["a", "c", "d"])
        XCTAssertEqual(value.mainContextID, "b")
        XCTAssertEqual(value.orderedAvailableContextIDs, ["b", "a", "c", "d", "e", "f", "g"])
        try value.setPinned(true, for: "e")
        try value.setMainContextID(nil)
        XCTAssertEqual(value.pinnedContextIDs, ["a", "c", "d", "e"])
        XCTAssertEqual(value.orderedAvailableContextIDs, ["a", "c", "d", "e", "b", "f", "g"])
    }

    func testRemovalRetainsPreferencesWithoutGhostAvailability() throws {
        var value = try model()
        try value.setMainContextID("g")
        for id in ["d", "c", "b", "a"] { try value.setPinned(true, for: id) }
        try value.setAlias("Research", for: "d")
        try value.setColorHex("#abcdef", for: "d")
        let saved = value.persistence
        try value.reconcile(discoveredContextIDs: ["e", "f"])
        XCTAssertEqual(value.persistence, saved)
        XCTAssertEqual(value.orderedAvailableContextIDs, ["e", "f"])
        assertAtomicFailure(&value, .tooManyPins) { try $0.setPinned(true, for: "e") }
        try value.reconcile(discoveredContextIDs: [])
        XCTAssertTrue(value.orderedAvailableContextIDs.isEmpty)
        XCTAssertEqual(value.persistence, saved)
        try value.reconcile(discoveredContextIDs: ["a", "b", "c", "d", "e", "f", "g"])
        XCTAssertEqual(value.persistence, saved)
        XCTAssertEqual(value.orderedAvailableContextIDs, ["g", "d", "c", "b", "a", "e", "f"])
        XCTAssertEqual(value.preference(for: "d")?.alias, "Research")
        XCTAssertEqual(value.preference(for: "d")?.colorHex, "#ABCDEF")
    }

    func testUnavailableSavedPreferencesRemainEditable() throws {
        var value = try model(["a", "b"])
        try value.setPinned(true, for: "a")
        try value.reconcile(discoveredContextIDs: [])
        try value.setPinned(false, for: "a")
        try value.setAlias("Later", for: "a")
        try value.setColorHex("#123456", for: "a")
        try value.setMainContextID("b")
        XCTAssertTrue(value.pinnedContextIDs.isEmpty)
        XCTAssertTrue(value.availableContextIDs.isEmpty)
        XCTAssertEqual(value.preference(for: "a")?.alias, "Later")
        XCTAssertEqual(value.preference(for: "a")?.colorHex, "#123456")
    }

    func testAliasesAreTrimmedLimitedByCharactersAndClearable() throws {
        var value = try model(["a"])
        try value.setAlias("  Research 名称  ", for: "a")
        XCTAssertEqual(value.displayName(for: "a", discoveredName: "Original"), "Research 名称")
        let boundary = String(repeating: "👩🏽‍💻", count: 80)
        try value.setAlias(boundary, for: "a")
        XCTAssertEqual(value.preference(for: "a")?.alias, boundary)
        assertAtomicFailure(&value, .invalidAlias) { try $0.setAlias(boundary + "x", for: "a") }
        for blank in ["", "   ", "\u{00a0}", nil] as [String?] {
            try value.setAlias(blank, for: "a")
            XCTAssertNil(value.preference(for: "a")?.alias)
            XCTAssertEqual(value.displayName(for: "a", discoveredName: " renamed "), " renamed ")
        }
        for invalid in ["line\nbreak", "tab\t", "\r", "\0", "x\u{007f}", "x\u{2028}y", "x\u{2029}y"] {
            assertAtomicFailure(&value, .invalidAlias) { try $0.setAlias(invalid, for: "a") }
        }
    }

    func testColorValidationNormalizationAndReset() throws {
        var value = try model(["a"])
        for (input, expected) in [("#aBcDeF", "#ABCDEF"), ("#000000", "#000000"), ("#ffffff", "#FFFFFF")] {
            try value.setColorHex(input, for: "a")
            XCTAssertEqual(value.preference(for: "a")?.customColorHex, expected)
            XCTAssertEqual(value.preference(for: "a")?.colorHex, expected)
        }
        for invalid in ["", "ABCDEF", "#fff", "#12345678", "#12345", "#1234567", "#12GG56", " #123456", "#123456\n", "#１２３４５６", "red"] {
            assertAtomicFailure(&value, .invalidColorHex) { try $0.setColorHex(invalid, for: "a") }
        }
        try value.setColorHex(nil, for: "a")
        XCTAssertNil(value.preference(for: "a")?.customColorHex)
        XCTAssertEqual(value.preference(for: "a")?.colorHex, "#38BDF8")
    }

    func testIDsAndDiscoveredNamesAreOpaque() throws {
        let ids = ["0", "ctx_0", "a/b", "A", "a", " a ", "名称", "parent:child", "👩🏽‍💻"]
        var value = try model(ids)
        XCTAssertEqual(Set(value.availableContextIDs), Set(ids))
        XCTAssertNil(value.mainContextID)
        try value.setAlias("same name", for: "A")
        try value.setAlias("same name", for: "a")
        XCTAssertNil(value.preference(for: " a ")?.alias)
        XCTAssertEqual(value.displayName(for: "ctx_0", discoveredName: "<b>0 / Main</b>"), "<b>0 / Main</b>")
        XCTAssertEqual(value.preference(for: "parent:child")?.contextID, "parent:child")
        XCTAssertEqual(value.preference(for: "👩🏽‍💻")?.contextID, "👩🏽‍💻")
    }

    func testInvalidDiscoveryAndUnknownMutationsAreAtomic() throws {
        var value = try model()
        for invalid in ["", String(repeating: "x", count: 129), "x\ny", "x\u{2028}y"] {
            assertAtomicFailure(&value, .invalidContextID) { try $0.reconcile(discoveredContextIDs: ["new", invalid]) }
        }
        assertAtomicFailure(&value, .duplicateContextID) { try $0.reconcile(discoveredContextIDs: ["new", "new"]) }
        assertAtomicFailure(&value, .unknownContextID) { try $0.setMainContextID("unknown") }
        assertAtomicFailure(&value, .unknownContextID) { try $0.setPinned(true, for: "unknown") }
        assertAtomicFailure(&value, .unknownContextID) { try $0.setPinned(false, for: "unknown") }
        assertAtomicFailure(&value, .unknownContextID) { try $0.setAlias("alias", for: "unknown") }
        assertAtomicFailure(&value, .unknownContextID) { try $0.setColorHex("#ABCDEF", for: "unknown") }
        assertAtomicFailure(&value, .invalidContextID) { try $0.setMainContextID("") }
        XCTAssertNoThrow(try value.reconcile(discoveredContextIDs: [String(repeating: "x", count: 128)]))
    }

    func testValueCopiesAreIndependent() throws {
        let original = try model()
        var copy = original
        try copy.setAlias("Copy", for: "a")
        try copy.setMainContextID("b")
        try copy.setPinned(true, for: "c")
        XCTAssertNil(original.preference(for: "a")?.alias)
        XCTAssertNil(original.mainContextID)
        XCTAssertTrue(original.pinnedContextIDs.isEmpty)
    }

    func testJSONAndPropertyListRoundTripsExcludeAvailabilityAndNames() throws {
        var value = try model()
        try value.setMainContextID("g")
        try value.setPinned(true, for: "b")
        try value.setAlias("Work", for: "b")
        try value.setColorHex("#ab12ef", for: "b")
        let json = try JSONEncoder().encode(value.persistence)
        let plist = try PropertyListEncoder().encode(value.persistence)
        let decoded = try JSONDecoder().decode(Model.Persistence.self, from: json)
        XCTAssertEqual(decoded, value.persistence)
        XCTAssertEqual(try PropertyListDecoder().decode(Model.Persistence.self, from: plist), decoded)
        var restored = Model(persistence: decoded)
        XCTAssertTrue(restored.availableContextIDs.isEmpty)
        XCTAssertTrue(restored.orderedAvailableContextIDs.isEmpty)
        try restored.reconcile(discoveredContextIDs: value.availableContextIDs)
        XCTAssertEqual(restored, value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "mainContextID", "pinnedContextIDs", "preferences"]))
    }

    func testPersistenceSortingAndSortedKeyEncodingAreDeterministic() throws {
        let a = try Model.Preference(contextID: "a", paletteIndex: 3)
        let b = try Model.Preference(contextID: "b", paletteIndex: 1)
        let first = try Model.Persistence(preferences: [b, a], pinnedContextIDs: ["b", "a"])
        let second = try Model.Persistence(preferences: [a, b], pinnedContextIDs: ["b", "a"])
        XCTAssertEqual(first.preferences.map(\.contextID), ["a", "b"])
        XCTAssertEqual(first.pinnedContextIDs, ["b", "a"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        var payload = fixture()
        payload["preferences"] = [["contextID": "b", "paletteIndex": 1], ["contextID": "a", "paletteIndex": 0]]
        let decoded = try JSONDecoder().decode(Model.Persistence.self, from: data(payload))
        XCTAssertEqual(decoded.preferences.map(\.contextID), ["a", "b"])
    }

    func testDirectDTOConstructionCannotBypassValidation() throws {
        for index in [-1, 6, Int.max] {
            XCTAssertThrowsError(try Model.Preference(contextID: "a", paletteIndex: index)) {
                XCTAssertEqual($0 as? Failure, .invalidPaletteIndex)
            }
        }
        XCTAssertThrowsError(try Model.Preference(contextID: "", paletteIndex: 0))
        XCTAssertThrowsError(try Model.Preference(contextID: "a", paletteIndex: 0, alias: "x\ny"))
        XCTAssertThrowsError(try Model.Preference(contextID: "a", paletteIndex: 0, customColorHex: "bad"))
        let records = try model().persistence.preferences
        let invalidSelections: [(String?, [String], Failure)] = [
            (nil, ["a", "b", "c", "d", "e"], .tooManyPins),
            (nil, ["a", "a"], .duplicatePin),
            ("a", ["a"], .mainAlsoPinned),
            ("unknown", [], .unknownContextID),
            (nil, ["unknown"], .unknownContextID)
        ]
        for (main, pins, error) in invalidSelections {
            XCTAssertThrowsError(try Model.Persistence(preferences: records, mainContextID: main, pinnedContextIDs: pins)) {
                XCTAssertEqual($0 as? Failure, error)
            }
        }
        XCTAssertThrowsError(try Model.Persistence(preferences: [records[0], records[0]])) {
            XCTAssertEqual($0 as? Failure, .duplicateContextID)
        }
    }

    func testDecodeRejectsSemanticCorruptionRatherThanRepairingIt() throws {
        for (key, replacement) in [("version", 0 as Any), ("version", 2), ("mainContextID", "missing"),
                                   ("pinnedContextIDs", ["missing"]), ("pinnedContextIDs", ["a"]),
                                   ("pinnedContextIDs", ["b", "b"])] {
            var value = fixture()
            value[key] = replacement
            try assertCorrupt(value)
        }
        var duplicate = fixture()
        duplicate["preferences"] = [["contextID": "a", "paletteIndex": 0], ["contextID": "a", "paletteIndex": 1]]
        try assertCorrupt(duplicate)
        let ids = ["a", "b", "c", "d", "e", "f"]
        try assertCorrupt(["version": 1, "mainContextID": "a", "pinnedContextIDs": Array(ids.dropFirst()),
                           "preferences": ids.map { ["contextID": $0, "paletteIndex": 0] as [String: Any] }])
    }

    func testDecodeValidatesEveryPreferenceFieldAndReportsNestedPath() throws {
        for (key, replacement) in [("contextID", "" as Any), ("contextID", String(repeating: "x", count: 129)),
                                   ("contextID", "x\ny"), ("paletteIndex", -1), ("paletteIndex", 6),
                                   ("alias", String(repeating: "a", count: 81)), ("alias", "x\ty"),
                                   ("customColorHex", "#fff"), ("customColorHex", "#12GG56")] {
            var row: [String: Any] = ["contextID": "a", "paletteIndex": 0]
            row[key] = replacement
            try assertCorrupt(["version": 1, "pinnedContextIDs": [], "preferences": [row]])
            XCTAssertThrowsError(try JSONDecoder().decode(Model.Preference.self, from: data(row)))
        }
        let invalid: [String: Any] = ["version": 1, "pinnedContextIDs": [],
            "preferences": [["contextID": "a", "paletteIndex": 6]]]
        XCTAssertThrowsError(try JSONDecoder().decode(Model.Persistence.self, from: data(invalid))) {
            guard case DecodingError.dataCorrupted(let context) = $0 else { return XCTFail("Wrong error: \($0)") }
            XCTAssertEqual(context.codingPath.first?.stringValue, "preferences")
            XCTAssertEqual(context.codingPath.last?.intValue, 0)
        }
    }

    func testDecodeRejectsMissingRequiredFieldsNullsWrongTypesAndMalformedJSON() throws {
        for key in ["version", "pinnedContextIDs", "preferences"] {
            for replacement in [nil, NSNull(), "wrong type"] as [Any?] {
                var value = fixture()
                value[key] = replacement
                XCTAssertThrowsError(try JSONDecoder().decode(Model.Persistence.self, from: data(value)))
            }
        }
        for key in ["contextID", "paletteIndex"] {
            var row: [String: Any] = ["contextID": "a", "paletteIndex": 0]
            row.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(Model.Preference.self, from: data(row)))
        }
        for key in ["alias", "customColorHex"] {
            let row: [String: Any] = ["contextID": "a", "paletteIndex": 0, key: 12]
            XCTAssertThrowsError(try JSONDecoder().decode(Model.Preference.self, from: data(row)))
        }
        for text in ["", "{", "[]", "null", "{}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Model.Persistence.self, from: Data(text.utf8)))
        }
    }

    func testDecodeNormalizesValidOptionalFieldsAndAcceptsUnknownKeys() throws {
        let payload: [String: Any] = ["version": 1, "mainContextID": NSNull(), "pinnedContextIDs": [], "future": true,
            "preferences": [["contextID": "a", "paletteIndex": 0, "alias": "  Label  ", "customColorHex": "#abcdef"],
                            ["contextID": "b", "paletteIndex": 1, "alias": NSNull(), "customColorHex": NSNull()],
                            ["contextID": "c", "paletteIndex": 2, "alias": "   "]]]
        let decoded = try JSONDecoder().decode(Model.Persistence.self, from: data(payload))
        XCTAssertNil(decoded.mainContextID)
        XCTAssertEqual(decoded.preferences[0].alias, "Label")
        XCTAssertEqual(decoded.preferences[0].colorHex, "#ABCDEF")
        XCTAssertNil(decoded.preferences[1].alias)
        XCTAssertEqual(decoded.preferences[1].colorHex, "#FBBF24")
        XCTAssertNil(decoded.preferences[2].alias)
    }
}
