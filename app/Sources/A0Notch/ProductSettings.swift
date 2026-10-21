import AppKit
import SwiftUI
import NotchCore

struct ProductSettings: View {
    @Bindable var store: IslandStore
    @State private var selectedTab = 0
    @State private var settingsWindow: NSWindow?
    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectionSettings(store: store).tabItem { Label("Connection", systemImage: "network") }.tag(0)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Context preferences").font(A0Brand.ui(24, weight: .medium))
                    Text("All chats remain discoverable. Main and pins only change presentation order; aliases and colors are private to this server/account.").foregroundStyle(A0Theme.muted)
                    Picker("Main context", selection: Binding(get: { store.preferences.mainContextID ?? "" }, set: { value in store.updatePreference { try $0.setMainContextID(value.isEmpty ? nil : value) } })) {
                        Text("None").tag("")
                        ForEach(store.orderedContexts) { row in Text(store.name(row)).tag(row.id) }
                    }
                    ForEach(store.preferences.persistence.preferences, id: \.contextID) { preference in
                        ContextPreferenceRow(store: store, preference: preference)
                    }
                }.padding(24)
            }.tabItem { Label("Contexts", systemImage: "bubble.left.and.bubble.right") }.tag(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Sounds") {
                        VStack(alignment: .leading) {
                            Toggle("Muted", isOn: Binding(get: { store.soundMuted }, set: { _ in store.toggleSound() }))
                            Slider(value: Binding(get: { store.soundVolume }, set: { store.setVolume($0) }), in: 0...0.2) { Text("Volume") }
                            Text("Original synthesized sounds · volume \(Int(store.soundVolume * 100))%").font(A0Brand.ui(11))
                            Button("Preview greeting") { store.sounds?.play([.peek, .greet]) }
                        }.padding(8)
                    }
                    GroupBox("Appearance and display") {
                        VStack(alignment: .leading) {
                            Picker("Presentation", selection: Binding(get: { store.presentation }, set: { store.selectPresentation($0) })) {
                                ForEach(IslandPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Picker("Display", selection: Binding(get: { store.displayChoice.rawValue }, set: { store.selectDisplay(IslandDisplayChoice(rawValue: $0)) })) {
                                Text("Notch (automatic)").tag("notch")
                                Text("Menu bar").tag("menuBar")
                                Text("Follow mouse").tag("followMouse")
                                ForEach(NSScreen.screens.map { (id: IslandWindowController.descriptor($0).id, screen: $0) }, id: \.id) { item in
                                    let screen = item.screen
                                    Text(screen.localizedName).tag("display:" + IslandWindowController.descriptor(screen).id)
                                }
                                if case .display(let id) = store.displayChoice,
                                   !NSScreen.screens.contains(where: { IslandWindowController.descriptor($0).id == id }) {
                                    Text("Saved screen (not connected)").tag(store.displayChoice.rawValue)
                                }
                            }
                            Button(store.desktop?.wantsDesktop == true ? "Return Zero to notch" : "Move Zero to desktop") { store.toggleDesktop() }
                        }.padding(8)
                    }
                    WardrobeView(wardrobe: store.wardrobe) { _ in store.interact() }
                }.padding(24)
            }.tabItem { Label("Zero", systemImage: "sparkles") }.tag(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Global shortcuts").font(A0Brand.ui(24, weight: .medium))
                    Text("Carbon shortcuts do not request Accessibility permission. Red means duplicate bindings; orange means macOS rejected a system conflict. Recording is local to this settings window.").foregroundStyle(A0Theme.muted)
                    if let hotkeys = store.hotkeys {
                        let _ = store.shortcutRevision
                        ForEach(NotchHotkeyAction.allCases, id: \.self) { action in
                            HStack {
                                Toggle(action.rawValue, isOn: Binding(get: { hotkeys.binding(for: action).isEnabled }, set: { hotkeys.setEnabled($0, for: action) }))
                                Spacer()
                                Button(hotkeys.recordingAction == action ? "Press shortcut… (Esc cancels)" : hotkeys.binding(for: action).chord.displayName) {
                                    if selectedTab == 3, let settingsWindow { hotkeys.beginRecording(for: action, window: settingsWindow) }
                                }
                                Text(statusLabel(hotkeys.status(for: action))).font(A0Brand.mono(10))
                                    .foregroundStyle(statusColor(hotkeys.status(for: action)))
                            }
                        }
                        HStack {
                            Button("Reset all", action: hotkeys.resetAll)
                            Button("Retry registration", action: hotkeys.retryRegistration)
                            Button("Cancel recording", action: hotkeys.cancelRecording)
                        }
                    }
                    Text("Local: ⌘←/→ context · ⌘1–9 select · ⌘E compose · ⌘↩ send · ⌘P copy · ⌘⇧D diff metadata. Native text navigation and marked-text composition take precedence.").font(A0Brand.ui(12))
                }.padding(24)
            }.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(3)
        }
        .font(A0Brand.ui(13)).frame(minWidth: 600, minHeight: 640)
        .background(A0Theme.background).preferredColorScheme(.dark)
        .background(SettingsWindowReader { settingsWindow = $0 })
        .onChange(of: selectedTab) { _, _ in store.hotkeys?.cancelRecording() }
        .onDisappear { store.hotkeys?.cancelRecording() }
    }
    private func statusLabel(_ status: NotchHotkeyStatus) -> String {
        switch status {
        case .disabled: "Off"
        case .stopped: "Stopped"
        case .recording: "Recording"
        case .registered: "Registered"
        case .invalidShortcut: "Invalid"
        case .internalConflict: "Duplicate"
        case .systemConflict: "System conflict"
        case .registrationFailed: "Registration failed"
        }
    }
    private func statusColor(_ status: NotchHotkeyStatus) -> Color {
        switch status {
        case .internalConflict, .invalidShortcut: A0Theme.error
        case .systemConflict, .registrationFailed: A0Theme.warning
        default: A0Theme.muted
        }
    }
}

private struct ContextPreferenceRow: View {
    let store: IslandStore
    let preference: ContextPreferences.Preference
    @State private var alias = ""
    @State private var color = ""
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.contexts.first { $0.id == preference.contextID }?.name ?? "Saved chat (not currently available)")
                Text(preference.contextID).font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted)
                HStack {
                    Toggle("Pin", isOn: Binding(get: { store.preferences.pinnedContextIDs.contains(preference.contextID) }, set: { enabled in store.updatePreference { try $0.setPinned(enabled, for: preference.contextID) } }))
                        .disabled(store.preferences.mainContextID == preference.contextID)
                    TextField("Alias", text: $alias)
                    TextField("#RRGGBB", text: $color).frame(width: 95)
                    Button("Save") {
                        store.updatePreference { preferences in
                            var updated = preferences
                            try updated.setAlias(alias, for: preference.contextID)
                            try updated.setColorHex(color.isEmpty ? nil : color, for: preference.contextID)
                            preferences = updated
                        }
                    }
                }
            }.padding(8)
        }
        .onAppear { alias = preference.alias ?? ""; color = preference.customColorHex ?? "" }
    }
}


private struct SettingsWindowReader: NSViewRepresentable {
    let changed: (NSWindow?) -> Void
    final class View: NSView {
        var changed: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed?(window) }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.changed = changed; return view }
    func updateNSView(_ view: View, context: Context) { view.changed = changed }
}
