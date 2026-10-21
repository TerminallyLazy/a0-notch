import AppKit
import SwiftUI
import Security
import ServiceManagement
import NotchCore

/// Credential scope includes the normalized origin and username. Never UserDefaults.
enum NotchKeychain {
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "Keychain is locked or unavailable. Unlock it and try again; the credential operation did not complete." }
    }
    static func check(_ status: OSStatus) throws -> Bool {
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Failure.unavailable }
        return true
    }
    static func checkWrite(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure.unavailable }
    }
    private static func query(origin: String, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "community.agentzero.notch.connection:" + origin,
         kSecAttrAccount as String: username]
    }
    static func read(origin: String, username: String) throws -> String? {
        var query = query(origin: origin, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard try check(SecItemCopyMatching(query as CFDictionary, &result)) else { return nil }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
        return value
    }
    static func save(_ password: String, origin: String, username: String) throws {
        let query = query(origin: origin, username: username)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try checkWrite(SecItemAdd(item as CFDictionary, nil))
        } else { try checkWrite(result) }
    }
    static func remove(origin: String, username: String) throws {
        _ = try check(SecItemDelete(query(origin: origin, username: username) as CFDictionary))
    }
}

struct ConnectionSettings: View {
    @Bindable var store: IslandStore
    @State private var password = ""
    @State private var savePassword = false
    @State private var keychainMessage = ""
    @State private var confirmForget = false
    @State private var forgetAccount: (origin: String, username: String)?
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginMessage = ""
    private var validAccount: Bool {
        (try? LiveOrigin(store.connectionURL)) != nil && !store.connectionUsername.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    AgentZeroWordmark().frame(width: 154, height: 30)
                    Spacer()
                    Text("CONNECTION").font(A0Brand.mono(11)).foregroundStyle(A0Theme.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your agent. Right here.").font(A0Brand.ui(25, weight: .medium))
                    Text("Connect your WebUI account to follow every chat, send messages, and manage running work.")
                        .foregroundStyle(A0Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SERVER").font(A0Brand.mono(11)).foregroundStyle(A0Theme.muted)
                        Text("WebUI URL").font(A0Brand.ui(13, weight: .medium))
                        TextField("https://your-agent-zero.example", text: $store.connectionURL)
                            .accessibilityLabel("WebUI server URL")
                        Text("Use the actual published URL and port. HTTPS is required except on localhost.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(store.connecting)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ACCOUNT").font(A0Brand.mono(11)).foregroundStyle(A0Theme.muted)
                        Text("WebUI username").font(A0Brand.ui(13, weight: .medium))
                        TextField("Username", text: $store.connectionUsername).accessibilityLabel("WebUI username")
                        Text("Password").font(A0Brand.ui(13, weight: .medium))
                        SecureField("Password, or leave blank to use your saved password", text: $password)
                            .accessibilityLabel("WebUI password")
                        Toggle("Save password in Keychain", isOn: $savePassword)
                        Text("Saving is optional and scoped to this server and username. Existing saved passwords are preserved. Browser cookies are never used.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(store.connecting)
                HStack(spacing: 12) {
                    Button(store.connecting ? "Connecting…" : "Connect") { run(test: false) }
                        .buttonStyle(IslandButtonStyle(primary: true)).disabled(!validAccount || store.connecting)
                    Button("Test connection") { run(test: true) }.disabled(!validAccount || store.connecting)
                    Spacer()
                    Button(store.connecting ? "Cancel" : "Disconnect") { store.disconnectLive() }
                        .disabled(store.live.mode == .disconnected)
                }
                HStack(alignment: .top, spacing: 10) {
                    if store.connecting { ProgressView().controlSize(.small) }
                    else { Image(systemName: store.connectionError ? "exclamationmark.triangle" : "network") }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.connectionLabel).font(A0Brand.mono(11))
                        Text(store.connectionMessage).font(A0Brand.ui(12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(store.connectionError ? A0Theme.accent : A0Theme.muted)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(A0Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Open WebUI", action: store.openWebUI).disabled((try? LiveOrigin(store.connectionURL)) == nil)
                    Spacer()
                    Button("Forget saved password…") {
                        if let origin = try? LiveOrigin(store.connectionURL) {
                            forgetAccount = (origin.url.absoluteString, store.connectionUsername)
                            confirmForget = true
                        }
                    }.disabled(!validAccount || store.connecting)
                }.font(A0Brand.ui(11))
                if !keychainMessage.isEmpty { Text(keychainMessage).foregroundStyle(A0Theme.accent) }
                GroupBox("Model configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.modelInformation).font(A0Brand.ui(13, weight: .medium))
                        Text(store.modelSettingsGuidance).font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                        Button("Open A0 model settings (in WebUI)", action: store.openModelSettings)
                            .disabled((try? LiveOrigin(store.connectedOrigin.isEmpty ? store.connectionURL : store.connectedOrigin)) == nil)
                        Text("Opens the WebUI. Choose this chat's model preset, or Settings → Models. No global settings are changed by a0_notch.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                    }.padding(8)
                }
                GroupBox("Microphone dictation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Require on-device recognition", isOn: $store.dictationOnDeviceOnly)
                        Picker("Speech language", selection: $store.dictationLocale) {
                            ForEach(Array(Set(AppleDictationDriver.locales + [store.dictationLocale])).sorted(), id: \.self) { identifier in
                                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                            }
                        }
                        Text(store.dictation.supportsOnDevice(locale: store.dictationLocale)
                             ? "On-device recognition is supported for this language."
                             : "On-device recognition is not currently supported for this language.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                        Text("Private by default. Turning this off allows Apple server recognition only when on-device recognition is unavailable. Every recording requires your explicit Start microphone consent. Recordings stop at 45 seconds; review and insert the transcript, then send separately. No audio or transcripts are saved by a0_notch.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                        Text("Language and recognition preference are saved separately for each connected server/account. Connect before changing them.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                        if store.dictation.active { Button("Cancel recording", action: store.cancelDictation) }
                        HStack {
                            Button("Microphone privacy…") { openPrivacy("Privacy_Microphone") }
                            Button("Speech privacy…") { openPrivacy("Privacy_SpeechRecognition") }
                        }
                    }.padding(8).disabled(store.connectedOrigin.isEmpty)
                }
                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Close after \(Int(store.autoCloseSeconds)) seconds", value: $store.autoCloseSeconds, in: 15...300, step: 15)
                        Stepper("Hide after \(Int(store.absenceMinutes)) minutes without mouse movement", value: $store.absenceMinutes, in: 1...30)
                        Toggle("Open for chat alerts and completion", isOn: $store.autoOpenEvents)
                        Text("Alerts are FIFO and stay open until resolved or dismissed. Completion gets 5.2 seconds, excluding alert time. Other chats never change your selection or load content automatically.")
                            .font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                    }.padding(8)
                }
                GroupBox("Launch at login") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(loginStatus == .enabled ? "Enabled" : loginStatus == .requiresApproval ? "Approval required in System Settings" : "Disabled")
                        HStack {
                            Button(loginStatus == .enabled || loginStatus == .requiresApproval ? "Disable launch at login" : "Enable launch at login") {
                                do {
                                    if loginStatus == .enabled || loginStatus == .requiresApproval { try SMAppService.mainApp.unregister() }
                                    else { try SMAppService.mainApp.register() }
                                    loginStatus = SMAppService.mainApp.status
                                    loginMessage = ""
                                } catch { loginMessage = "macOS could not update the login item. Install the app in Applications and check System Settings." }
                            }
                            Button("System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        if !loginMessage.isEmpty { Text(loginMessage).font(A0Brand.ui(11)).foregroundStyle(A0Theme.accent) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(26)
        }
        .textFieldStyle(.roundedBorder).font(A0Brand.ui(13))
        .frame(minWidth: 550, minHeight: 620).background(A0Theme.background)
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .confirmationDialog("Remove the saved password for this server and username?", isPresented: $confirmForget) {
            Button("Forget password", role: .destructive) {
                if let account = forgetAccount {
                    do {
                        try NotchKeychain.remove(origin: account.origin, username: account.username)
                        keychainMessage = "Saved password removed (or already absent)."
                    } catch { keychainMessage = error.localizedDescription }
                }
            }
        }
        .onChange(of: store.connectionURL) { _, _ in password = ""; savePassword = false }
        .onChange(of: store.connectionUsername) { _, _ in password = ""; savePassword = false }
        .onChange(of: store.live.mode) { _, mode in if mode == .live { password = "" } }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    private func run(test: Bool) {
        // connectLive captures credentials synchronously; do not retain the field
        // through failed logins, test-only completion, or cancellation.
        store.connectLive(password: password, savePassword: savePassword, testOnly: test)
        password = ""
        savePassword = false
    }
}
