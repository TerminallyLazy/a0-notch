import Foundation
import XCTest
@testable import NotchCore

/// Real URLSession against a disposable loopback HTTP peer; never the user's A0.
/// Requires an existing python3, with no packages. Does not exercise Keychain or IslandStore UI.
@MainActor
final class LiveHTTPClientTests: XCTestCase {
    private let username = "fixture+user &="
    private let password = "synthetic+password &= café"

    private func withFixture(_ scenario: String = "normal",
                             body: (HTTPFixture, LiveHTTPClient) async throws -> Void) async throws {
        let fixture = try await HTTPFixture(scenario: scenario)
        defer { fixture.stop() }
        let client = LiveHTTPClient(origin: try LiveOrigin(fixture.origin))
        do {
            try await body(fixture, client)
            await client.cancel()
        } catch {
            await client.cancel()
            throw error
        }
    }
    private func login(_ client: LiveHTTPClient) async throws {
        try await client.authenticate(username: username, password: password)
    }
    private func expect(_ expected: LiveError,
                        operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected a safe client error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LiveError, expected, file: file, line: line)
        }
    }
    private func statusFailure(_ scenario: String, _ error: LiveError) async throws {
        try await withFixture(scenario) { fixture, client in
            try await self.login(client)
            await self.expect(error) { _ = try await client.status() }
            let counts = try await fixture.counters()
            let trap = try await fixture.counters(trap: true)
            XCTAssertEqual(counts.counts["redirect_target", default: 0], 0)
            XCTAssertEqual(trap.counts["redirect_target", default: 0], 0)
            XCTAssertFalse(counts.lease_active)
        }
    }

    func testLoginCookiesCSRFStatusConnectPollDisconnect() async throws {
        try await withFixture { fixture, client in
            try await self.login(client)
            let status = try await client.status()
            XCTAssertEqual(status.auth, "session_csrf")
            XCTAssertEqual(status.contexts.map(\.id), ["fixture-root"])
            let id = UUID()
            let initial = try await client.exchange(action: "connect", clientID: id)
            XCTAssertTrue(initial.reset == true)
            XCTAssertEqual(initial.cursor, 0)
            let poll = try await client.exchange(action: "poll", clientID: id,
                                                 epoch: initial.server_epoch, cursor: initial.cursor)
            XCTAssertEqual(poll.events?.first?.kind, "finished")
            XCTAssertEqual(poll.cursor, 1)
            _ = try await client.exchange(action: "disconnect", clientID: id, epoch: initial.server_epoch)
            let state = try await fixture.counters()
            XCTAssertFalse(state.lease_active)
            for key in ["login", "csrf", "status", "connect", "poll", "disconnect"] {
                XCTAssertEqual(state.counts[key], 1, key)
            }
            XCTAssertEqual(state.counts["redirect_target", default: 0], 0)
            XCTAssertEqual(state.counts["guard_rejection", default: 0], 0)
        }
    }
    func testEmptyAuthorizationIsValidButHasNoContexts() async throws {
        try await withFixture("empty") { _, client in
            try await self.login(client)
            let status = try await client.status()
            XCTAssertTrue(status.contexts.isEmpty)
            let envelope = try await client.exchange(action: "connect", clientID: UUID())
            XCTAssertTrue(envelope.contexts.isEmpty)
        }
    }
    func testMissingCredentialsMakeNoRequest() async throws {
        try await withFixture { fixture, client in
            await self.expect(.authentication) { try await client.authenticate(username: "", password: "") }
            let state = try await fixture.counters()
            XCTAssertTrue(state.counts.isEmpty)
        }
    }
    func testBadLoginHTMLRejected() async throws {
        try await withFixture("bad_login") { fixture, client in
            await self.expect(.authentication) { try await self.login(client) }
            let state = try await fixture.counters()
            XCTAssertNil(state.counts["csrf"])
        }
    }
    func testLoginRedirectWithoutCookieDoesNotAuthenticate() async throws {
        try await withFixture("login_without_cookie") { _, client in
            await self.expect(.authentication) { try await self.login(client) }
        }
    }
    func testLoginCrossOriginRedirectNeverReached() async throws {
        try await withFixture("login_redirect") { fixture, client in
            await self.expect(.authentication) { try await self.login(client) }
            let trap = try await fixture.counters(trap: true)
            XCTAssertEqual(trap.counts["redirect_target", default: 0], 0)
        }
    }
    func testMalformedCSRFReturnsSafePayloadError() async throws {
        try await withFixture("csrf_malformed") { _, client in
            await self.expect(.invalidPayload) { try await self.login(client) }
        }
    }
    func testInvalidCSRFRejected() async throws {
        try await withFixture("csrf_invalid") { _, client in
            await self.expect(.authentication) { try await self.login(client) }
        }
    }
    func testProtectedStatus401Rejected() async throws { try await statusFailure("status_unauthorized", .authentication) }
    func testProtectedStatus403Rejected() async throws { try await statusFailure("status_forbidden", .authentication) }
    func testSameOriginRedirectNotFollowed() async throws { try await statusFailure("status_redirect", .authentication) }
    func testCrossOriginRedirectNotFollowed() async throws { try await statusFailure("status_cross_redirect", .authentication) }
    func testHTMLInsteadOfMetadataRejected() async throws { try await statusFailure("status_html", .invalidPayload) }
    func testMalformedMetadataRejected() async throws { try await statusFailure("status_malformed", .invalidPayload) }
    func testDeclaredOversizedResponseRejected() async throws { try await statusFailure("status_oversized", .oversized) }
    func testChunkedOversizedResponseRejected() async throws { try await statusFailure("status_stream_oversized", .oversized) }
    func testLeaseConflictPreservesHTTPCode() async throws {
        try await withFixture("lease_conflict") { _, client in
            try await self.login(client)
            await self.expect(.http(409)) { _ = try await client.exchange(action: "connect", clientID: UUID()) }
        }
    }
    func testCookieJarNotSharedByFreshClient() async throws {
        try await withFixture { fixture, client in
            try await self.login(client)
            _ = try await client.status()
            let fresh = LiveHTTPClient(origin: try LiveOrigin(fixture.origin))
            await self.expect(.authentication) { _ = try await fresh.status() }
            await fresh.cancel()
            let counts = try await fixture.counters()
            XCTAssertEqual(counts.counts["cookie_without_csrf", default: 0], 0)
            _ = try await client.status()
        }
    }
    func testPollAuthenticationLossMarksAcceptedDataStale() async throws {
        try await withFixture("poll_unauthorized") { _, client in
            try await self.login(client)
            let id = UUID()
            var state = LiveSessionState()
            let generation = state.begin()
            let envelope = try await client.exchange(action: "connect", clientID: id)
            _ = try state.accept(envelope, generation: generation, now: 0)
            await self.expect(.authentication) {
                _ = try await client.exchange(action: "poll", clientID: id, epoch: envelope.server_epoch, cursor: 0)
            }
            state.fail(generation: generation)
            XCTAssertEqual(state.mode, .stale)
            XCTAssertTrue(state.contexts.isEmpty)
        }
    }
    private func cancelledPoll(invalidateClient: Bool) async throws {
        try await withFixture("held_poll") { fixture, client in
            try await self.login(client)
            let id = UUID()
            let envelope = try await client.exchange(action: "connect", clientID: id)
            let task = Task { try await client.exchange(action: "poll", clientID: id,
                                                        epoch: envelope.server_epoch, cursor: 0) }
            try await fixture.waitForPoll()
            let clock = ContinuousClock()
            let start = clock.now
            if invalidateClient { await client.cancel() } else { task.cancel() }
            do {
                _ = try await task.value
                XCTFail("Cancelled poll must not deliver metadata")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
            try await fixture.release()
        }
    }
    func testTaskCancellationStopsPendingURLSessionPoll() async throws { try await cancelledPoll(invalidateClient: false) }
    func testClientInvalidationStopsPendingURLSessionPoll() async throws { try await cancelledPoll(invalidateClient: true) }

    private func latePollCannotRevive(_ mode: LiveSessionState.Mode) async throws {
        try await withFixture("held_poll") { fixture, client in
            try await self.login(client)
            let id = UUID()
            var state = LiveSessionState()
            let generation = state.begin()
            let envelope = try await client.exchange(action: "connect", clientID: id)
            _ = try state.accept(envelope, generation: generation, now: 0)
            let task = Task { try await client.exchange(action: "poll", clientID: id,
                                                        epoch: envelope.server_epoch, cursor: 0) }
            try await fixture.waitForPoll()
            if mode == .stale { XCTAssertTrue(state.expire(now: 10)) } else { state.clear(mode) }
            // Deliberately let an in-flight reply arrive: generation protection must work
            // even when cancellation races with completion. No claim of UI integration.
            try await fixture.release()
            let late = try await task.value
            XCTAssertFalse(try state.accept(late, generation: generation, now: 11))
            XCTAssertEqual(state.mode, mode)
            XCTAssertTrue(state.contexts.isEmpty)
            _ = try await client.exchange(action: "disconnect", clientID: id, epoch: envelope.server_epoch)
            let counts = try await fixture.counters()
            XCTAssertFalse(counts.lease_active)
        }
    }
    func testLatePollCannotReviveDisconnectedState() async throws { try await latePollCannotRevive(.disconnected) }
    func testLatePollCannotReviveStaleState() async throws { try await latePollCannotRevive(.stale) }
    func testNormalChatAPIsUseOwnedSessionAndCSRF() async throws {
        try await withFixture { fixture, client in
            try await self.login(client); _ = try await client.status()
            let snapshot = try await client.recentSnapshot(context: "fixture-root")
            XCTAssertEqual(snapshot.lastResponse, "Synthetic answer")
            try await client.send(context: "fixture-root", text: "Synthetic reply", messageID: UUID())
            try await client.setPaused(context: "fixture-root", paused: true)
            let paused = try await client.recentSnapshot(context: "fixture-root")
            XCTAssertTrue(paused.paused)
            try await client.setPaused(context: "fixture-root", paused: false)
            try await client.stop(context: "fixture-root")
            let id = UUID().uuidString
            let created = try await client.createChat(id: id)
            XCTAssertEqual(created, id)
            let status = try await client.status()
            XCTAssertTrue(status.contexts.contains { $0.id == id })
            let counts = try await fixture.counters().counts
            XCTAssertEqual(counts["chat_message_async"], 1)
            XCTAssertEqual(counts["chat_pause"], 2)
            XCTAssertEqual(counts["chat_stop"], 1)
            XCTAssertEqual(counts["chat_chat_create"], 1)
            XCTAssertNil(counts["guard_rejection"])
        }
    }
    func testActionsCannotRunBeforeOwnedLoginAndPluginStatus() async throws {
        try await withFixture { fixture, client in
            await self.expect(.authentication) { try await client.send(context: "fixture-root", text: "Test", messageID: UUID()) }
            try await self.login(client)
            await self.expect(.authentication) { try await client.setPaused(context: "fixture-root", paused: true) }
            let counts = try await fixture.counters().counts
            XCTAssertNil(counts["chat_message_async"]); XCTAssertNil(counts["chat_pause"])
        }
    }
    func testDiscoveryOverFiveChats() async throws {
        try await withFixture("many") { _, client in
            try await self.login(client)
            let status = try await client.status()
            XCTAssertEqual(status.contexts.count, 251)
            XCTAssertEqual(status.contexts.first { $0.id == "chat-1" }?.parent_id, "fixture-root")
        }
    }
    func testWrongOrMissingSelectedChatRejected() async throws {
        for scenario in ["wrong_chat", "missing_chat"] {
            try await withFixture(scenario) { _, client in
                try await self.login(client); _ = try await client.status()
                await self.expect(.invalidPayload) { _ = try await client.recentSnapshot(context: "fixture-root") }
            }
        }
    }
    func testAmbiguousSendIsNeverReplayed() async throws {
        try await withFixture("ambiguous_send") { fixture, client in
            try await self.login(client); _ = try await client.status()
            await self.expect(.invalidPayload) { try await client.send(context: "fixture-root", text: "Once", messageID: UUID()) }
            try await Task.sleep(for: .milliseconds(100))
            let counts = try await fixture.counters().counts
            XCTAssertEqual(counts["chat_message_async"], 1)
        }
    }
    func testMutationAuthenticationFailureDoesNotFallback() async throws {
        try await withFixture("mutation_forbidden") { fixture, client in
            try await self.login(client); _ = try await client.status()
            await self.expect(.authentication) { try await client.stop(context: "fixture-root") }
            let counts = try await fixture.counters().counts
            XCTAssertEqual(counts["chat_stop"], 1); XCTAssertEqual(counts["login"], 1)
        }
    }
    func testInvalidMutationInputsMakeNoWriteRequest() async throws {
        try await withFixture { fixture, client in
            try await self.login(client); _ = try await client.status()
            await self.expect(.invalidPayload) { try await client.send(context: "fixture-root", text: "  ", messageID: UUID()) }
            await self.expect(.invalidPayload) { try await client.send(context: "", text: "Text", messageID: UUID()) }
            await self.expect(.invalidPayload) { _ = try await client.createChat(id: "") }
            let counts = try await fixture.counters().counts
            XCTAssertNil(counts["chat_message_async"]); XCTAssertNil(counts["chat_chat_create"])
        }
    }

}

