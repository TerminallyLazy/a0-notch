import AppKit
import NotchCore

@MainActor
final class AppCommands {
    let store: IslandStore
    weak var island: IslandWindowController?
    private var monitor: Any?
    init(store: IslandStore, island: IslandWindowController) {
        self.store = store; self.island = island
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }
    func global(_ action: NotchHotkeyAction) {
        switch action {
        case .toggleIsland: store.mode == .expanded ? store.close() : store.open()
        case .openPrompt: store.navigate(.prompt)
        case .goToAlert: store.open()
        case .openWebUI: store.openWebUI()
        case .attachWindow: store.attachFrontApplication()
        case .nextContext: store.cycleContext(1)
        case .previousContext: store.cycleContext(-1)
        case .mute: store.toggleSound()
        case .desktopZero: store.toggleDesktop()
        case .wardrobe: store.open(); store.wardrobePresented = true
        }
    }
    private func handle(_ event: NSEvent) -> Bool {
        guard store.hotkeys?.recordingAction == nil, let window = event.window,
              window === NSApp.keyWindow,
              window === island?.panel || window.identifier?.rawValue == "notch-chats" else { return false }
        let editor = window.firstResponder as? NSTextView
        let field = (editor?.delegate as? NSView) ?? editor
        let composer = field?.identifier?.rawValue == "notch-composer" || (window === island?.panel ? store.islandComposerEditing : store.chatComposerEditing)
        var modifiers: LocalKeyboardCommands.Modifiers = []
        for (flag, value): (NSEvent.ModifierFlags, LocalKeyboardCommands.Modifiers) in [
            (.command, .command), (.shift, .shift), (.control, .control), (.option, .option),
            (.capsLock, .capsLock), (.function, .function), (.numericPad, .numericPad)] {
            if event.modifierFlags.contains(flag) { modifiers.insert(value) }
        }
        let key: LocalKeyboardCommands.Key
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 36, 76: key = .returnKey
        case 53: key = .escape
        default: key = .character(event.charactersIgnoringModifiers ?? "")
        }
        let context = LocalKeyboardCommands.Context(isIslandKey: true,
            focus: editor == nil ? .island : (composer ? .composer : .textInput),
            hasMarkedText: editor?.hasMarkedText() ?? false, contextCount: store.orderedContexts.count,
            canSend: store.canMutate && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        switch LocalKeyboardCommands.resolve(.init(key: key, modifiers: modifiers, isRepeat: event.isARepeat), in: context) {
        case .passThrough: return false
        case .consume: return true
        case .perform(let command):
            switch command {
            case .nextContext: store.cycleContext(1)
            case .previousContext: store.cycleContext(-1)
            case .selectContext(let index): store.focus(store.orderedContexts[index - 1].id)
            case .openSelected: store.showChats()
            case .editPrompt, .newMessage: store.navigate(.prompt)
            case .send: store.perform(.send, target: store.target)
            case .settings: store.showConnection()
            case .copyLastMessage:
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.lastResponse, forType: .string)
            case .toggleDiff: store.showDiff.toggle()
            case .dismiss: store.close()
            case .scrollUp: window.firstResponder?.tryToPerform(#selector(NSResponder.scrollPageUp(_:)), with: nil)
            case .scrollDown: window.firstResponder?.tryToPerform(#selector(NSResponder.scrollPageDown(_:)), with: nil)
            }
            store.interact(); return true
        }
    }
    func shutdown() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
