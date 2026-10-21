import AppKit
import SwiftUI
import NotchCore
import Security

@main
@MainActor
struct AppIntegrationChecks {
    static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = root.appendingPathComponent("build").appendingPathComponent("notch-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ready = work.appendingPathComponent("ready.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("tests/transport_http_fixture.py").path, "--scenario", "store", "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let suite = "notch-store-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = IslandStore(defaults: defaults, arguments: [])
        defer {
            store.disconnectLive()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: work)
        }
        try process.run()
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: String]
        let origin = info["origin"]!
        store.connectionURL = origin; store.connectionUsername = "fixture+user &= " .trimmingCharacters(in: .whitespaces)
        store.connectLive(password: "synthetic+password &= café", savePassword: false)
        try await wait { store.live.mode == .live }
        try check(store.contexts.count == 2 && store.focusedID.isEmpty && store.chatSnapshot == nil, "discovery never selects/fetches")
        store.focus("fixture-root")
        try await wait { store.canMutate }
        try check(store.target.incarnation != nil && store.lastResponse == "Synthetic answer", "captured incarnation snapshot")
        // Keychain status classification uses synthetic OSStatus values, never real credentials.
        let keychainSuccess = try NotchKeychain.check(errSecSuccess)
        try check(keychainSuccess, "keychain success")
        let keychainAbsent = try NotchKeychain.check(errSecItemNotFound)
        try check(!keychainAbsent, "keychain absent")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            do { _ = try NotchKeychain.check(status); throw NSError(domain: "keychain failure swallowed", code: 1) }
            catch is NotchKeychain.Failure {}
        }
        // Equal persisted values must not be rewritten just because JSON key order differs.
        let preferenceKey = defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("contexts.v1.") && !$0.contains(".dictation.") }!
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let existingPreferences = try encoder.encode(store.preferences.persistence)
        defaults.set(existingPreferences, forKey: preferenceKey)
        store.savePreferences()
        try check(defaults.data(forKey: preferenceKey) == existingPreferences, "unchanged preferences preserve stored bytes")
        try NotchKeychain.checkWrite(errSecSuccess)
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            do { try NotchKeychain.checkWrite(status); throw NSError(domain: "keychain write failure swallowed", code: 1) }
            catch is NotchKeychain.Failure {}
        }
        store.loadModelPresets()
        try await wait { store.modelPresets != nil }
        let modelTarget = store.target
        let otherPreset = store.modelPresets!.presets.first { $0.label == "Other" }!.id
        store.selectModelPreset(otherPreset, target: modelTarget)
        try await wait { !store.mutationBusy }
        try check(store.modelPresets?.current_label == "Other", "real native preset selection")
        store.focus("other")
        store.selectModelPreset(otherPreset, target: modelTarget)
        try check(!store.mutationBusy, "stale preset selection rejected")
        store.focus("fixture-root")
        try await wait { store.canMutate }
        let captured = store.target
        let capturedIdentity = store.focusedIdentity!
        store.draft = "Explicit integration message"
        store.perform(.send, target: captured)
        try await wait { !store.mutationBusy }
        try check(store.draft.isEmpty && !store.uncertainOutcome, "real Store send dispatch")
        try await wait { store.canMutate }
        let file = work.appendingPathComponent("sample.txt")
        try Data("synthetic attachment".utf8).write(to: file)
        _ = try LiveAttachment(url: file)
        store.stageFiles([file], target: store.target)
        try await wait { store.transfer.phase == .staged }
        try check(store.transfer.phase == .staged, "secure staging: \(store.mutationMessage)")
        store.uploadFiles()
        try await wait { !store.mutationBusy }
        if case .result(let receipt) = store.transfer.phase { try check(receipt.files.count == 1, "authoritative receipt") }
        else { throw NSError(domain: "upload receipt missing", code: 2) }
        store.chooseFiles(.askAboutFiles)
        try check(!store.draft.isEmpty, "ask about files only drafts")
        // Cancel A, immediately start B, then let A's cancellation unwind.
        func control(_ path: String) async throws {
            var request = URLRequest(url: URL(string: origin + "/__fixture/" + path)!)
            request.httpMethod = "POST"; _ = try await URLSession.shared.data(for: request)
        }
        try await control("hold")
        store.createChat()
        try check(store.mutationBusy, "creation A started")
        store.focus("other"); store.acknowledgeOutcome(); store.createChat()
        try check(store.mutationBusy, "creation B started")
        let creationMessage = store.mutationMessage
        try await Task.sleep(for: .milliseconds(250))
        try check(store.mutationBusy && store.mutationMessage == creationMessage, "late creation A cannot clear B")
        store.createChat()
        try check(store.mutationMessage == creationMessage, "third create blocked")
        try await control("release")
        try await wait { !store.mutationBusy }
        store.focus("fixture-root"); store.acknowledgeOutcome()
        try await wait { store.canMutate }
        try await control("hold")
        store.stageFiles([file], target: store.target)
        try await wait { store.transfer.phase == .staged }
        store.uploadFiles(); store.cancelUpload(); store.acknowledgeOutcome()
        store.stageFiles([file], target: store.target)
        try await wait { store.transfer.phase == .staged }
        store.uploadFiles()
        try check(store.mutationBusy, "upload B started after cancellation A")
        let uploadMessage = store.mutationMessage
        try await Task.sleep(for: .milliseconds(250))
        try check(store.mutationBusy && store.mutationMessage == uploadMessage, "late upload A cannot clear B")
        try await control("release")
        try await wait { !store.mutationBusy }
        var request = URLRequest(url: URL(string: origin + "/__fixture/advance")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        try await wait { store.expanded.attention.requiresAttention }
        try check(store.focusedID == "fixture-root" && store.lastResponse == "Synthetic answer", "other-chat alert cannot select or load")
        try check(store.expanded.attention.first?.id.context.contextID == "other", "metadata alert queued")
        store.draft = "Must be invalidated on replacement"
        _ = try await URLSession.shared.data(for: request)
        try await wait { store.focusedID.isEmpty }
        try check(store.chatSnapshot == nil && store.lastResponse.isEmpty && store.draft.isEmpty && store.transfer.files.isEmpty, "replacement clears content drafts files")
        store.perform(.send, target: captured)
        try check(!store.mutationBusy, "stale captured row never sends")
        store.focus(capturedIdentity)
        try check(store.focusedID.isEmpty, "stale completion identity cannot select replacement")
        store.focus("fixture-root")
        try check(store.draft.isEmpty && store.target.incarnation != captured.incarnation, "replacement requires explicit selection")
        store.disconnectLive()
        try check(store.expanded.attention.entries.isEmpty && store.contexts.isEmpty, "disconnect clears queue")
        print("PASS: integrated Store discovery, selection, captured send, upload receipt, cross-chat alert isolation, replacement revocation, disconnect")
    }
    static func check(_ result: @autoclosure () -> Bool, _ label: String) throws { if !result() { throw NSError(domain: label, code: 1) } }
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw NSError(domain: "integration state timeout", code: 3)
    }
}
