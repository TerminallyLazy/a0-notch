import XCTest
import NotchCore

final class LocalKeyboardCommandsTests: XCTestCase {
    private typealias Keyboard = LocalKeyboardCommands

    private var ready: Keyboard.Context {
        .init(isIslandKey: true, contextCount: 12, canSend: true)
    }

    private var mappings: [(Keyboard.Event, Keyboard.Command)] {
        var rows: [(Keyboard.Event, Keyboard.Command)] = [
            (.init(key: .leftArrow, modifiers: .command), .previousContext),
            (.init(key: .rightArrow, modifiers: .command), .nextContext),
            (.init(key: .upArrow, modifiers: .command), .scrollUp),
            (.init(key: .downArrow, modifiers: .command), .scrollDown),
            (.init(key: .character("o"), modifiers: .command), .openSelected),
            (.init(key: .character("e"), modifiers: .command), .editPrompt),
            (.init(key: .returnKey, modifiers: .command), .send),
            (.init(key: .character("k"), modifiers: .command), .newMessage),
            (.init(key: .character(","), modifiers: .command), .settings),
            (.init(key: .character("p"), modifiers: .command), .copyLastMessage),
            (.init(key: .character("d"), modifiers: [.command, .shift]), .toggleDiff),
            (.init(key: .escape), .dismiss)
        ]
        for slot in 1...9 {
            rows.append((.init(key: .character(String(slot)), modifiers: .command), .selectContext(slot)))
        }
        return rows
    }

    func testEverySpecifiedLocalChordMapsToItsCommand() {
        for (event, command) in mappings {
            XCTAssertEqual(Keyboard.resolve(event, in: ready), .perform(command), "\(event)")
        }
    }

    func testNonKeyIslandNeverInterceptsAnyMappedKey() {
        var context = ready
        context.isIslandKey = false
        for (event, _) in mappings {
            XCTAssertEqual(Keyboard.resolve(event, in: context), .passThrough)
        }
    }

    func testTextEditorsKeepNavigationEscapeAndEditingShortcuts() {
        for focus in [Keyboard.Focus.textInput, .composer] {
            var context = ready
            context.focus = focus
            for (event, command) in mappings {
                let allowed = command == .settings || (focus == .composer && command == .send)
                XCTAssertEqual(Keyboard.resolve(event, in: context), allowed ? .perform(command) : .passThrough,
                               "\(focus): \(event)")
            }
            // Standard edit keys not in the island map must remain native too.
            for key in ["a", "c", "v", "x", "z", "f"] {
                XCTAssertEqual(Keyboard.resolve(.init(key: .character(key), modifiers: .command), in: context), .passThrough)
            }
        }
    }

    func testMarkedTextAlwaysRetainsAllMappedKeysIncludingSendAndEscape() {
        for focus in [Keyboard.Focus.island, .textInput, .composer] {
            var context = ready
            context.focus = focus
            context.hasMarkedText = true
            for (event, _) in mappings {
                XCTAssertEqual(Keyboard.resolve(event, in: context), .passThrough)
            }
        }
    }

    func testBareKeysAndNativeReturnAreNotCommands() {
        let keys: [Keyboard.Key] = [.leftArrow, .rightArrow, .upArrow, .downArrow, .returnKey,
                                    .character("1"), .character("o"), .character("e"), .character("k"),
                                    .character(","), .character("p"), .character("d")]
        for key in keys {
            XCTAssertEqual(Keyboard.resolve(.init(key: key), in: ready), .passThrough)
        }
        XCTAssertEqual(Keyboard.resolve(.init(key: .escape, modifiers: .command), in: ready), .passThrough)
    }

    func testExtraSemanticAndUnknownModifiersAreRejected() {
        for (event, _) in mappings {
            for extra in [Keyboard.Modifiers.option, .control, .init(rawValue: 1 << 20)] {
                let modified = Keyboard.Event(key: event.key, modifiers: event.modifiers.union(extra))
                XCTAssertEqual(Keyboard.resolve(modified, in: ready), .passThrough)
            }
            if !event.modifiers.contains(.shift) {
                let shifted = Keyboard.Event(key: event.key, modifiers: event.modifiers.union(.shift))
                XCTAssertEqual(Keyboard.resolve(shifted, in: ready), .passThrough)
            }
        }
        XCTAssertEqual(Keyboard.resolve(.init(key: .character("d"), modifiers: .command), in: ready), .passThrough)
    }

