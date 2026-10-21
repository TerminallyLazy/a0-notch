import Foundation
import XCTest
@testable import NotchCore

final class TransportV2Tests: XCTestCase {
    func testAttachmentValidation() throws {
        let content = Data("safe text".utf8)
        XCTAssertEqual(try LiveAttachment(filename: "notes.md", data: content).contentType, "text/markdown")
        for name in ["../a.txt", ".env", "a/../b.txt", "image.svg", "file.txt\r\nInjected", "file.txt "] {
            XCTAssertThrowsError(try LiveAttachment(filename: name, data: content))
        }
        XCTAssertThrowsError(try LiveAttachment(filename: "a.txt", data: Data()))
        XCTAssertThrowsError(try LiveAttachment(filename: "a.txt", data: Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
    }
    func testIncompletePagesCannotEnterLiveState() throws {
        let epoch = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let payload: [String: Any] = ["ok":true, "schema_version":1, "server_epoch":epoch,
            "cursor":0, "reset":true, "events":[], "dropped":["overflow":0,"contention":0,"no_consumer":0,"invalid":0],
            "page_token":epoch, "page_offset":0, "catalog_count":2, "next_offset":1,
            "contexts":[["id":"a","name":"A","state":"idle","tool":"","running":false,"incarnation":epoch]]]
        let envelope = try LiveEnvelope.decode(JSONSerialization.data(withJSONObject: payload))
        var state = LiveSessionState(); let gen = state.begin()
        XCTAssertThrowsError(try state.accept(envelope, generation: gen, now: 0))
        XCTAssertTrue(state.contexts.isEmpty)
    }
    func testCapturedIncarnationGuardsSelection() throws {
        let epoch = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let payload: [String: Any] = ["ok":true, "schema_version":1, "server_epoch":epoch,
            "cursor":0, "reset":true, "events":[], "dropped":["overflow":0,"contention":0,"no_consumer":0,"invalid":0],
            "contexts":[["id":"a","name":"A","state":"idle","tool":"","running":false,"incarnation":epoch]]]
        var state = LiveSessionState(); let gen = state.begin(); let selection = UUID()
        _ = try state.accept(LiveEnvelope.decode(JSONSerialization.data(withJSONObject: payload)), generation: gen, now: 0)
        XCTAssertTrue(state.permits(ChatTarget(context: "a", generation: gen, selection: selection, incarnation: epoch), selected: "a", selection: selection, now: 1))
        XCTAssertFalse(state.permits(ChatTarget(context: "a", generation: gen, selection: selection), selected: "a", selection: selection, now: 1))
        XCTAssertFalse(state.permits(ChatTarget(context: "a", generation: gen, selection: selection, incarnation: UUID().uuidString), selected: "a", selection: selection, now: 1))
    }
}

extension TransportV2Tests {
    func testURLAttachmentRejectsSymlinkAndSpecialFile() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("synthetic text".utf8).write(to: file)
        XCTAssertEqual(try LiveAttachment(url: file).data, Data("synthetic text".utf8))
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try LiveAttachment(url: link))
        let linkedDirectory = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        XCTAssertThrowsError(try LiveAttachment(url: linkedDirectory.appendingPathComponent("note.txt")))
        XCTAssertThrowsError(try LiveAttachment(url: directory))
        XCTAssertThrowsError(try LiveAttachment(url: URL(fileURLWithPath: "/dev/null")))
    }
}
