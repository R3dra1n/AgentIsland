import XCTest
import CryptoKit
@testable import AgentIsland

final class CodexRegressionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 20000)

    func activity(_ state: AIState, second: Double?, session: String = "s") -> CodexLiveActivity {
        .init(sessionID: session, turnID: "turn-\(second ?? 0)", state: state,
              startedAt: second.map { now.addingTimeInterval($0) })
    }

    func testNewestTurnResultWinsRegardlessOfHistoricalSeverity() {
        let oldFailure = activity(.failed, second: 1, session: "old")
        let newCompletion = activity(.completed, second: 2, session: "new")
        for values in [[oldFailure, newCompletion], [newCompletion, oldFailure]] {
            XCTAssertEqual(CodexObserver.aggregateLiveStates(values)?.state, .completed)
            XCTAssertEqual(CodexObserver.aggregateLiveStates(values)?.sessionID, "new")
        }
        XCTAssertEqual(CodexObserver.aggregateLiveStates([
            activity(.completed, second: 1), activity(.failed, second: 2)])?.state, .failed)
        XCTAssertEqual(CodexObserver.aggregateLiveStates([
            activity(.interrupted, second: 1), activity(.completed, second: 2)])?.state, .completed)
    }

    func testActiveWorkStillWinsAndUndatedFailureDoesNotMaskNewCompletion() {
        XCTAssertEqual(CodexObserver.aggregateLiveStates([
            activity(.running, second: 1), activity(.completed, second: 2)])?.state, .running)
        XCTAssertEqual(CodexObserver.aggregateLiveStates([
            activity(.running, second: 2), activity(.awaitingInput, second: 1)])?.state, .awaitingInput)
        XCTAssertEqual(CodexObserver.aggregateLiveStates([
            activity(.failed, second: nil), activity(.completed, second: 2)])?.state, .completed)
        XCTAssertNil(CodexObserver.aggregateLiveStates([activity(.unknown, second: 3)]))
    }

    func testUnreachableActiveSessionIsNotHiddenByAnotherSessionsCompletion() {
        let otherCompletion = activity(.completed, second: 2, session: "other")
        let activeFallback: [String: AIState] = ["active": .running]
        XCTAssertEqual(CodexObserver.aggregateLiveAndFallback([otherCompletion], fallback: activeFallback)?.state, .running)
        XCTAssertEqual(CodexObserver.aggregateLiveAndFallback([otherCompletion], fallback: ["active": .awaitingInput])?.state, .awaitingInput)
        XCTAssertEqual(CodexObserver.aggregateLiveAndFallback([otherCompletion, activity(.unknown, second: 3, session: "active")], fallback: activeFallback)?.state, .running)
        let ownCompletion = activity(.completed, second: 3, session: "active")
        XCTAssertEqual(CodexObserver.aggregateLiveAndFallback([otherCompletion, ownCompletion], fallback: activeFallback)?.state, .completed)
    }

    func testQueuedAsyncQuestionSurvivesEmptyDesktopRequestListUntilLogResolvesIt() {
        let queued = CodexPendingRequest(sessionID: "a", turnID: "t", requestID: "q", isQuestion: true,
            context: "synthetic question", isAsynchronous: true)
        let other = CodexPendingRequest(sessionID: "b", turnID: "t", requestID: "other", isQuestion: true, context: nil)
        let merged = CodexObserver.mergeRequests([queued, other], live: [], session: "a")
        XCTAssertEqual(merged, [other, queued])
        // When the log observes the answer, the next scan no longer includes
        // the queued request, so an empty desktop list can clear it normally.
        XCTAssertEqual(CodexObserver.mergeRequests([other], live: [], session: "a"), [other])
        var liveQuestion = CodexPendingRequest(sessionID: "a", turnID: nil, requestID: "q", isQuestion: true, context: nil)
        liveQuestion.desktopMethod = "item/tool/requestUserInput"
        let liveMerged = CodexObserver.mergeRequests([queued], live: [liveQuestion], session: "a")
        XCTAssertEqual(liveMerged.count, 1)
        XCTAssertTrue(liveMerged[0].isAsynchronous)
        XCTAssertEqual(liveMerged[0].desktopMethod, "item/tool/requestUserInput")
    }

    func testScannerReportsActiveCodexSessionForIPCFailureFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, now = Date()
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id]],
            ["payload": ["type": "task_started", "turn_id": "current"]]
        ]
        var data = Data()
        for event in events { data.append(try JSONSerialization.data(withJSONObject: event)); data.append(10) }
        try data.write(to: root.appendingPathComponent("test.jsonl"))
        let scanner = LogScanner(source: "codex", root: root, hookURL: root.appendingPathComponent("no-hooks"))
        _ = await scanner.scan(now: now)
        let active = await scanner.activeCodexSessionStates(now: now)
        XCTAssertEqual(active[id], .running)
    }

    func hook(_ event: String, tool: String = "", id: String = "q", turn: String = "t", second: Double = 0) -> [String: Any] {
        ["hook_event_name": event, "session_id": "s", "turn_id": turn,
         "tool_name": tool, "tool_use_id": id, "received_at": now.timeIntervalSince1970 + second]
    }

    func call(_ name: String, id: String = "q") -> [String: Any] {
        ["type": "response_item", "payload": ["type": "function_call", "name": name, "call_id": id]]
    }

    func testAsyncHookReturnAndUnrelatedToolsKeepWaiting() {
        var store = HookStateStore()
        store.consume(hook("UserPromptSubmit"))
        store.consume(hook("PreToolUse", tool: "request_user_input_async"))
        store.consume(hook("PostToolUse", tool: "request_user_input_async"))
        store.consume(hook("PreToolUse", tool: "read_file", id: "other"))
        store.consume(hook("PostToolUse", tool: "read_file", id: "other"))
        XCTAssertEqual(store.states(now: now.addingTimeInterval(3600)).max(), .awaitingInput)
    }

    func testSynchronousHookReturnResolvesOnlyItsQuestion() {
        var store = HookStateStore()
        store.consume(hook("PreToolUse", tool: "request_user_input"))
        store.consume(hook("PermissionRequest", tool: "exec_command", id: "permission"))
        store.consume(hook("PostToolUse", tool: "request_user_input"))
        let owner = HookStateStore.Owner(session: "s", agent: "main")
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["permission"])
        XCTAssertEqual(store.states(now: now).max(), .awaitingInput)
        store.consume(hook("PostToolUse", tool: "exec_command", id: "permission"))
        XCTAssertEqual(store.states(now: now).max(), .running)
    }

    func testSameTurnInputClearsSingleQuestionButNotPermission() {
        var store = HookStateStore()
        store.consume(hook("UserPromptSubmit"))
        store.consume(hook("PreToolUse", tool: "request_user_input_async", second: 1))
        store.consume(hook("PermissionRequest", tool: "exec_command", id: "permission", second: 2))
        store.consume(hook("UserPromptSubmit", second: 3))
        let owner = HookStateStore.Owner(session: "s", agent: "main")
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["permission"])
        XCTAssertEqual(store.states(now: now).max(), .awaitingInput)
    }

    func testAmbiguousReplyDoesNotClearMultipleQuestions() {
        var store = HookStateStore()
        store.consume(hook("UserPromptSubmit"))
        for id in ["q1", "q2"] { store.consume(hook("PreToolUse", tool: "request_user_input_async", id: id)) }
        store.consume(hook("UserPromptSubmit", second: 1))
        let owner = HookStateStore.Owner(session: "s", agent: "main")
        XCTAssertEqual(store.owners[owner]?.pendingRequests.count, 2)
        var reply = hook("UserPromptSubmit", second: 2)
        reply["request_id"] = "q1"
        store.consume(reply)
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["q2"])
    }

    func testOldTurnReplyCannotClearNewQuestion() {
        var store = HookStateStore()
        store.consume(hook("UserPromptSubmit", turn: "old"))
        store.consume(hook("UserPromptSubmit", turn: "new", second: 1))
        store.consume(hook("PreToolUse", tool: "request_user_input_async", turn: "new", second: 2))
        store.consume(hook("UserPromptSubmit", turn: "old", second: 3))
        XCTAssertEqual(store.states(now: now).max(), .awaitingInput)
    }

    func testLogAsyncReturnKeepsQuestionUntilSameTurnUserText() {
        var value = SessionState()
        value.consume(["payload": ["type": "task_started", "turn_id": "t"]], source: "codex", date: now)
        value.consume(call("request_user_input_async"), source: "codex", date: now)
        value.consume(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "q", "output": "{\"accepted\":true}"]], source: "codex", date: now)
        value.consume(call("read_file", id: "other"), source: "codex", date: now)
        XCTAssertEqual(value.visibleState(now: now.addingTimeInterval(3600)), .awaitingInput)
        value.consume(["type": "response_item", "payload": ["type": "message", "role": "user", "internal_chat_message_metadata_passthrough": ["turn_id": "t", "content_item_kinds": ["user.text"]]]], source: "codex", date: now.addingTimeInterval(1))
        XCTAssertEqual(value.state, .running)
        XCTAssertTrue(value.asyncRequests.isEmpty)
    }

    func testCompletedCodexTurnKeepsAsyncQuestionUntilExplicitReply() {
        var value = SessionState()
        value.consume(["payload": ["type": "task_started", "turn_id": "t"]], source: "codex", date: now)
        value.consume(call("request_user_input_async", id: "call_123"), source: "codex", date: now.addingTimeInterval(1))
        value.consume(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "call_123"]], source: "codex", date: now.addingTimeInterval(2))
        value.consume(["payload": ["type": "task_complete", "turn_id": "t"]], source: "codex", date: now.addingTimeInterval(3))
        XCTAssertEqual(value.visibleState(now: now.addingTimeInterval(3600)), .awaitingInput)
        XCTAssertEqual(value.asyncRequests, ["call_123"])
        value.consume(["payload": ["type": "task_started", "turn_id": "next"]], source: "codex", date: now.addingTimeInterval(4))
        XCTAssertEqual(value.state, .awaitingInput)
        value.consume(["type": "response_item", "payload": ["type": "message", "role": "user",
            "internal_chat_message_metadata_passthrough": ["turn_id": "next", "content_item_kinds": ["user.text"]],
            "content": [["type": "input_text", "text": "<send_user_message_question_reply>call_123</send_user_message_question_reply>"]]]], source: "codex", date: now.addingTimeInterval(5))
        XCTAssertTrue(value.asyncRequests.isEmpty)
        XCTAssertEqual(value.state, .running)
    }

    func testCodexStopPreservesAsyncQuestionButAntigravityStopIsUnchanged() {
        var codex = HookStateStore()
        codex.consume(hook("UserPromptSubmit"), source: "codex")
        codex.consume(hook("PreToolUse", tool: "request_user_input_async", second: 1), source: "codex")
        codex.consume(hook("Stop", second: 2), source: "codex")
        XCTAssertEqual(codex.states(now: now.addingTimeInterval(3600)).max(), .awaitingInput)
        codex.consume(hook("UserPromptSubmit", second: 3), source: "codex")
        XCTAssertEqual(codex.states(now: now.addingTimeInterval(3)).max(), .running)

        var antigravity = HookStateStore()
        antigravity.consume(hook("UserPromptSubmit"), source: "antigravity")
        antigravity.consume(hook("PreToolUse", tool: "request_user_input_async", second: 1), source: "antigravity")
        antigravity.consume(hook("Stop", second: 2), source: "antigravity")
        XCTAssertEqual(antigravity.states(now: now.addingTimeInterval(2)).max(), .completed)
    }

    func testNewCodexTurnKeepsUnansweredQuestionsAndResolvesOnlyMatchingID() {
        var store = HookStateStore()
        store.consume(hook("UserPromptSubmit", turn: "old"), source: "codex")
        store.consume(hook("PreToolUse", tool: "request_user_input_async", id: "q1", turn: "old", second: 1), source: "codex")
        store.consume(hook("PreToolUse", tool: "request_user_input_async", id: "q2", turn: "old", second: 2), source: "codex")
        store.consume(hook("Stop", turn: "old", second: 3), source: "codex")
        store.consume(hook("UserPromptSubmit", turn: "new", second: 4), source: "codex")
        let owner = HookStateStore.Owner(session: "s", agent: "main")
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["q1", "q2"])
        store.reconcileResolvedAsync(session: "different", ids: ["q1"], date: now.addingTimeInterval(5))
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["q1", "q2"])
        store.reconcileResolvedAsync(session: "s", ids: ["q1"], date: now.addingTimeInterval(5))
        XCTAssertEqual(store.owners[owner]?.pendingRequests, ["q2"])
        XCTAssertEqual(store.states(now: now.addingTimeInterval(5)).max(), .awaitingInput)
        store.reconcileResolvedAsync(session: "s", ids: ["q2"], date: now.addingTimeInterval(6))
        XCTAssertEqual(store.states(now: now.addingTimeInterval(6)).max(), .running)
    }

    func testExplicitOldTurnResolutionOnlyClearsItsOutstandingQuestion() {
        var value = SessionState()
        value.consume(["payload": ["type": "task_started", "turn_id": "old"]], source: "codex", date: now)
        value.consume(call("request_user_input_async", id: "old-question"), source: "codex", date: now)
        value.consume(["payload": ["type": "task_started", "turn_id": "new"]], source: "codex", date: now)
        value.consume(call("request_user_input_async", id: "new-question"), source: "codex", date: now)
        value.consume(["payload": ["type": "request_resolved", "turn_id": "old", "request_id": "old-question"]], source: "codex", date: now)
        XCTAssertEqual(value.pendingRequests, ["new-question"])
        XCTAssertEqual(value.resolvedAsyncRequestIDs, ["old-question"])
        XCTAssertEqual(value.state, .awaitingInput)
    }

    func testScannerReconcilesExplicitAsyncAnswerAcrossHookAndLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bytes(_ events: [[String: Any]]) throws -> Data {
            var data = Data()
            for event in events { data.append(try JSONSerialization.data(withJSONObject: event)); data.append(10) }
            return data
        }
        let logURL = root.appendingPathComponent("session.jsonl")
        let hookURL = root.appendingPathComponent("hooks")
        let before: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "s"]],
            ["payload": ["type": "task_started", "turn_id": "old"]],
            call("request_user_input_async", id: "call_123"),
            ["payload": ["type": "task_complete", "turn_id": "old"]],
            ["payload": ["type": "task_started", "turn_id": "new"]]
        ]
        try bytes(before).write(to: logURL)
        try bytes([hook("UserPromptSubmit", turn: "old"),
                   hook("PreToolUse", tool: "request_user_input_async", id: "call_123", turn: "old", second: 1),
                   hook("Stop", turn: "old", second: 2),
                   hook("UserPromptSubmit", turn: "new", second: 3)]).write(to: hookURL)
        let scanner = LogScanner(source: "codex", root: root, hookURL: hookURL)
        let waiting = await scanner.scan(now: now.addingTimeInterval(4))
        XCTAssertEqual(waiting.state, .awaitingInput)
        XCTAssertEqual(waiting.codexRequests.map(\.requestID), ["call_123"])
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes([["payload": ["type": "request_resolved", "turn_id": "old", "request_id": "call_123"]]]))
        try handle.close()
        let answered = await scanner.scan(now: now.addingTimeInterval(5))
        XCTAssertTrue(answered.codexRequests.isEmpty)
        XCTAssertEqual(answered.state, .running)
    }

    func testEnvironmentMetadataIsNotAnAnswer() {
        var value = SessionState()
        value.consume(call("request_user_input_async"), source: "codex", date: now)
        value.consume(["type": "response_item", "payload": ["type": "message", "role": "user", "internal_chat_message_metadata_passthrough": ["content_item_kinds": ["environments.environment_context"]]]], source: "codex", date: now)
        XCTAssertEqual(value.state, .awaitingInput)
    }

    func testScannerDoesNotResurrectAnsweredHookQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "s"]], call("request_user_input_async")
        ]
        func bytes(_ events: [[String: Any]]) throws -> Data {
            var result = Data()
            for event in events { result.append(try JSONSerialization.data(withJSONObject: event)); result.append(10) }
            return result
        }
        try bytes(logs).write(to: root.appendingPathComponent("session.jsonl"))
        let hookURL = root.appendingPathComponent("hooks")
        try bytes([hook("UserPromptSubmit"), hook("PreToolUse", tool: "request_user_input_async", second: 1), hook("UserPromptSubmit", second: 2)]).write(to: hookURL)
        let scanner = LogScanner(source: "codex", root: root, hookURL: hookURL)
        let result = await scanner.scan(now: now.addingTimeInterval(3))
        XCTAssertEqual(result.state, .running)
        XCTAssertTrue(result.codexRequests.isEmpty)
    }

    func testCommandMatchingRejectsTextAndPersistentGrants() {
        XCTAssertTrue(CodexActionMatch.isDecisionButton(role: "AXButton", label: "Allow once", enabled: true, approve: true))
        XCTAssertTrue(CodexActionMatch.isDecisionButton(role: "AXButton", label: "允许一次 ⌘↵", enabled: true, approve: true))
        XCTAssertFalse(CodexActionMatch.isDecisionButton(role: "AXStaticText", label: "Allow", enabled: true, approve: true))
        XCTAssertFalse(CodexActionMatch.isDecisionButton(role: "AXButton", label: "Always allow", enabled: true, approve: true))
        XCTAssertFalse(CodexActionMatch.isDecisionButton(role: "AXButton", label: "Run tests in background", enabled: true, approve: true))
        XCTAssertFalse(CodexActionMatch.isDecisionButton(role: "AXButton", label: "Allow", enabled: false, approve: true))
        XCTAssertFalse(CodexActionMatch.isDecisionButton(role: "AXButton", label: "Submit", enabled: true, approve: true))
    }

    func testCommandDigestMustMatchExactDisplayedCommand() {
        let command = "echo hello"
        let digest = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
        let request = CodexPendingRequest(sessionID: "s", turnID: "t", requestID: "r", isQuestion: false, context: nil, commandDigest: digest)
        XCTAssertTrue(CodexActionMatch.matchesRequest(request, texts: ["echo hello", "Allow once"]))
        XCTAssertFalse(CodexActionMatch.matchesRequest(request, texts: ["echo other", "Allow once"]))
        XCTAssertFalse(CodexActionMatch.matchesRequest(request, texts: ["echo hello; rm file"]))
        XCTAssertFalse(CodexActionMatch.matchesRequest(request, texts: ["ECHO hello"]))
        XCTAssertFalse(CodexActionMatch.matchesRequest(request, texts: ["echo  hello"]))
    }
    func testLiveCandidatesIncludeRunningSessionWithoutQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        let entries: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": sessionID]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t"]]
        ]
        let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let scanner = LogScanner(source: "codex", root: root, hookURL: root.appendingPathComponent("absent"))
        let snapshot = await scanner.scan()
        XCTAssertTrue(snapshot.codexRequests.isEmpty)
        let ids = await scanner.recentCodexSessionIDs()
        XCTAssertEqual(ids, [sessionID])
    }

}
