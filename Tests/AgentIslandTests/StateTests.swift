import XCTest
@testable import AgentIsland

final class StateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10000)

    func testQuietRunningAndUnknownRecordsNeverComplete() {
        var state = SessionState()
        state.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "one"]], source: "codex", date: now)
        state.consume(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "exec_command"]], source: "codex", date: now)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(200)), .running)
        state.consume(["type": "new_unrecognized_event"], source: "codex", date: now)
        XCTAssertEqual(state.state, .running)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(3601)), .idle)
    }

    func testOldCompletionCannotEndNewTurn() {
        var state = SessionState()
        for turn in ["one", "two"] {
            state.consume(["payload": ["type": "task_started", "turn_id": turn]], source: "codex", date: now)
        }
        state.consume(["payload": ["type": "task_complete", "turn_id": "one"]], source: "codex", date: now)
        XCTAssertEqual(state.state, .running)
        state.consume(["payload": ["type": "task_complete", "turn_id": "two"]], source: "codex", date: now)
        XCTAssertEqual(state.visibleState(now: now), .completed)
        // Completion persists until acknowledged by the UI; it is not a timeout.
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(11)), .completed)
    }

    func testMultiplePendingRequests() {
        var state = SessionState()
        for id in ["a", "b"] {
            state.consume(["payload": ["type": "approval_requested", "request_id": id]], source: "codex", date: now)
        }
        state.consume(["payload": ["type": "approval_resolved", "request_id": "a"]], source: "codex", date: now)
        XCTAssertEqual(state.state, .awaitingInput)
        state.consume(["payload": ["type": "approval_resolved", "request_id": "b"]], source: "codex", date: now)
        XCTAssertEqual(state.state, .running)
    }

    func testAntigravityModelResponseCompletion() {
        var state = SessionState()
        // GENERIC is background metadata, not the beginning of a user turn.
        state.consume(["type": "USER_INPUT"], source: "antigravity", date: now)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(30)), .running)
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE"], source: "antigravity", date: now)
        XCTAssertEqual(state.state, .completed)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(4), source: "antigravity"), .completed)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(600), source: "antigravity"), .completed)
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(6), source: "codex"), .completed)
    }

    func testAntigravityBackgroundMetadataDoesNotStartATurn() {
        var state = SessionState()
        state.consume(["type": "GENERIC", "status": "RUNNING"], source: "antigravity", date: now)
        XCTAssertEqual(state.visibleState(now: now), .idle)
    }

    func testAntigravityApprovalCommandDetection() {
        var state = SessionState()
        state.consume([
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "tool_calls": [["name": "run_command", "args": ["CommandLine": "killall AgentIsland"]]]
        ], source: "antigravity", date: now)
        XCTAssertEqual(state.state, .awaitingInput)
        XCTAssertTrue(state.pendingActionDetail?.contains("请在 Antigravity 中核对实际审批选项") == true)
        XCTAssertFalse(state.pendingActionDetail?.contains("永远允许") == true)
        state.consume(["type": "GENERIC", "status": "DONE"], source: "antigravity", date: now)
        XCTAssertEqual(state.state, .running)
    }

    func testAntigravityQuestionSurvivesBackgroundRecordsUntilUserAnswers() {
        var state = SessionState()
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE",
            "tool_calls": [["name": "functions.ask_question", "args": ["questions": [["question": "Choose", "options": ["A", "B"]]]]]]],
            source: "antigravity", date: now)
        XCTAssertEqual(state.state, .awaitingInput)
        for kind in ["GENERIC", "PLANNER_RESPONSE"] {
            state.consume(["type": kind, "status": "DONE"], source: "antigravity", date: now.addingTimeInterval(1))
            XCTAssertEqual(state.state, .awaitingInput)
        }
        XCTAssertEqual(state.visibleState(now: now.addingTimeInterval(3600)), .awaitingInput)
        state.consume(["type": "USER_INPUT"], source: "antigravity", date: now.addingTimeInterval(3601))
        XCTAssertEqual(state.state, .running)
        XCTAssertTrue(state.inputRequests.isEmpty)
    }

    func testAntigravityCompletedAnswerRequiresResultAndAssistantResponse() {
        var state = SessionState()
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE",
            "tool_calls": [["name": "ask_question", "args": ["questions": [["question": "Choose", "options": ["A", "B"]]]]]]],
            source: "antigravity", date: now)
        state.consume(["type": "GENERIC", "status": "DONE"], source: "antigravity", date: now.addingTimeInterval(1))
        XCTAssertEqual(state.state, .awaitingInput)
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE", "content": "Response after tool result"], source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertEqual(state.state, .completed)
        XCTAssertTrue(state.inputRequests.isEmpty)
    }

    func testAntigravityAnswerFollowedByToolReturnsToRunning() {
        var state = SessionState()
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE",
            "tool_calls": [["name": "ask_question", "args": ["questions": [["question": "Choose", "options": ["A"]]]]]]],
            source: "antigravity", date: now)
        state.consume(["type": "GENERIC", "status": "DONE"], source: "antigravity", date: now.addingTimeInterval(1))
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE",
            "tool_calls": [["name": "view_file", "args": [:]]]], source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertEqual(state.state, .running)
        XCTAssertTrue(state.inputRequests.isEmpty)
    }

    func testAntigravitySimultaneousQuestionsDoNotCollapseWithoutIDs() {
        var state = SessionState()
        let question: [String: Any] = ["name": "ask_question", "args": ["questions": [["question": "Choose"]]]]
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [question, question]], source: "antigravity", date: now)
        XCTAssertEqual(state.inputRequests.count, 2)
        state.consume(["type": "GENERIC", "status": "DONE"], source: "antigravity", date: now.addingTimeInterval(1))
        state.consume(["type": "PLANNER_RESPONSE", "status": "DONE", "content": "Continued"], source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertEqual(state.state, .awaitingInput)
    }

    func testHookTasksAndOldTurnEvents() {
        var hooks = HookStateStore()
        func event(_ name: String, _ session: String, _ turn: String = "one", _ agent: String = "main") -> [String: Any] {
            ["hook_event_name": name, "session_id": session, "turn_id": turn, "agent_id": agent, "received_at": now.timeIntervalSince1970]
        }
        hooks.consume(event("UserPromptSubmit", "a"))
        hooks.consume(event("PermissionRequest", "a"))
        hooks.consume(event("UserPromptSubmit", "b"))
        hooks.consume(event("Stop", "b"))
        XCTAssertEqual(hooks.states(now: now).max(), .awaitingInput)
        hooks.consume(event("UserPromptSubmit", "a", "two"))
        hooks.consume(event("Stop", "a", "one"))
        XCTAssertEqual(hooks.states(now: now).max(), .running)
        hooks.consume(event("SubagentStart", "a", "two", "child"))
        hooks.consume(event("Stop", "a", "two"))
        XCTAssertEqual(hooks.states(now: now).max(), .running)
        hooks.consume(event("SubagentStop", "a", "two", "child"))
        XCTAssertEqual(hooks.states(now: now).max(), .completed)
        hooks.consume(event("SessionEnd", "a", "two"))
        XCTAssertFalse(hooks.owners.keys.contains { $0.session == "a" })
    }

    func testAntigravityStopRequiresNoBackgroundTasksAndNoError() {
        var hooks = HookStateStore()
        var event: [String: Any] = ["hook_event_name": "Stop", "session_id": "a", "received_at": now.timeIntervalSince1970, "fully_idle": false, "termination_reason": "model_stop"]
        hooks.consume(event)
        XCTAssertEqual(hooks.states(now: now).max(), .running)
        event["fully_idle"] = true
        event["termination_reason"] = "error"
        hooks.consume(event)
        XCTAssertEqual(hooks.states(now: now).max(), .failed)
        event["termination_reason"] = "model_stop"
        hooks.consume(event)
        XCTAssertEqual(hooks.states(now: now).max(), .completed)
    }

    func testAsyncAndSynchronousQuestionsHaveDifferentResolution() {
        for asynchronous in [false, true] {
            var state = SessionState()
            state.consume(["type": "response_item", "payload": ["type": "function_call", "name": asynchronous ? "request_user_input_async" : "request_user_input", "call_id": "q"]], source: "codex", date: now)
            XCTAssertEqual(state.state, .awaitingInput)
            state.consume(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "q"]], source: "codex", date: now)
            XCTAssertEqual(state.state, asynchronous ? .awaitingInput : .running)
        }
    }

    func testHookOverridesLogForSameSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"same\"}}\n{\"payload\":{\"type\":\"task_started\"}}\n"
        try Data(log.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let hook = root.appendingPathComponent("hook-events")
        let event: [String: Any] = ["hook_event_name": "Stop", "session_id": "same", "turn_id": "one", "received_at": Date().timeIntervalSince1970]
        var bytes = try JSONSerialization.data(withJSONObject: event); bytes.append(10)
        try bytes.write(to: hook)
        let scanner = LogScanner(source: "codex", root: root, hookURL: hook)
        let snapshot = await scanner.scan()
        XCTAssertEqual(snapshot.state, .completed)
    }

    func testPartialUTF8AndTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let line = Data("{\"type\":\"你好\"}\n".utf8)
        let split = line.count - 5
        try line.prefix(split).write(to: url)
        var reader = JSONLReader()
        var count = 0
        _ = try reader.read(url) { _ in count += 1 }
        XCTAssertEqual(count, 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: line.suffix(from: split)); try handle.close()
        _ = try reader.read(url) { json in count += 1; XCTAssertEqual(json["type"] as? String, "你好") }
        XCTAssertEqual(count, 1)
        _ = try reader.read(url) { _ in count += 1 }
        XCTAssertEqual(count, 1)
        try Data("{}\n".utf8).write(to: url)
        _ = try reader.read(url) { _ in count += 1 }
        XCTAssertEqual(count, 2)
    }

    func testScannerAggregatesFilesAndUsesExplicitCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"payload\":{\"type\":\"approval_requested\",\"request_id\":\"a\"}}\n".utf8).write(to: root.appendingPathComponent("a.jsonl"))
        try Data("{\"payload\":{\"type\":\"task_complete\"}}\n".utf8).write(to: root.appendingPathComponent("b.jsonl"))
        let scanner = LogScanner(source: "codex", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let first = await scanner.scan()
        XCTAssertEqual(first.state, .awaitingInput)
        let second = await scanner.scan(now: Date().addingTimeInterval(200))
        XCTAssertEqual(second.state, .awaitingInput)
    }

    func testAntigravityScannerChangesIdentityForIdenticalQuestionInAnotherSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstFolder = root.appendingPathComponent("first")
        let secondFolder = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let event = Data("{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{\"questions\":[{\"question\":\"Choose\",\"options\":[\"A\"]}]}}]}\n".utf8)
        try event.write(to: firstFolder.appendingPathComponent("transcript.jsonl"))
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let now = Date()
        let first = await scanner.scan(now: now)
        XCTAssertEqual(first.antigravityPendingSessions, 1)
        XCTAssertNotNil(first.antigravityPendingIdentity)
        try FileManager.default.removeItem(at: firstFolder)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try event.write(to: secondFolder.appendingPathComponent("transcript.jsonl"))
        let second = await scanner.scan(now: now.addingTimeInterval(6))
        XCTAssertEqual(second.antigravityPendingSessions, 1)
        XCTAssertEqual(first.actionDetail, second.actionDetail)
        XCTAssertNotEqual(first.antigravityPendingIdentity, second.antigravityPendingIdentity)
    }

    func testAntigravityScannerDoesNotEnableNumericReplyForMultipleQuestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = ["question": "First", "options": ["A"]] as [String: Any]
        let two = ["question": "Second", "options": ["B"]] as [String: Any]
        let cases: [[[String: Any]]] = [
            [["name": "ask_question", "args": ["questions": [one, two]]]],
            [["name": "ask_question", "args": ["questions": [one]]],
             ["name": "ask_question", "args": ["questions": [two]]]],
            [["name": "ask_question", "args": ["questions": [one]]], ["name": "run_command", "args": [:]]]
        ]
        for (index, calls) in cases.enumerated() {
            let folder = root.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let event: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": calls]
            let data = try JSONSerialization.data(withJSONObject: event) + Data([10])
            try data.write(to: folder.appendingPathComponent("transcript.jsonl"))
            let scanner = LogScanner(source: "antigravity", root: folder, hookURL: folder.appendingPathComponent("no-hooks"))
            let snapshot = await scanner.scan()
            XCTAssertEqual(snapshot.antigravityPendingSessions, 1)
            XCTAssertNil(snapshot.antigravityPendingIdentity)
        }
    }

    func testAntigravityHookOnlyWaitingSessionDoesNotChangeTargetedQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = UUID().uuidString
        let folder = root.appendingPathComponent(session).appendingPathComponent("one").appendingPathComponent("two")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let event: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [
            ["name": "ask_question", "args": ["questions": [["question": "Choose", "options": ["A"]]]]]
        ]]
        try (JSONSerialization.data(withJSONObject: event) + Data([10])).write(to: folder.appendingPathComponent("transcript.jsonl"))
        let hook = root.appendingPathComponent("hook.jsonl")
        let hookEvent: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": UUID().uuidString,
                                        "received_at": Date().timeIntervalSince1970]
        try (JSONSerialization.data(withJSONObject: hookEvent) + Data([10])).write(to: hook)
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: hook)
        let snapshot = await scanner.scan()
        XCTAssertEqual(snapshot.antigravityPendingSessions, 2)
        XCTAssertEqual(snapshot.antigravityPendingIdentity?.transcript.resolvingSymlinksInPath(), folder.appendingPathComponent("transcript.jsonl").resolvingSymlinksInPath())
    }

    func testAntigravitySelectsOnlyUniquelyDisplayedQuestionAcrossSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        func writeQuestion(_ name: String, _ date: Date) throws -> URL {
            let dir = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("one").appendingPathComponent("two")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let event: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "timestamp": formatter.string(from: date),
                "tool_calls": [["name": "ask_question", "args": ["questions": [["question": name, "options": ["A"]]]]]]]
            let url = dir.appendingPathComponent("transcript.jsonl")
            try (JSONSerialization.data(withJSONObject: event) + Data([10])).write(to: url)
            return url
        }
        _ = try writeQuestion("Older", now.addingTimeInterval(-10))
        let selected = try writeQuestion("Newest", now)
        let scanner = LogScanner(source: "antigravity", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let unique = await scanner.scan(now: now)
        XCTAssertEqual(unique.antigravityPendingSessions, 2)
        XCTAssertEqual(unique.antigravityPendingIdentity?.transcript.resolvingSymlinksInPath(), selected.resolvingSymlinksInPath())
        XCTAssertTrue(unique.actionDetail?.contains("Newest") == true)
        _ = try writeQuestion("Newest", now.addingTimeInterval(1))
        let ambiguous = await scanner.scan(now: now.addingTimeInterval(6))
        XCTAssertEqual(ambiguous.antigravityPendingSessions, 3)
        XCTAssertNil(ambiguous.antigravityPendingIdentity)
    }

    func testScannerRebuildsStateAfterTransientReadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.jsonl")
        try Data("{\"payload\":{\"type\":\"approval_requested\",\"request_id\":\"a\"}}\n".utf8).write(to: file)
        let scanner = LogScanner(source: "codex", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        let first = await scanner.scan()
        XCTAssertEqual(first.state, .awaitingInput)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let failed = await scanner.scan()
        XCTAssertNotEqual(failed.state, .awaitingInput)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recovered = await scanner.scan()
        XCTAssertEqual(recovered.state, .awaitingInput)
    }
}
