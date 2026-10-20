import AppKit
import SwiftUI
import Security
import ServiceManagement
import NotchCore

/// Credential scope includes the normalized origin and username. Never UserDefaults.
enum NotchKeychain {
    private static func query(origin: String, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "community.agentzero.notch.connection:" + origin,
         kSecAttrAccount as String: username]
    }
    static func read(origin: String, username: String) -> String? {
        var query = query(origin: origin, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, origin: String, username: String) throws {
        let query = query(origin: origin, username: username)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LiveError.authentication }
        } else if result != errSecSuccess { throw LiveError.authentication }
    }
    static func remove(origin: String, username: String) {
        SecItemDelete(query(origin: origin, username: username) as CFDictionary)
    }
}

struct ConnectionSettings: View {
    @Bindable var store: IslandStore
    @State private var password = ""
    @State private var savePassword = false
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
                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Close after \(Int(store.autoCloseSeconds)) seconds", value: $store.autoCloseSeconds, in: 15...300, step: 15)
                        Stepper("Hide after \(Int(store.absenceMinutes)) minutes without mouse movement", value: $store.absenceMinutes, in: 1...30)
                        Toggle("Open for selected-chat errors and completion", isOn: $store.autoOpenEvents)
                        Text("Errors stay open until dismissed. Completion stays for 5.2 seconds unless you interact. Other chats never change your selection.")
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
                    NotchKeychain.remove(origin: account.origin, username: account.username)
                }
            }
        }
        .onChange(of: store.connectionURL) { _, _ in password = ""; savePassword = false }
        .onChange(of: store.connectionUsername) { _, _ in password = ""; savePassword = false }
        .onChange(of: store.live.mode) { _, mode in if mode == .live { password = "" } }
    }
    private func run(test: Bool) {
        // connectLive captures credentials synchronously; do not retain the field
        // through failed logins, test-only completion, or cancellation.
        store.connectLive(password: password, savePassword: savePassword, testOnly: test)
        password = ""
        savePassword = false
    }
}
