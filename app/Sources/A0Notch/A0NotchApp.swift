import AppKit
import SwiftUI
import NotchCore

@main
@MainActor
enum A0NotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: IslandStore
    private let smokeDefaults: String?
    override init() {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            let name = "community.agentzero.notch.launch." + UUID().uuidString
            smokeDefaults = name
            store = IslandStore(defaults: UserDefaults(suiteName: name)!)
        } else { smokeDefaults = nil; store = IslandStore() }
        super.init()
    }
    private var island: IslandWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var chatWindow: NSWindow?
    private var commands: AppCommands?
    private var smokeTask: Task<Void, Never>?
    private var dictationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak store] _ in
            MainActor.assumeIsolated { store?.cancelDictation() }
        })
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { store?.cancelDictation() }
            })
        }
        _ = A0Brand.fontsRegistered
        NSApp.applicationIconImage = A0Brand.appIcon
        store.showChats = { [weak self] in self?.openChats() }
        store.showConnection = { [weak self] in self?.connectionSettings() }
        island = IslandWindowController(store: store)
        if let island {
            commands = AppCommands(store: store, island: island)
            store.focusComposer = { [weak island] in island?.enableTextInput() }
            store.desktop = DesktopZeroController(wardrobe: store.wardrobe, callbacks: .init(
                islandFrame: { [weak island] in island?.visibleFrame },
                visibilityChanged: { [weak store] visible in store?.desktopVisible = visible },
                wardrobeRequested: { [weak store] in store?.open(); store?.wardrobePresented = true },
                soundToggleRequested: { [weak store] in store?.toggleSound() },
                sound: { [weak store] cue in
                    if let sound = NotchSound(rawValue: String(describing: cue)) { store?.sounds?.play(sound) }
                }))
        }
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            store.sounds = try? NotchSoundPlayer()
            store.soundMuted = store.sounds?.isMuted ?? true
            store.soundVolume = store.sounds?.volume ?? 0.12
            store.interaction.onCue = { [weak store] cue in
                if let sound = NotchSound(rawValue: cue) { store?.sounds?.play(sound) }
            }
            store.hotkeys = GlobalHotkeys()
            store.hotkeys?.onAction = { [weak self] action in self?.commands?.global(action) }
            store.hotkeys?.onChange = { [weak store] in store?.shortcutRevision += 1 }
            store.hotkeys?.start()
            store.desktop?.start()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = A0Brand.menuIcon
        if A0Brand.menuIcon == nil { item.button?.title = "A0" }
        item.button?.toolTip = "a0_notch — chats, connection and appearance"
        item.button?.setAccessibilityLabel("Agent Zero notch menu")
        item.button?.setAccessibilityHelp("Choose Notch, Floating Capsule or Slim Bar; open your chats.")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--open") || arguments.contains("--smoke-test") { store.open() }
        if arguments.contains("--smoke-test") { runSmokeTest() }
    }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(menu) }
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        add("a0_notch · Agent Zero", to: menu, action: nil)
        menu.addItem(.separator())
        add("Open the notch", to: menu, action: #selector(openIsland))
        add("Chats…", to: menu, action: #selector(openChats), key: "n")
        let appearance = NSMenu()
        for choice in IslandPresentation.allCases {
            let item = add(choice.title, to: appearance, action: #selector(selectPresentation(_:)))
            item.representedObject = choice.rawValue
            item.state = store.presentation == choice ? .on : .off
        }
        add("Appearance", to: menu, action: nil).submenu = appearance
        let display = NSMenu()
        let choices: [(String, IslandDisplayChoice)] = [("Notch (automatic)", .notch), ("Menu bar", .menuBar), ("Follow mouse", .followMouse)]
            + NSScreen.screens.map { ($0.localizedName, .display(IslandWindowController.descriptor($0).id)) }
        for (name, choice) in choices {
            let item = add(name, to: display, action: #selector(selectDisplay(_:)))
            item.representedObject = choice.rawValue
            item.state = store.displayChoice == choice ? .on : .off
        }
        if case .display(let savedID) = store.displayChoice,
           !NSScreen.screens.contains(where: { IslandWindowController.descriptor($0).id == savedID }) {
            add("Saved screen (not connected)", to: display, action: nil).state = .on
        }
        let displayItem = add("Display", to: menu, action: nil)
        displayItem.submenu = display
        menu.addItem(.separator())
        add(store.connectionLabel, to: menu, action: nil)
        add(store.soundMuted ? "Unmute sounds" : "Mute sounds", to: menu, action: #selector(toggleSound))
        add("Desktop Zero", to: menu, action: #selector(toggleDesktop))
        add("Wardrobe…", to: menu, action: #selector(openWardrobe))
        add("Ask Agent Zero", to: menu, action: #selector(openPrompt))
        add("Settings…", to: menu, action: #selector(connectionSettings), key: ",")
        add("Disconnect live", to: menu, action: #selector(disconnectLive))
        add("Open Agent Zero WebUI", to: menu, action: #selector(openWebUI))
        add("Quit a0_notch", to: menu, action: #selector(quit), key: "q")
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc private func openIsland() { store.open() }
    @objc private func openChats() {
        store.cancelDictation()
        if chatWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Agent Zero · Chats"
            window.identifier = NSUserInterfaceItemIdentifier("notch-chats")
            window.contentView = NSHostingView(rootView: ChatWorkspace(store: store))
            window.minSize = NSSize(width: 780, height: 560)
            window.isReleasedWhenClosed = false
            window.center(); chatWindow = window
        }
        chatWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func selectPresentation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = IslandPresentation(rawValue: raw) else { return }
        store.selectPresentation(choice)
    }
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        store.selectDisplay(IslandDisplayChoice(rawValue: raw)); island?.refreshDisplay()
    }
    @objc private func connectionSettings() {
        store.cancelDictation()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "a0_notch · Settings"
            window.contentView = NSHostingView(rootView: ProductSettings(store: store))
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleSound() { store.toggleSound() }
    @objc private func toggleDesktop() { store.toggleDesktop() }
    @objc private func openWardrobe() { store.open(); store.wardrobePresented = true }
    @objc private func openPrompt() { store.navigate(.prompt) }
    @objc private func disconnectLive() { store.disconnectLive() }
    @objc private func openWebUI() { store.openWebUI() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        for observer in dictationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        dictationObservers.removeAll()
        smokeTask?.cancel()
        store.disconnectLive()
        commands?.shutdown(); store.hotkeys?.shutdown(); store.desktop?.shutdown(); store.sounds?.shutdown()
        island?.shutdown()
        if let smokeDefaults { UserDefaults.standard.removePersistentDomain(forName: smokeDefaults) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
    /// Exercise the actual store without touching the user's persistent domain.
    private func verifyPresentationPreferences() -> Bool {
        let suite = "community.agentzero.notch.smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "islandPresentation"
        for choice in IslandPresentation.allCases {
            let store = IslandStore(defaults: defaults, arguments: [])
            store.selectPresentation(choice)
            guard defaults.string(forKey: key) == choice.rawValue,
                  IslandStore(defaults: defaults, arguments: []).presentation == choice else { return false }
            for override in IslandPresentation.allCases {
                let preview = IslandStore(defaults: defaults, arguments: ["--presentation=\(override.rawValue)"])
                guard preview.presentation == override,
                      defaults.string(forKey: key) == choice.rawValue else { return false }
            }
        }
        defaults.set("invalid", forKey: key)
        guard IslandStore(defaults: defaults, arguments: []).presentation == .notch else { return false }
        defaults.removeObject(forKey: key)
        return IslandStore(defaults: defaults, arguments: []).presentation == .notch
    }

    private func runSmokeTest() {
        smokeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let island = self.island else { return }
            var diagnostics = island.diagnostics()
            diagnostics["brandingValid"] = A0Brand.isValid
            diagnostics["presentationPreferencesValid"] = self.verifyPresentationPreferences()
            diagnostics["menuIconIsTemplate"] = A0Brand.menuIcon?.isTemplate == true
            diagnostics["brandingBundle"] = A0Brand.resourceBundle.bundleURL.path
            diagnostics["uiFont"] = NSFont(name: "Rubik-Regular", size: 13)?.familyName ?? "missing"
            diagnostics["codeFont"] = NSFont(name: "RobotoMono-Regular", size: 11)?.familyName ?? "missing"
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) { print(string) }
            let passed = A0Brand.isValid
                && diagnostics["presentationPreferencesValid"] as? Bool == true
                && A0Brand.menuIcon?.isTemplate == true
                && diagnostics["presentationSettled"] as? Bool == true
                && diagnostics["transparentMarginPassesThrough"] as? Bool == true
                && island.panel.frame.size == CGSize(width: 720, height: 320)
                && !island.panel.canBecomeKey && !island.panel.canBecomeMain
                && island.panel.styleMask.contains(.nonactivatingPanel)
                && diagnostics["topAnchored"] as? Bool == true
                && !island.panel.isKeyWindow && NSApp.activationPolicy() == .accessory
            print(passed ? "SMOKE_TEST_PASS" : "SMOKE_TEST_FAIL")
            if !passed { exit(1) }
            NSApp.terminate(nil)
        }
    }
}
