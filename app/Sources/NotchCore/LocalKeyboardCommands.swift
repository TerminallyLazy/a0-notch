import Foundation

/// Pure local-key policy; does not install monitors, register hotkeys or execute actions.
/// The AppKit adapter must pass key-down events only, identify the owning key window,
/// and translate special keys explicitly. Never feed global keyboard events here.
public enum LocalKeyboardCommands {
    public enum Command: Hashable, Sendable {
        case previousContext, nextContext
        /// One-based position in the caller's currently displayed context order.
        case selectContext(Int)
        case scrollUp, scrollDown
        case openSelected, editPrompt, send, newMessage, settings, copyLastMessage, toggleDiff
        /// A dismissal request, not permission to discard an unresolved alert.
        case dismiss

        fileprivate var allowsRepeat: Bool {
            switch self {
            case .previousContext, .nextContext, .scrollUp, .scrollDown: return true
            default: return false
            }
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1 << 0)
        public static let shift = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let control = Self(rawValue: 1 << 3)
        public static let capsLock = Self(rawValue: 1 << 4)
        public static let function = Self(rawValue: 1 << 5)
        public static let numericPad = Self(rawValue: 1 << 6)
    }

    public enum Key: Equatable, Sendable {
        /// Supply charactersIgnoringModifiers; letters are matched case-insensitively.
        /// Do not trim whitespace or translate layout-specific physical key codes.
        case character(String)
        case leftArrow, rightArrow, upArrow, downArrow, returnKey, escape
    }

    public struct Event: Equatable, Sendable {
        public let key: Key
        public let modifiers: Modifiers
        public let isRepeat: Bool

        public init(key: Key, modifiers: Modifiers = [], isRepeat: Bool = false) {
            self.key = key
            self.modifiers = modifiers
            self.isRepeat = isRepeat
        }
    }

    public enum Focus: Equatable, Sendable {
        case island
        /// Search, secure fields, settings fields and other native text editors.
        case textInput
        /// Only the actual message composer may claim Command-Return while editing.
        case composer
    }

    public struct Context: Equatable, Sendable {
        public var isIslandKey: Bool
        public var focus: Focus
        public var hasMarkedText: Bool
        public var contextCount: Int
        /// Explicit readiness supplied by the owner (fresh session, valid target,
        /// nonempty draft, no in-flight send). False by default; never inferred.
        public var canSend: Bool
        public var disabledCommands: Set<Command>

        public init(
            isIslandKey: Bool,
            focus: Focus = .island,
            hasMarkedText: Bool = false,
            contextCount: Int = 0,
            canSend: Bool = false,
            disabledCommands: Set<Command> = []
        ) {
            self.isIslandKey = isIslandKey
            self.focus = focus
            self.hasMarkedText = hasMarkedText
            self.contextCount = contextCount
            self.canSend = canSend
            self.disabledCommands = disabledCommands
        }
    }

    public enum Resolution: Equatable, Sendable {
        /// Leave the event with the native responder chain, including text editing.
        case passThrough
        case perform(Command)
        /// Handled but intentionally does nothing. Do not forward to another send
        /// handler: repeat/disabled/unavailable commands must not execute indirectly.
        case consume
    }

    /// Recognizes the spec's local commands using exact shortcut modifiers.
    /// Command-arrows and all editing-sensitive commands pass through in text fields.
    /// Escape also passes through there for completion/IME/editor cancellation; after
    /// editing ends, an unmodified Escape requests island dismissal. Marked text owns
    /// every key, even Command-Return, until composition is committed.
    ///
    /// This rejects auto-repeat, not separate physical presses or duplicate delivery
    /// of a nonrepeat event. The caller must have one dispatcher and atomically mark
    /// sends in flight, snapshot their target, and revalidate before performing them.
    public static func resolve(_ event: Event, in context: Context) -> Resolution {
        guard context.isIslandKey, !context.hasMarkedText,
              let command = command(for: event) else { return .passThrough }

        if context.focus != .island {
            let allowed = command == .settings || (command == .send && context.focus == .composer)
            guard allowed else { return .passThrough }
        }
        guard !context.disabledCommands.contains(command) else { return .consume }
        guard !event.isRepeat || command.allowsRepeat else { return .consume }
        if command == .send, !context.canSend { return .consume }
        if case .selectContext(let slot) = command, slot > context.contextCount { return .consume }
        if (command == .nextContext || command == .previousContext), context.contextCount < 2 {
            return .consume
        }
        return .perform(command)
    }

    private static func command(for event: Event) -> Command? {
        // AppKit may attach these incidental flags to arrows/Return. Unknown bits,
        // Option, Control and extra Shift are NOT discarded.
        let modifiers = event.modifiers.subtracting([.capsLock, .function, .numericPad])
        if event.key == .escape, modifiers.isEmpty { return .dismiss }
        if modifiers == [.command, .shift], case .character(let text) = event.key,
           text.lowercased() == "d" { return .toggleDiff }
        guard modifiers == .command else { return nil }
        switch event.key {
        case .leftArrow: return .previousContext
        case .rightArrow: return .nextContext
        case .upArrow: return .scrollUp
        case .downArrow: return .scrollDown
        case .returnKey: return .send
        case .escape: return nil
        case .character(let text):
            switch text.lowercased() {
            case "1": return .selectContext(1)
            case "2": return .selectContext(2)
            case "3": return .selectContext(3)
            case "4": return .selectContext(4)
            case "5": return .selectContext(5)
            case "6": return .selectContext(6)
            case "7": return .selectContext(7)
            case "8": return .selectContext(8)
            case "9": return .selectContext(9)
            case "o": return .openSelected
            case "e": return .editPrompt
            case "k": return .newMessage
            case ",": return .settings
            case "p": return .copyLastMessage
            default: return nil
            }
        }
    }
}
