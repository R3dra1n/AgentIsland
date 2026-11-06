import XCTest
import Darwin
@testable import AgentIsland

final class CodexNativeBridgeTests: XCTestCase {
    func question(_ id: String = "call-real") -> [String: Any] {
        ["type": "agentMessage", "id": id, "delivery": "async", "questions": [["title": "选择？", "options": ["A", "B"]]]]
    }
    func state(_ items: [[String: Any]], status: String = "inProgress") -> [String: Any] {
        ["turnHistory": ["kind": "canonical", "history": ["entitiesByKey": ["turn:1": ["turnId": "turn:1", "turnStartedAtMs": 1000, "status": status, "items": items]]]]]
    }
    func command(_ request: [String: Any], answer: String = "B") -> [String: Any] {
        ["action": "reply", "sessionID": "thread", "requestID": request["requestID"]!, "answers": [request["requestID"] as! String: answer]]
    }
    func testAsyncQuestionIdentityAndUnrelatedActivity() throws {
        let values = try CodexNativeBridge.pending(state([question(), ["type": "commandExecution", "status": "completed"],
            ["type": "userMessage", "content": [["type": "text", "text": "Continue"]]],
            ["type": "agentMessage", "id": "notice", "delivery": "async", "text": "Working"]]))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0]["requestID"] as? String, "[\"request_user_input_async\",\"call-real\",0]")
        let questions = values[0]["questions"] as! [[String: Any]]
        XCTAssertEqual(questions[0]["options"] as? [String], ["A", "B"])
        var completed = state([question()], status: "completed")
        completed["threadRuntimeStatus"] = ["type": "idle"]
        let carried = try CodexNativeBridge.pending(completed)
        XCTAssertEqual(carried.count, 1)
        let (route, params) = try CodexNativeBridge.replyRequest(command(carried[0]), state: completed, thread: "thread")
        XCTAssertEqual(route, "thread-follower-start-turn")
        let start = params["turnStart"] as! [String: Any]
        let input = start["request"] as! [String: Any]
        XCTAssertEqual(input["threadId"] as? String, "thread")
        XCTAssertEqual(input["turnTrigger"] as? String, "send_user_message_async_question")
        XCTAssertTrue((((input["input"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("call-real"))
        completed["threadRuntimeStatus"] = ["type": "active"]
        XCTAssertThrowsError(try CodexNativeBridge.replyRequest(command(carried[0]), state: completed, thread: "thread"))
        XCTAssertTrue(try CodexNativeBridge.pending(state([question()], status: "failed")).isEmpty)
        XCTAssertTrue(try CodexNativeBridge.pending(state([question()], status: "interrupted")).isEmpty)
    }
    func testOnlyAcceptedIdentityMatchedReplyClearsQuestion() throws {
        let requests = try CodexNativeBridge.pending(state([question(), question("other")]))
        let id = requests[0]["requestID"] as! String
        let text = "<send_user_message_question_reply>" + String(decoding: try CodexNativeBridge.encode([["questionItemId": id, "answer": "A"]]), as: UTF8.self) + "</send_user_message_question_reply>"
        var reply: [String: Any] = ["type": "steeringUserMessage", "status": "pending", "input": [["type": "text", "text": text]]]
        XCTAssertEqual(try CodexNativeBridge.pending(state([question(), question("other"), reply])).count, 2)
        reply["status"] = "accepted"
        let remaining = try CodexNativeBridge.pending(state([question(), question("other"), reply]))
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue((remaining[0]["requestID"] as! String).contains("other"))
    }

    func testCompleteHistoryOnlyReconcilesKnownAnsweredOrFailedCalls() throws {
        let answeredID = "[\"request_user_input_async\",\"answered\",0]"
        let body = String(decoding: try CodexNativeBridge.encode([["questionItemId": answeredID, "question": "q", "answer": "ok"]]), as: UTF8.self)
        let response: [String: Any] = ["type": "userMessage", "content": [["type": "text", "text": "<send_user_message_question_reply>\(body)</send_user_message_question_reply>"]]]
        var snapshot: [String: Any] = ["turnHistory": ["kind": "canonical", "history": ["isComplete": true, "entitiesByKey": [
            "a": ["turnId": "a", "status": "completed", "items": [question("answered"), question("waiting"), response]],
            "b": ["turnId": "b", "status": "failed", "items": [question("failed")]]
        ]]]]
        let pending = try CodexNativeBridge.pending(snapshot)
        XCTAssertEqual(CodexNativeBridge.resolvedAsyncCalls(snapshot, pending: pending), ["answered", "failed"])
        snapshot["turnHistory"] = ["kind": "canonical", "history": ["isComplete": false, "entitiesByKey": [
            "a": ["turnId": "a", "status": "completed", "items": [question("answered"), response]]
        ]]]
        XCTAssertTrue(CodexNativeBridge.resolvedAsyncCalls(snapshot, pending: try CodexNativeBridge.pending(snapshot)).isEmpty)
    }

    func testOnlyOlderCompletedAsyncQuestionsBecomeHistorical() {
        func snapshot(complete: Bool, latestTime: Int) -> [String: Any] {
            ["turnHistory": ["kind": "canonical", "history": ["isComplete": complete, "entitiesByKey": [
                "old": ["turnId": "old", "turnStartedAtMs": 100, "status": "completed", "items": [question("old-call")]],
                "latest": ["turnId": "latest", "turnStartedAtMs": latestTime, "status": "completed", "items": [question("current-call")]],
                "active": ["turnId": "active", "turnStartedAtMs": 50, "status": "inProgress", "items": [question("active-call")]]
            ]]]]
        }
        XCTAssertEqual(CodexNativeBridge.historicalAsyncCalls(snapshot(complete: true, latestTime: 200)), ["old-call"])
        // A partial snapshot must behave identically: "a strictly newer turn
        // exists" cannot be falsified by turns that failed to load, and
        // requiring completeness here left historical questions on screen.
        XCTAssertEqual(CodexNativeBridge.historicalAsyncCalls(snapshot(complete: false, latestTime: 200)), ["old-call"])
        // Nothing is strictly older than the newest start time, so the tie
        // between "old" and "latest" hides neither, and the in-progress turn
        // is never historical.
        XCTAssertTrue(CodexNativeBridge.historicalAsyncCalls(snapshot(complete: true, latestTime: 100)).isEmpty)
    }
    func testAsyncResponseCarriesRestoreContextAndUnicode() throws {
        var snapshot = state([question()]); snapshot["cwd"] = "/tmp/example"
        let request = try XCTUnwrap(CodexNativeBridge.pending(snapshot).first)
        let (method, params) = try CodexNativeBridge.replyRequest(command(request, answer: "中文 / answer"), state: snapshot, thread: "thread")
        XCTAssertEqual(method, "thread-follower-steer-turn")
        let restore = params["restoreMessage"] as! [String: Any]
        XCTAssertEqual(restore["cwd"] as? String, "/tmp/example")
        XCTAssertEqual(restore["id"] as? String, params["clientUserMessageId"] as? String)
        let context = restore["context"] as! [String: Any]
        XCTAssertEqual((context["commentAttachments"] as? [String])?.count, 0)
        XCTAssertTrue((context["prompt"] as! String).contains("中文 / answer"))
        XCTAssertEqual(context["turnTrigger"] as? String, "send_user_message_async_question")
    }
    func testStaleAndEmptyAnswersRejectedBeforeSubmission() throws {
        let snapshot = state([question()])
        let request = try XCTUnwrap(CodexNativeBridge.pending(snapshot).first)
        XCTAssertThrowsError(try CodexNativeBridge.replyRequest(command(request, answer: " \n"), state: snapshot, thread: "thread"))
        XCTAssertThrowsError(try CodexNativeBridge.replyRequest(command(request), state: [:], thread: "thread"))
    }
    func testNumericApprovalIDsAndAllowedDecisionRoutes() throws {
        for (method, route) in [("item/commandExecution/requestApproval", "thread-follower-command-approval-decision"),
                                ("item/fileChange/requestApproval", "thread-follower-file-approval-decision")] {
            let snapshot: [String: Any] = ["requests": [["id": 42, "method": method, "params": ["command": "echo test"]]]]
            for decision in ["accept", "decline"] {
                let (actual, params) = try CodexNativeBridge.replyRequest(["requestID": "42", "decision": decision], state: snapshot, thread: "thread")
                XCTAssertEqual(actual, route)
                XCTAssertEqual(params["requestId"] as? Int, 42)
                XCTAssertEqual(params["decision"] as? String, decision)
            }
            XCTAssertThrowsError(try CodexNativeBridge.replyRequest(["requestID": "42", "decision": "acceptForSession"], state: snapshot, thread: "thread"))
        }
        let unsupported: [String: Any] = ["requests": [["id": 1, "method": "item/commandExecution/requestApproval", "params": ["availableDecisions": ["acceptForSession"]]]]]
        XCTAssertTrue(try CodexNativeBridge.pending(unsupported).isEmpty)
        let structuredOnly: [String: Any] = ["requests": [["id": 1, "method": "item/commandExecution/requestApproval", "params": ["availableDecisions": [["acceptForSession": true]]]]]]
        XCTAssertTrue(try CodexNativeBridge.pending(structuredOnly).isEmpty)
    }
    func testSynchronousMultiQuestionRequiresAllAnswers() throws {
        let snapshot: [String: Any] = ["requests": [["id": 7, "method": "item/tool/requestUserInput", "params": ["questions": [
            ["id": "one", "question": "One", "options": [["label": "A"]]], ["id": "two", "question": "Two"]]]]]]
        XCTAssertThrowsError(try CodexNativeBridge.replyRequest(["requestID": "7", "answers": ["one": "A"]], state: snapshot, thread: "thread"))
        let (method, params) = try CodexNativeBridge.replyRequest(["requestID": "7", "answers": ["one": "A", "two": "free text"]], state: snapshot, thread: "thread")
        XCTAssertEqual(method, "thread-follower-submit-user-input")
        let answers = (params["response"] as! [String: Any])["answers"] as! [String: [String: [String]]]
        XCTAssertEqual(answers["two"]?["answers"], ["free text"])
    }
    func testMalformedQuestionCannotBecomeAnApproval() throws {
        let snapshot: [String: Any] = ["requests": [["id": 1, "method": "item/tool/requestUserInput", "params": ["questions": [["unexpected": "field"]]]]]]
        XCTAssertTrue(try CodexNativeBridge.pending(snapshot).isEmpty)
    }
    func testLatestTurnAndRuntimeCompatibility() {
        var snapshot: [String: Any] = ["threadRuntimeStatus": ["type": "idle"], "turns": [
            ["turnId": "new", "turnStartedAtMs": 2000, "status": "completed"],
            ["turnId": "old", "turnStartedAtMs": 1000, "status": "failed"]]]
        XCTAssertEqual(CodexNativeBridge.executionState(snapshot), "completed")
        XCTAssertEqual(CodexNativeBridge.latestTurn(snapshot)["turnId"] as? String, "new")
        snapshot["turns"] = Array((snapshot["turns"] as! [[String: Any]]).reversed())
        XCTAssertEqual(CodexNativeBridge.latestTurn(snapshot)["turnId"] as? String, "new")
        snapshot["threadRuntimeStatus"] = ["type": "active"]
        XCTAssertEqual(CodexNativeBridge.executionState(snapshot), "running")
        snapshot["threadRuntimeStatus"] = ["type": "notLoaded"]
        XCTAssertEqual(CodexNativeBridge.executionState(snapshot), "unknown")
    }
    func testLatestActiveTurnWinsOverTransientIdleRuntime() {
        let snapshot: [String: Any] = ["threadRuntimeStatus": ["type": "idle"], "turns": [
            ["turnId": "old", "turnStartedAtMs": 1, "status": "completed"],
            ["turnId": "current", "turnStartedAtMs": 2, "status": "inProgress"]
        ]]
        XCTAssertEqual(CodexNativeBridge.executionState(snapshot), "running")
    }
    func sockets() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (fds[0], fds[1])
    }
    func testFragmentedFrameAndEOF() throws {
        let (left, right) = try sockets()
        let transport = try CodexIPCTransport(connectedSocket: left)
        let body = try CodexNativeBridge.encode(["message": "拆包🙂"])
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(body)
        let bytes = Array(frame)
        let done = expectation(description: "fragment writer")
        DispatchQueue.global().async {
            defer { Darwin.close(right); done.fulfill() }
            for var byte in bytes { _ = Darwin.send(right, &byte, 1, 0) }
        }
        XCTAssertEqual(try transport.receive()["message"] as? String, "拆包🙂")
        XCTAssertThrowsError(try transport.receive())
        wait(for: [done], timeout: 2)
    }
    func testOversizedFrameAndMissingReplyAreBounded() throws {
        do {
            let (left, right) = try sockets(); defer { Darwin.close(right) }
            let transport = try CodexIPCTransport(connectedSocket: left)
            var header = UInt32(CodexIPCTransport.maximumFrame + 1).littleEndian
            _ = Darwin.send(right, &header, 4, 0)
            XCTAssertThrowsError(try transport.receive())
        }
        let (left, right) = try sockets(); defer { Darwin.close(right) }
        let transport = try CodexIPCTransport(connectedSocket: left, timeout: 0.03)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try transport.receive())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
    func testNonSocketRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try CodexIPCTransport(path: file.path))
    }
    func testDisconnectedPeerCannotCrashSenderWithSIGPIPE() throws {
        let (left, right) = try sockets()
        let transport = try CodexIPCTransport(connectedSocket: left)
        Darwin.close(right)
        XCTAssertThrowsError(try transport.send(["test": true]))
    }
    func testHandshakeDiscoveryAndOwnerRoutedReply() throws {
        let (left, right) = try sockets()
        let done = expectation(description: "mock desktop")
        let snapshot = try CodexNativeBridge.encode(state([question()]))
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let server = try CodexIPCTransport(connectedSocket: right)
                let hello = try server.receive()
                XCTAssertEqual(hello["method"] as? String, "initialize")
                XCTAssertEqual(hello["version"] as? Int, 0)
                try server.send(["type": "response", "requestId": hello["requestId"]!, "resultType": "success", "result": ["clientId": "client"]])
                XCTAssertEqual(try server.receive()["method"] as? String, "thread-stream-following-changed")
                try server.send(["type": "client-discovery-request", "requestId": "discover"])
                let discovery = try server.receive()
                XCTAssertEqual((discovery["response"] as? [String: Bool])?["canHandle"], false)
                let parsed = try JSONSerialization.jsonObject(with: snapshot)
                try server.send(["method": "thread-stream-state-changed", "sourceClientId": "wrong-owner", "params": ["conversationId": "other-thread", "change": ["type": "snapshot", "conversationState": [:]]]])
                try server.send(["method": "thread-stream-state-changed", "sourceClientId": "owner", "params": ["conversationId": "thread", "hostId": "local", "change": ["type": "snapshot", "conversationState": parsed]]])
                let action = try server.receive()
                XCTAssertEqual(action["method"] as? String, "thread-follower-steer-turn")
                XCTAssertEqual(action["targetClientId"] as? String, "owner")
                XCTAssertEqual(action["version"] as? Int, 1)
                try server.send(["type": "response", "requestId": "unrelated", "resultType": "success"])
                try server.send(["type": "response", "requestId": action["requestId"]!, "resultType": "success", "result": [:]])
            } catch { XCTFail("Mock desktop: \(error)") }
        }
        let request = try XCTUnwrap(CodexNativeBridge.pending(state([question()])).first)
        let transport = try CodexIPCTransport(connectedSocket: left)
        let result = try CodexNativeBridge.run(CodexNativeBridge.encode(command(request)), transport: transport)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: result) as? [String: Any])?["ok"] as? Bool, true)
        wait(for: [done], timeout: 3)
    }

    func testCompletedTurnReplyUsesVersionTwoStartRoute() throws {
        let (left, right) = try sockets()
        let done = expectation(description: "mock completed desktop turn")
        var snapshot = state([question()], status: "completed")
        snapshot["threadRuntimeStatus"] = ["type": "idle"]
        let encodedSnapshot = try CodexNativeBridge.encode(snapshot)
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let server = try CodexIPCTransport(connectedSocket: right)
                let hello = try server.receive()
                try server.send(["type": "response", "requestId": hello["requestId"]!, "resultType": "success", "result": ["clientId": "client"]])
                _ = try server.receive() // follow notification
                let parsed = try JSONSerialization.jsonObject(with: encodedSnapshot)
                try server.send(["method": "thread-stream-state-changed", "sourceClientId": "owner", "params": ["conversationId": "thread", "hostId": "local", "change": ["type": "snapshot", "conversationState": parsed]]])
                let action = try server.receive()
                XCTAssertEqual(action["method"] as? String, "thread-follower-start-turn")
                XCTAssertEqual(action["version"] as? Int, 2)
                XCTAssertEqual(action["targetClientId"] as? String, "owner")
                try server.send(["type": "response", "requestId": action["requestId"]!, "resultType": "success", "result": [:]])
            } catch { XCTFail("Mock desktop: \(error)") }
        }
        let request = try XCTUnwrap(CodexNativeBridge.pending(snapshot).first)
        let transport = try CodexIPCTransport(connectedSocket: left)
        let result = try CodexNativeBridge.run(CodexNativeBridge.encode(command(request)), transport: transport)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: result) as? [String: Any])?["ok"] as? Bool, true)
        wait(for: [done], timeout: 3)
    }

    func testLoadingFullHistoryReconcilesFailedCallWithoutSendingReply() throws {
        let (left, right) = try sockets()
        let done = expectation(description: "mock full history")
        let partial: [String: Any] = ["turnHistory": ["kind": "canonical", "history": ["isComplete": false, "entitiesByKey": [:]]]]
        let full: [String: Any] = ["threadRuntimeStatus": ["type": "idle"], "turnHistory": ["kind": "canonical", "history": ["isComplete": true, "entitiesByKey": [
            "old": ["turnId": "old", "status": "failed", "items": [question("old-call")]]
        ]]]]
        let partialData = try CodexNativeBridge.encode(partial), fullData = try CodexNativeBridge.encode(full)
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let server = try CodexIPCTransport(connectedSocket: right)
                let hello = try server.receive()
                try server.send(["type": "response", "requestId": hello["requestId"]!, "resultType": "success", "result": ["clientId": "client"]])
                _ = try server.receive()
                let partialState = try JSONSerialization.jsonObject(with: partialData)
                try server.send(["method": "thread-stream-state-changed", "sourceClientId": "owner", "params": ["conversationId": "thread", "hostId": "local", "change": ["type": "snapshot", "conversationState": partialState]]])
                let request = try server.receive()
                XCTAssertEqual(request["method"] as? String, "thread-follower-load-complete-history")
                let fullState = try JSONSerialization.jsonObject(with: fullData)
                try server.send(["method": "thread-stream-state-changed", "sourceClientId": "owner", "params": ["conversationId": "thread", "hostId": "local", "change": ["type": "snapshot", "conversationState": fullState]]])
                try server.send(["type": "response", "requestId": request["requestId"]!, "resultType": "success", "result": [:]])
            } catch { XCTFail("Mock desktop: \(error)") }
        }
        let result = try CodexNativeBridge.run(CodexNativeBridge.encode(["sessionID": "thread", "loadCompleteHistory": true]), transport: CodexIPCTransport(connectedSocket: left))
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(reply["resolvedAsyncCallIDs"] as? [String], ["old-call"])
        XCTAssertTrue((reply["requests"] as? [[String: Any]] ?? []).isEmpty)
        wait(for: [done], timeout: 3)
    }
}