@MainActor
private final class HTTPFixture {
    struct Ready: Decodable { let origin: String; let trap_origin: String }
    struct Counters: Decodable { let counts: [String: Int]; let lease_active: Bool }
    private let process = Process()
    private let directory: URL
    private let control = URLSession(configuration: .ephemeral)
    private(set) var origin = ""
    private var trapOrigin = ""

    init(scenario: String) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("a0-notch-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/m5_http_fixture.py").path,
                             "--scenario", scenario, "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: ready), let result = try? JSONDecoder().decode(Ready.self, from: data) {
                    origin = result.origin; trapOrigin = result.trap_origin
                    return
                }
                guard process.isRunning else { throw FixtureError.startup }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw FixtureError.startup
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        control.invalidateAndCancel()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
    func counters(trap: Bool = false) async throws -> Counters {
        let request = URLRequest(url: URL(string: (trap ? trapOrigin : origin) + "/__fixture")!, timeoutInterval: 2)
        let (data, response) = try await control.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.control }
        return try JSONDecoder().decode(Counters.self, from: data)
    }
    func waitForPoll() async throws {
        for _ in 0..<100 {
            if try await counters().counts["poll", default: 0] > 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.control
    }
    func release() async throws {
        var request = URLRequest(url: URL(string: origin + "/__fixture/release")!, timeoutInterval: 2)
        request.httpMethod = "POST"; request.httpBody = Data()
        let (_, response) = try await control.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.control }
    }
    enum FixtureError: Error { case startup, control }
}

extension LiveHTTPClientTests {
    func testLegacyPluginCannotReceiveUnsafeMutationFallback() async throws {
        try await withFixture("legacy_actions") { fixture, client in
            try await self.login(client); _ = try await client.status()
            await self.expect(.unsupportedActions) {
                try await client.send(context: "fixture-root", text: "hello", messageID: UUID())
            }
            await self.expect(.unsupportedActions) { try await client.setPaused(context: "fixture-root", paused: true) }
            await self.expect(.unsupportedActions) { try await client.stop(context: "fixture-root") }
            let counts = try await fixture.counters().counts
            XCTAssertNil(counts["chat_message_async"])
            XCTAssertNil(counts["chat_pause"])
            XCTAssertNil(counts["chat_stop"])
        }
    }
}
