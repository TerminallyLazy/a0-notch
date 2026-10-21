import Foundation
import NotchCore

@MainActor final class FakeSpeech: DictationDriver {
    var authorizationCalls = 0
    var starts = 0
    var cancels = 0
    var onDevice = true
    var denied = false
    var suspendedAuthorization = false
    var continuation: CheckedContinuation<Void, Never>?
    var callback: (@MainActor @Sendable (String, Bool, String?) -> Void)?
    func authorize() async throws {
        authorizationCalls += 1
        if suspendedAuthorization { await withCheckedContinuation { continuation = $0 } }
        if denied { throw DictationFailure("Permission denied (fixture)") }
    }
    func supportsOnDevice(locale: String) -> Bool { onDevice }
    func start(locale: String, onDeviceOnly: Bool, update: @escaping @MainActor @Sendable (String, Bool, String?) -> Void) throws {
        starts += 1; callback = update
    }
    func cancel() { cancels += 1 }
}

@main struct DictationChecks {
    @MainActor static func check(_ passed: @autoclosure () -> Bool, _ label: String) {
        guard passed() else { fatalError("FAIL: \(label)") }
    }
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(15)) }
    @MainActor static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw DictationFailure("Fixture timed out")
    }
    @MainActor static func selectedChatChecks(root: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ready = work.appendingPathComponent("ready.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("tests/transport_http_fixture.py").path, "--scenario", "store", "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let suite = "dictation-selection-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let driver = FakeSpeech()
        let store = IslandStore(defaults: defaults, arguments: [], dictationDriver: driver)
        defer {
            store.disconnectLive()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: work)
        }
        try process.run()
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: String]
        store.connectionURL = info["origin"]!; store.connectionUsername = "fixture+user &="
        store.connectLive(password: "synthetic+password &= café", savePassword: false)
        try await wait { store.live.mode == .live }
        store.focus("fixture-root"); try await wait { store.canMutate }
        store.draft = "Existing draft"
        store.beginDictation(surface: .chat, consent: true); await settle()
        check(store.dictation.phase == .recording, "selected chat can dictate")
        driver.callback?("dictated words", true, nil)
        check(store.draft == "Existing draft" && !store.mutationBusy, "recognition never inserts or submits automatically")
        store.insertDictation()
        check(store.draft == "Existing draft dictated words" && !store.mutationBusy, "explicit insertion preserves existing draft without submitting")
        store.draft = String(repeating: "x", count: 65_530)
        store.beginDictation(surface: .chat, consent: true); await settle()
        driver.callback?("overflow transcript", true, nil)
        check(!store.insertDictation(), "oversized insertion rejected")
        check(store.dictation.transcript == "overflow transcript" && store.draft.count == 65_530, "overflow preserves transcript and draft")
        store.draft = "Shorter"
        check(store.insertDictation() && store.draft == "Shorter overflow transcript", "retained transcript can be inserted after shortening")
        store.beginDictation(surface: .chat, consent: true); await settle()
        let stale = driver.callback
        store.focus("other")
        stale?("wrong chat words", true, nil); store.insertDictation()
        check(store.draft.isEmpty && !store.dictation.active, "selection change rejects stale speech")
        try await wait { store.canMutate }
        store.chatComposerEditing = true
        store.beginDictation(surface: .chat, consent: true); await settle()
        store.chatComposerEditing = false
        check(!store.dictation.active, "composer focus loss cancels")
        store.beginDictation(surface: .island, consent: true); await settle()
        store.close()
        check(!store.dictation.active, "close cancels capture")
    }
    @MainActor static func main() async throws {
        let driver = FakeSpeech()
        let session = DictationSession(driver: driver)
        check(driver.authorizationCalls == 0 && driver.starts == 0, "init never authorizes or records")
        session.begin(locale: "en-US", onDeviceOnly: true, consent: false)
        await settle()
        check(driver.authorizationCalls == 0, "no consent means no permission request")
        driver.denied = true
        session.begin(locale: "en-US", onDeviceOnly: true, consent: true)
        await settle()
        check(session.phase == .failed && driver.starts == 0, "denial does not capture")
        driver.denied = false; driver.onDevice = false
        session.begin(locale: "en-US", onDeviceOnly: true, consent: true)
        await settle()
        check(session.phase == .failed && driver.starts == 0, "unsupported private mode fails closed")
        session.begin(locale: "en-US", onDeviceOnly: false, consent: true)
        await settle()
        check(session.phase == .recording && driver.starts == 1, "explicit fallback allowed")
        driver.callback?("hello", false, nil)
        driver.callback?("hello there", false, nil)
        check(session.transcript == "hello there", "partials replace, not append")
        let stale = driver.callback
        session.finish()
        check(session.phase == .review && session.transcript == "hello there", "stop preserves review text")
        stale?("late", true, nil)
        check(session.transcript == "hello there", "late result ignored")
        session.cancel()
        check(session.phase == .idle && session.transcript.isEmpty, "cancel discards transcript")
        driver.onDevice = true
        session.begin(locale: "en-US", onDeviceOnly: true, consent: true)
        await settle()
        driver.callback?(String(repeating: "a", count: 20_000), false, nil)
        check(session.transcript.count == 16_000, "bounded transcript")
        driver.callback?("", false, "service unavailable")
        check(session.phase == .failed && session.transcript.count == 16_000, "error cleans up and preserves partial for review")
        let pending = FakeSpeech(); pending.suspendedAuthorization = true
        let waiting = DictationSession(driver: pending)
        waiting.begin(locale: "en-US", onDeviceOnly: true, consent: true)
        await settle(); waiting.cancel(); pending.continuation?.resume(); await settle()
        check(pending.starts == 0 && waiting.phase == .idle, "cancel during authorization prevents capture")
        let boundedDriver = FakeSpeech()
        let bounded = DictationSession(driver: boundedDriver, duration: .milliseconds(20))
        bounded.begin(locale: "en-US", onDeviceOnly: true, consent: true)
        try await Task.sleep(for: .milliseconds(100))
        check(bounded.phase == .review && boundedDriver.cancels >= 2, "deadline stops driver")
        let finalDriver = FakeSpeech(); let final = DictationSession(driver: finalDriver)
        final.begin(locale: "en-US", onDeviceOnly: true, consent: true); await settle()
        finalDriver.callback?("finished words", true, nil)
        check(final.phase == .review && final.transcript == "finished words", "final result stops recording")

        let suite = "community.agentzero.notch.dictation-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeDriver = FakeSpeech()
        let store = IslandStore(defaults: defaults, arguments: [], dictationDriver: storeDriver)
        check(storeDriver.authorizationCalls == 0, "store construction never authorizes")
        store.beginDictation(surface: .chat, consent: true); await settle()
        check(storeDriver.authorizationCalls == 0, "disconnected store cannot capture")
        store.loadPreferences(origin: "https://one.example", account: "a")
        store.dictationOnDeviceOnly = false; store.dictationLocale = "fr-FR"
        store.loadPreferences(origin: "https://two.example", account: "a")
        check(store.dictationOnDeviceOnly, "new server defaults private")
        store.dictationLocale = "de-DE"
        store.loadPreferences(origin: "https://one.example", account: "a")
        check(!store.dictationOnDeviceOnly && store.dictationLocale == "fr-FR", "server scoped settings survive roundtrip")
        store.loadPreferences(origin: "https://one.example", account: "b")
        check(store.dictationOnDeviceOnly, "account isolated")
        // Drive injected session directly to check store cancellation without fake live/auth grants.
        store.dictation.begin(locale: "en-US", onDeviceOnly: true, consent: true); await settle()
        store.connectionURL = "https://different.example"
        check(!store.dictation.active, "connection edits cancel")
        store.dictation.begin(locale: "en-US", onDeviceOnly: true, consent: true); await settle()
        store.disconnectLive()
        check(!store.dictation.active, "disconnect cancels")
        store.dictation.begin(locale: "en-US", onDeviceOnly: true, consent: true); await settle()
        store.suspended = true
        check(!store.dictation.active, "suspension cancels")
        store.insertDictation()
        check(store.draft.isEmpty, "unbound results cannot insert")
        check(store.modelSettingsGuidance.contains("this chat only"), "honest core capability")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("app/Info.plist")), format: nil) as! [String: Any]
        check((plist["NSMicrophoneUsageDescription"] as? String)?.contains("45 seconds") == true, "microphone purpose string")
        check((plist["NSSpeechRecognitionUsageDescription"] as? String)?.contains("Apple") == true, "speech purpose discloses server")
        try await selectedChatChecks(root: root)
        print("DICTATION_CHECKS_PASS: consent, denial, private mode, partial/final/error, stale callbacks, cancellation, deadline, scoped settings, store gates, plist. Real Apple adapter compiled but never started.")
    }
}
