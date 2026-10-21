import XCTest
@testable import NotchCore

final class LiveProtocolTests: XCTestCase {
    private let epoch = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private func payload(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var value: [String: Any] = ["ok": true, "schema_version": 1, "server_epoch": epoch,
            "cursor": 1, "reset": false,
            "contexts": [["id":"root", "name":"Context 1", "state":"working", "tool":"browser", "running":true]],
            "events": [["sequence":1,"context_id":"root","state":"working","tool":"browser","kind":"tool_start","observed_at":1]],
            "dropped": ["overflow":0,"contention":0,"invalid":0,"no_consumer":0]]
        edit(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testPaginationIntMaxRejectsWithoutOverflow() throws {
        for next in [nil, Int.max] as [Int?] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { value in
                value["schema_version"] = 2; value["page_token"] = self.epoch
                value["page_offset"] = Int.max; value["catalog_count"] = Int.max
                if let next { value["next_offset"] = next }
                var rows = value["contexts"] as! [[String: Any]]
                rows[0]["incarnation"] = self.epoch; value["contexts"] = rows
            }))
        }
    }
    func testValidEnvelope() throws {
        let result = try LiveEnvelope.decode(payload())
        XCTAssertEqual(result.contexts.first?.id, "root")
        XCTAssertEqual(result.events?.count, 1)
    }
    func testInvalidJSONAndLimits() throws {
        for data in [Data("<html>login</html>".utf8), Data("{}".utf8), Data(repeating: 32, count: 2097153)] {
            XCTAssertThrowsError(try LiveEnvelope.decode(data))
        }
    }
    func testInvalidSchemaAndEpoch() throws {
        for key in ["schema_version", "server_epoch", "ok", "cursor"] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { $0[key] = "invalid" }))
        }
    }
    func testDuplicateOrExcessContexts() throws {
        for count in [2, 6] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { value in
                let row = (value["contexts"] as! [[String: Any]])[0]
                value["contexts"] = Array(repeating: row, count: count)
            }))
        }
    }
    func testInvalidStatesAndControls() throws {
        for (key, value) in [("state","intervention"), ("name","line\nbreak"), ("tool",String(repeating:"x",count:65))] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { data in
                var rows = data["contexts"] as! [[String: Any]]; rows[0][key] = value; data["contexts"] = rows
            }))
        }
    }
    func testInvalidEvents() throws {
        for key in ["context_id", "kind", "state", "sequence"] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { data in
                var events = data["events"] as! [[String: Any]]; events[0][key] = "invalid"; data["events"] = events
            }))
        }
        XCTAssertThrowsError(try LiveEnvelope.decode(payload { data in
            let event = (data["events"] as! [[String: Any]])[0]; data["events"] = [event, event]
        }))
    }
    func testOrigins() throws {
        for valid in ["http://127.0.0.1:54321", "http://localhost:80/", "https://a0.example.org", "http://[::1]:80"] {
            XCTAssertNoThrow(try LiveOrigin(valid))
        }
        for bad in ["", "ftp://example.org", "http://example.org", "https://u:p@example.org", "https://example.org/api", "https://example.org/?token=x", "https://example.org/#x", "http://localhost.evil.org", "https://example.org:0"] {
            XCTAssertThrowsError(try LiveOrigin(bad))
        }
    }
    func testStaleClearsCurrentActivity() throws {
        var state = LiveSessionState(); let gen = state.begin()
        XCTAssertTrue(try state.accept(LiveEnvelope.decode(payload()), generation: gen, now: 10))
        XCTAssertFalse(state.expire(now: 19.99))
        XCTAssertTrue(state.expire(now: 20))
        XCTAssertEqual(state.mode, .stale); XCTAssertTrue(state.contexts.isEmpty)
        XCTAssertFalse(try state.accept(LiveEnvelope.decode(payload()), generation: gen, now: 21))
    }
    func testDisconnectIsolation() throws {
        var state = LiveSessionState(); let gen = state.begin()
        state.clear()
        XCTAssertFalse(try state.accept(LiveEnvelope.decode(payload()), generation: gen, now: 10))
        XCTAssertEqual(state.mode, .disconnected)
    }
    func testOldGenerationCannotReplaceReconnect() throws {
        var state = LiveSessionState(); let old = state.begin(); let new = state.begin()
        XCTAssertFalse(try state.accept(LiveEnvelope.decode(payload()), generation: old, now: 10))
        XCTAssertTrue(try state.accept(LiveEnvelope.decode(payload()), generation: new, now: 11))
    }
    func testReplayAndEpochChangeRejected() throws {
        var state = LiveSessionState(); let gen = state.begin()
        _ = try state.accept(LiveEnvelope.decode(payload()), generation: gen, now: 10)
        XCTAssertThrowsError(try state.accept(LiveEnvelope.decode(payload()), generation: gen, now: 11))
        XCTAssertThrowsError(try state.accept(LiveEnvelope.decode(payload { $0["server_epoch"] = UUID().uuidString }), generation: gen, now: 11))
    }
    func testInitialFailureIsDisconnected() {
        var state = LiveSessionState(); let gen = state.begin(); state.fail(generation: gen)
        XCTAssertEqual(state.mode, .disconnected)
    }
    func testStatusRequiresCapabilitiesAndAuth() throws {
        XCTAssertThrowsError(try LiveEnvelope.decode(payload(), status:true))
        XCTAssertNoThrow(try LiveEnvelope.decode(payload {
            $0["auth"] = "session_csrf"; $0["plugin_version"] = "0.6.0"; $0["capabilities"] = ["discovery", "metadata", "poll"]
        }, status:true))
    }
    func testDiscoveryHasNoFiveChatCapAndKeepsParentIdentity() throws {
        let result = try LiveEnvelope.decode(payload { value in
            value["contexts"] = (0..<1000).map { index -> [String: Any] in
                ["id": index == 0 ? "root" : "chat-\(index)", "name": "Chat \(index)",
                 "state": "idle", "tool": "", "running": false,
                 "parent_id": index == 0 ? NSNull() : "root", "last_activity_at": 12.5, "created_at": 1]
            }
        })
        XCTAssertEqual(result.contexts.count, 1000)
        XCTAssertEqual(result.contexts.last?.parent_id, "root")
    }
    func testOldReadOnlyCapabilityRejected() throws {
        XCTAssertThrowsError(try LiveEnvelope.decode(payload {
            $0["auth"] = "session_csrf"; $0["plugin_version"] = "0.5.0"
            $0["capabilities"] = ["read_only", "metadata", "poll"]
        }, status: true))
    }
    func testExactByteLimit() throws {
        var data = try payload()
        data.append(Data(repeating: 32, count: 2 * 1024 * 1024 - data.count))
        XCTAssertNoThrow(try LiveEnvelope.decode(data))
        data.append(32)
        XCTAssertThrowsError(try LiveEnvelope.decode(data)) { XCTAssertEqual($0 as? LiveError, .oversized) }
    }
    func testInvalidParentAndTimestamps() throws {
        for (key, value) in [("parent_id", "root" as Any), ("parent_id", ""), ("created_at", -1)] {
            XCTAssertThrowsError(try LiveEnvelope.decode(payload { data in
                var rows = data["contexts"] as! [[String: Any]]; rows[0][key] = value; data["contexts"] = rows
            }))
        }
    }
    func testMutationRequiresFreshExactTargetAndSelectionRevision() throws {
        var state = LiveSessionState(); let generation = state.begin(); let selection = UUID()
        let target = ChatTarget(context: "root", generation: generation, selection: selection)
        XCTAssertFalse(state.permits(target, selected: "root", selection: selection, now: 0))
        _ = try state.accept(LiveEnvelope.decode(payload()), generation: generation, now: 10)
        XCTAssertTrue(state.permits(target, selected: "root", selection: selection, now: 19.99))
        XCTAssertFalse(state.permits(target, selected: "root", selection: selection, now: 20))
        XCTAssertFalse(state.permits(target, selected: "other", selection: selection, now: 11))
        XCTAssertFalse(state.permits(target, selected: "root", selection: UUID(), now: 11))
        XCTAssertFalse(state.permits(target, selected: "root", selection: selection, now: 9))
        state.clear()
        XCTAssertFalse(state.permits(target, selected: "root", selection: selection, now: 11))
    }
    func testRemovalRevokesTargetWithoutReconnect() throws {
        var state = LiveSessionState(); let generation = state.begin(); let selection = UUID()
        _ = try state.accept(LiveEnvelope.decode(payload()), generation: generation, now: 10)
        let target = ChatTarget(context: "root", generation: generation, selection: selection)
        _ = try state.accept(LiveEnvelope.decode(payload { $0["contexts"] = []; $0["events"] = [] }), generation: generation, now: 11)
        XCTAssertFalse(state.permits(target, selected: "root", selection: selection, now: 11))
    }
    func testSnapshotUsesOnlySelectedMainAgentResponse() throws {
        var value: [String: Any] = ["context": "root", "deselect_chat": false, "log_guid": "guid", "log_version": 100,
            "paused": false, "log_progress": "Step", "log_progress_active": true,
            "logs": [["no": 2, "type": "response", "content": "Main answer", "heading": "", "agentno": 0],
                     ["no": 3, "type": "response", "content": "Subordinate answer", "heading": "", "agentno": 1]]]
        func decode(_ target: String = "root") throws -> ChatSnapshot {
            try ChatSnapshot.decode(JSONSerialization.data(withJSONObject: value), target: target)
        }
        XCTAssertEqual(try decode().lastResponse, "Main answer")
        XCTAssertThrowsError(try decode("other"))
        value["deselect_chat"] = true
        XCTAssertThrowsError(try decode())
        value["deselect_chat"] = false
        value["logs"] = [["no": 1, "type": "user", "content": "Question", "heading": "", "agentno": 0]]
        XCTAssertNil(try decode().lastResponse)
    }

}