    func testIncidentalFlagsAndLetterCaseDoNotChangeMapping() {
        for (event, command) in mappings {
            let modified = Keyboard.Event(key: event.key, modifiers: event.modifiers.union([.capsLock, .function, .numericPad]))
            XCTAssertEqual(Keyboard.resolve(modified, in: ready), .perform(command))
        }
        for (letter, command) in [("O", Keyboard.Command.openSelected), ("E", .editPrompt),
                                  ("K", .newMessage), ("P", .copyLastMessage)] {
            XCTAssertEqual(Keyboard.resolve(.init(key: .character(letter), modifiers: .command), in: ready), .perform(command))
        }
        XCTAssertEqual(Keyboard.resolve(.init(key: .character("D"), modifiers: [.command, .shift]), in: ready), .perform(.toggleDiff))
    }

    func testUnsupportedCharactersAreNotCoercedIntoCommands() {
        for text in ["", "0", "10", "١", "１", " o", "o ", "oo", "\r", "\n", "\u{1b}", "🙂", "n"] {
            XCTAssertEqual(Keyboard.resolve(.init(key: .character(text), modifiers: .command), in: ready), .passThrough, text)
        }
    }

    func testContextSlotsAreOneBasedAndBoundedWithoutClamping() {
        for count in [-1, 0, 1, 4, 9, 12] {
            var context = ready
            context.contextCount = count
            for slot in 1...9 {
                let event = Keyboard.Event(key: .character(String(slot)), modifiers: .command)
                XCTAssertEqual(Keyboard.resolve(event, in: context), slot <= count ? .perform(.selectContext(slot)) : .consume)
            }
            XCTAssertEqual(Keyboard.resolve(.init(key: .leftArrow, modifiers: .command), in: context),
                           count >= 2 ? .perform(.previousContext) : .consume)
            XCTAssertEqual(Keyboard.resolve(.init(key: .rightArrow, modifiers: .command), in: context),
                           count >= 2 ? .perform(.nextContext) : .consume)
        }
    }

    func testDisabledCommandsAreConsumedWithoutExecutingOrFallingThrough() {
        for (event, command) in mappings {
            var context = ready
            context.disabledCommands = [command]
            XCTAssertEqual(Keyboard.resolve(event, in: context), .consume)
        }
        var context = ready
        context.disabledCommands = [.selectContext(1)]
        XCTAssertEqual(Keyboard.resolve(.init(key: .character("2"), modifiers: .command), in: context), .perform(.selectContext(2)))
        context.focus = .textInput
        context.disabledCommands = [.editPrompt]
        XCTAssertEqual(Keyboard.resolve(.init(key: .character("e"), modifiers: .command), in: context), .passThrough)
    }

    func testAutoRepeatOnlyAllowsNavigationAndScrolling() {
        let repeatable: Set<Keyboard.Command> = [.previousContext, .nextContext, .scrollUp, .scrollDown]
        for (event, command) in mappings {
            let repeated = Keyboard.Event(key: event.key, modifiers: event.modifiers, isRepeat: true)
            XCTAssertEqual(Keyboard.resolve(repeated, in: ready), repeatable.contains(command) ? .perform(command) : .consume)
        }
    }

    func testSendRequiresExplicitReadinessAndRejectsRepeatedMutation() {
        let send = Keyboard.Event(key: .returnKey, modifiers: .command)
        XCTAssertEqual(Keyboard.resolve(send, in: .init(isIslandKey: true)), .consume)
        var context = ready
        context.focus = .composer
        XCTAssertEqual(Keyboard.resolve(send, in: context), .perform(.send))
        XCTAssertEqual(Keyboard.resolve(.init(key: .returnKey, modifiers: .command, isRepeat: true), in: context), .consume)
        // The owner marks the operation in flight before executing it; a second
        // physical press must not send while readiness is false either.
        context.canSend = false
        XCTAssertEqual(Keyboard.resolve(send, in: context), .consume)
        context.canSend = true
        XCTAssertEqual(Keyboard.resolve(send, in: context), .perform(.send))
    }

    func testResolutionIsDeterministicAndDoesNotMutateInputContext() {
        let context = ready
        let snapshot = context
        for _ in 0..<10 {
            for (event, command) in mappings {
                XCTAssertEqual(Keyboard.resolve(event, in: context), .perform(command))
            }
        }
        XCTAssertEqual(context, snapshot)
    }
}
