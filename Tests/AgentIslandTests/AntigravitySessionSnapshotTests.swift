import XCTest
@testable import AgentIsland

final class AntigravitySessionSnapshotTests: XCTestCase {
    private func write(_ objects: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for object in objects {
            data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10)
        }
        try data.write(to: file)
    }

    private func question(_ text: String, date: Date) -> [String: Any] {
        ["type": "PLANNER_RESPONSE", "status": "DONE", "timestamp": ISO8601DateFormatter().string(from: date),
         "tool_calls": [["name": "ask_question", "args": ["questions": [["question": text, "options": ["Yes", "No"]]]]]]]
    }

    private func transcript(_ root: URL, _ id: String, branch: String = "a") -> URL {
        root.appendingPathComponent(id).appendingPathComponent(branch).appendingPathComponent("b").appendingPathComponent("transcript.jsonl")
    }

    func testIdenticalQuestionsHaveIndependentStableSessionIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID().uuidString, secondID = UUID().uuidString, now = Date()
        let first = transcript(root, firstID), second = transcript(root, secondID)
        try write([question("Same question", date: now)], to: first)
        try write([question("Same question", date: now)], to: second)
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let before = await scanner.scan(now: now)
        XCTAssertEqual(before.antigravitySessions.count, 2)
        XCTAssertEqual(Set(before.antigravitySessions.map(\.id)).count, 2)
        XCTAssertTrue(before.antigravitySessions.allSatisfy { $0.state == .awaitingInput && $0.pendingIdentity != nil })
        XCTAssertEqual(Set(before.antigravitySessions.compactMap(\.actionDetail)).count, 1)
        XCTAssertTrue(before.antigravitySessions.allSatisfy { !$0.id.contains(firstID) && !$0.id.contains(secondID) && !$0.id.contains(root.path) })
        let firstSnapshot = try XCTUnwrap(before.antigravitySessions.first { $0.pendingIdentity?.transcript.resolvingSymlinksInPath() == first.resolvingSymlinksInPath() })
        // Append result and assistant response, just as a real answered question does.
        let handle = try FileHandle(forWritingTo: first); try handle.seekToEnd()
        for event in [["type": "GENERIC", "status": "DONE"], ["type": "PLANNER_RESPONSE", "status": "DONE", "content": "done"]] {
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
        }
        try handle.close()
        let after = await scanner.scan(now: now.addingTimeInterval(1))
        let same = try XCTUnwrap(after.antigravitySessions.first { $0.id == firstSnapshot.id })
        XCTAssertEqual(same.state, .completed)
        XCTAssertNil(same.pendingIdentity)
        XCTAssertEqual(after.antigravitySessions.filter { $0.state == .awaitingInput }.count, 1)
        let later = await scanner.scan(now: now.addingTimeInterval(7))
        XCTAssertEqual(later.antigravitySessions.count, 2)
        XCTAssertEqual(later.antigravitySessions.filter { $0.state == .awaitingInput }.count, 1)
        XCTAssertEqual(later.antigravitySessions.filter { $0.state == .completed }.count, 1)
        XCTAssertEqual(later.state, .awaitingInput)
    }

    func testHookOnlyWaitingIsVisibleButCannotBeRepliedTo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appendingPathComponent("hook.jsonl"), session = UUID().uuidString, now = Date()
        try write([["hook_event_name": "PermissionRequest", "session_id": session, "received_at": now.timeIntervalSince1970]], to: hook)
        let scanner = LogScanner(source: "antigravity", root: directory.appendingPathComponent("missing"), hookURL: hook)
        let snapshot = await scanner.scan(now: now)
        let item = try XCTUnwrap(snapshot.antigravitySessions.first)
        XCTAssertEqual(snapshot.antigravitySessions.count, 1)
        XCTAssertEqual(item.state, .awaitingInput)
        XCTAssertNil(item.pendingIdentity)
        XCTAssertNil(item.actionDetail)
        XCTAssertFalse(item.id.contains(session))
    }

    func testHookAndTranscriptOfSameUUIDMergeWithoutCaseSensitivity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, now = Date(), file = transcript(root, id.lowercased())
        try write([question("One", date: now)], to: file)
        let hook = root.appendingPathComponent("hook.jsonl")
        try write([["hook_event_name": "PermissionRequest", "session_id": id.uppercased(), "received_at": now.timeIntervalSince1970]], to: hook)
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: hook)
        let snapshot = await scanner.scan(now: now)
        XCTAssertEqual(snapshot.antigravitySessions.count, 1)
        XCTAssertEqual(snapshot.antigravitySessions.first?.state, .awaitingInput)
        // The Hook reports a permission, which must not be confused with the
        // transcript question even though they share the same session ID.
        XCTAssertNil(snapshot.antigravitySessions.first?.pendingIdentity)
    }

    func testDuplicateTranscriptsForOneSessionAreNotReplyable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, now = Date()
        try write([question("One", date: now)], to: transcript(root, id, branch: "one"))
        try write([question("Two", date: now)], to: transcript(root, id, branch: "two"))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let snapshot = await scanner.scan(now: now)
        XCTAssertEqual(snapshot.antigravitySessions.count, 1)
        XCTAssertEqual(snapshot.antigravitySessions.first?.state, .awaitingInput)
        XCTAssertNil(snapshot.antigravitySessions.first?.pendingIdentity)
    }

    func testOldCompletedSessionAndWaitingArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), old = now.addingTimeInterval(-3600)
        try write([["type": "PLANNER_RESPONSE", "status": "DONE", "timestamp": ISO8601DateFormatter().string(from: old), "content": "done"]], to: transcript(root, UUID().uuidString))
        try write([question("Waiting", date: old)], to: transcript(root, UUID().uuidString))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let snapshot = await scanner.scan(now: now)
        XCTAssertEqual(snapshot.antigravitySessions.count, 2)
        XCTAssertEqual(snapshot.antigravitySessions.filter { $0.state == .awaitingInput }.count, 1)
        XCTAssertEqual(snapshot.antigravitySessions.filter { $0.state == .completed }.count, 1)
    }

    func testRepeatedQuestionKeepsIdentityButAnsweredAndReaskedQuestionGetsNewIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), file = transcript(root, UUID().uuidString)
        var event = question("Same", date: now)
        var call = try XCTUnwrap((event["tool_calls"] as? [[String: Any]])?.first)
        call["id"] = "stable-request"
        event["tool_calls"] = [call]
        try write([event], to: file)
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let initialSnapshot = await scanner.scan(now: now)
        let initial = try XCTUnwrap(initialSnapshot.antigravitySessions.first?.pendingIdentity)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
        let repeatedSnapshot = await scanner.scan(now: now.addingTimeInterval(1))
        let repeated = try XCTUnwrap(repeatedSnapshot.antigravitySessions.first?.pendingIdentity)
        XCTAssertEqual(initial, repeated)
        for record: [String: Any] in [
            ["type": "GENERIC", "status": "DONE"],
            ["type": "PLANNER_RESPONSE", "status": "DONE", "content": "done"],
            event
        ] {
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        }
        try handle.close()
        let nextSnapshot = await scanner.scan(now: now.addingTimeInterval(2))
        let next = try XCTUnwrap(nextSnapshot.antigravitySessions.first?.pendingIdentity)
        XCTAssertNotEqual(initial, next)
        try write([event], to: file)
        let replacedSnapshot = await scanner.scan(now: now.addingTimeInterval(3))
        let replaced = try XCTUnwrap(replacedSnapshot.antigravitySessions.first?.pendingIdentity)
        XCTAssertNotEqual(next, replaced)
    }

    func testNewAntigravitySessionIsDiscoveredOnNextTwoSecondRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let before = await scanner.scan(now: now)
        XCTAssertTrue(before.antigravitySessions.isEmpty)
        try write([question("New session", date: now)], to: standard(root, UUID().uuidString))   // where Antigravity writes them
        let after = await scanner.scan(now: now.addingTimeInterval(2.1))
        XCTAssertEqual(after.antigravitySessions.count, 1)
        XCTAssertEqual(after.antigravitySessions.first?.state, .awaitingInput)
    }

    // MARK: Finding transcripts without walking every file

    private func standard(_ root: URL, _ id: String) -> URL {
        LogScanner.antigravityTranscript(root: root, conversation: id)
    }

    func testANewConversationAtTheUsualPlaceIsFoundWithinSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try write([question("First", date: now)], to: standard(root, UUID().uuidString))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let before = await scanner.scan(now: now)
        XCTAssertEqual(before.antigravitySessions.count, 1)
        // Well inside the minute between full walks.
        try write([question("Second", date: now)], to: standard(root, UUID().uuidString))
        let after = await scanner.scan(now: now.addingTimeInterval(3))
        XCTAssertEqual(after.antigravitySessions.count, 2)
    }

    func testTheQuickLookDoesNotRereadATranscriptTheFullWalkFound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), id = UUID().uuidString
        try write([question("Only once", date: now)], to: standard(root, id))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let full = await scanner.scan(now: now)                          // full walk
        let quick = await scanner.scan(now: now.addingTimeInterval(3))   // quick look
        let fullAgain = await scanner.scan(now: now.addingTimeInterval(LogScanner.fullDiscoveryInterval + 4))
        // Read from the start again, the question would be a new request each
        // time and its identity (which a reply is checked against) would change.
        XCTAssertEqual(full.antigravitySessions.map(\.id), quick.antigravitySessions.map(\.id))
        XCTAssertNotNil(full.antigravityPendingIdentity)
        XCTAssertEqual(full.antigravityPendingIdentity, quick.antigravityPendingIdentity)
        XCTAssertEqual(full.antigravityPendingIdentity, fullAgain.antigravityPendingIdentity)
        XCTAssertEqual(quick.antigravityPendingSessions, 1)
    }

    func testATranscriptSomewhereElseIsStillFoundByTheFullWalkAndKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try write([question("Usual", date: now)], to: standard(root, UUID().uuidString))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        _ = await scanner.scan(now: now)
        let elsewhere = transcript(root, UUID().uuidString)   // not where Antigravity puts them today
        try write([question("Elsewhere", date: now)], to: elsewhere)
        let quick = await scanner.scan(now: now.addingTimeInterval(3))
        XCTAssertEqual(quick.antigravitySessions.count, 1, "the quick look only checks the usual place")
        let full = await scanner.scan(now: now.addingTimeInterval(LogScanner.fullDiscoveryInterval + 1))
        XCTAssertEqual(full.antigravitySessions.count, 2, "the full walk finds it")
        let kept = await scanner.scan(now: now.addingTimeInterval(LogScanner.fullDiscoveryInterval + 5))
        XCTAssertEqual(kept.antigravitySessions.count, 2, "and the next quick look does not drop it")
        try FileManager.default.removeItem(at: elsewhere)
        let gone = await scanner.scan(now: now.addingTimeInterval(LogScanner.fullDiscoveryInterval + 9))
        XCTAssertEqual(gone.antigravitySessions.count, 1, "a deleted one goes at once")
    }
}
