import XCTest
@testable import AgentIsland

/// Every endpoint is simulated; these tests never access assistant sessions.
final class AntigravityReplyWorkflowTests: XCTestCase {
    private let cascade = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let trajectory = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let detail = "❓ Choose\n   [1] First\n   [2] Second"

    private enum SimulatedFailure: Error { case fetch, submit }

    private actor Service {
        private var responses: [Data]
        private var failFetchAt: Int?
        private var failSubmit: Bool
        private(set) var fetchCount = 0
        private(set) var sent: [Data] = []

        init(_ responses: [Data], failFetchAt: Int? = nil, failSubmit: Bool = false) {
            self.responses = responses
            self.failFetchAt = failFetchAt
            self.failSubmit = failSubmit
        }

        func fetch() throws -> Data {
            fetchCount += 1
            if fetchCount == failFetchAt { throw SimulatedFailure.fetch }
            guard !responses.isEmpty else { throw SimulatedFailure.fetch }
            return responses.removeFirst()
        }

        func submit(_ data: Data) throws {
            sent.append(data)
            if failSubmit { throw SimulatedFailure.submit }
        }
    }

    private actor CancellationGate {
        private var isEntered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var blocked: CheckedContinuation<Bool, Never>?

        func waitUntilEntered() async {
            if isEntered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func pauseBeforeSubmission() async -> Bool {
            await withCheckedContinuation { continuation in
                blocked = continuation
                isEntered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }

        func release() {
            blocked?.resume(returning: true)
            blocked = nil
        }
    }

    private func fixture(question: String = "Choose", optionText: String = "First",
                         questionCount: Int = 1, generation: Int = 1) throws -> Data {
        let q: [String: Any] = ["question": question, "options": [
            ["id": "option-1", "text": optionText], ["id": "option-2", "text": "Second"]
        ]]
        let step: [String: Any] = [
            "status": "CORTEX_STEP_STATUS_WAITING",
            "requestedInteraction": ["askQuestion": ["questions": Array(repeating: q, count: questionCount)]],
            "metadata": ["stepGenerationVersion": generation],
            "stepRef": ["trajectoryId": trajectory.uuidString, "stepIndex": 1]
        ]
        return try JSONSerialization.data(withJSONObject: ["trajectory": ["trajectoryId": trajectory.uuidString,
            "steps": [["status": "CORTEX_STEP_STATUS_DONE"], step]]])
    }

    func testTextIsSubmittedExactlyOnceAfterTwoMatchingReads() async throws {
        let data = try fixture()
        let service = Service([data, data])
        let result = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("你好"),
            fetch: { try await service.fetch() }, stillCurrent: { true }, submit: { try await service.submit($0) })
        let sent = await service.sent
        let fetchCount = await service.fetchCount
        XCTAssertTrue(result)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(sent.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
        let interaction = try XCTUnwrap(payload["interaction"] as? [String: Any])
        let ask = try XCTUnwrap(interaction["askQuestion"] as? [String: Any])
        let answer = try XCTUnwrap((ask["responses"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["cascadeId"] as? String, cascade.uuidString.lowercased())
        XCTAssertEqual(interaction["stepIndex"] as? Int, 1)
        XCTAssertEqual(answer["writeInResponse"] as? String, "你好")
        XCTAssertNil(answer["selectedOptionIds"])
    }

    func testOptionMapsToServerIDAndSubmitsOnlyOnce() async throws {
        let data = try fixture()
        let service = Service([data, data])
        let result = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .option(2),
            fetch: { try await service.fetch() }, stillCurrent: { true }, submit: { try await service.submit($0) })
        let sent = await service.sent
        XCTAssertTrue(result)
        XCTAssertEqual(sent.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
        let interaction = try XCTUnwrap(payload["interaction"] as? [String: Any])
        let ask = try XCTUnwrap(interaction["askQuestion"] as? [String: Any])
        let answer = try XCTUnwrap((ask["responses"] as? [[String: Any]])?.first)
        XCTAssertEqual(answer["selectedOptionIds"] as? [String], ["option-2"])
        XCTAssertNil(answer["writeInResponse"])
    }

    func testChangedServerStepOrCurrentSessionNeverSubmits() async throws {
        let original = try fixture()
        let changed = try fixture(generation: 2)
        let changedServer = Service([original, changed])
        let serverResult = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
            fetch: { try await changedServer.fetch() }, stillCurrent: { true }, submit: { try await changedServer.submit($0) })
        let serverSent = await changedServer.sent
        XCTAssertFalse(serverResult)
        XCTAssertTrue(serverSent.isEmpty)

        let changedSession = Service([original, original])
        let sessionResult = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
            fetch: { try await changedSession.fetch() }, stillCurrent: { false }, submit: { try await changedSession.submit($0) })
        let sessionSent = await changedSession.sent
        XCTAssertFalse(sessionResult)
        XCTAssertTrue(sessionSent.isEmpty)
    }

    func testMultipleQuestionsAndChangedDisplayNeverSubmit() async throws {
        let multiple = Service([try fixture(questionCount: 2)])
        do {
            _ = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
                fetch: { try await multiple.fetch() }, stillCurrent: { true }, submit: { try await multiple.submit($0) })
            XCTFail("Multiple questions must not be accepted")
        } catch {}
        let multipleSent = await multiple.sent
        XCTAssertTrue(multipleSent.isEmpty)

        let mismatch = Service([try fixture(optionText: "Changed")])
        let result = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .option(1),
            fetch: { try await mismatch.fetch() }, stillCurrent: { true }, submit: { try await mismatch.submit($0) })
        let mismatchSent = await mismatch.sent
        let fetchCount = await mismatch.fetchCount
        XCTAssertFalse(result)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertTrue(mismatchSent.isEmpty)
    }

    func testFetchAndSubmitErrorsAreNotRetried() async throws {
        let original = try fixture()
        let failedFetch = Service([original], failFetchAt: 2)
        do {
            _ = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
                fetch: { try await failedFetch.fetch() }, stillCurrent: { true }, submit: { try await failedFetch.submit($0) })
            XCTFail("Fetch error must propagate")
        } catch SimulatedFailure.fetch {} catch { XCTFail("Unexpected error") }
        let fetchCount = await failedFetch.fetchCount
        let fetchSent = await failedFetch.sent
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(fetchSent.isEmpty)

        let failedSubmit = Service([original, original], failSubmit: true)
        do {
            _ = try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
                fetch: { try await failedSubmit.fetch() }, stillCurrent: { true }, submit: { try await failedSubmit.submit($0) })
            XCTFail("Submit error must propagate")
        } catch SimulatedFailure.submit {} catch { XCTFail("Unexpected error") }
        let submitCount = await failedSubmit.sent.count
        XCTAssertEqual(submitCount, 1)
    }

    func testCancellationBeforeSubmissionNeverSendsAnswer() async throws {
        let original = try fixture()
        let service = Service([original, original])
        let gate = CancellationGate()
        let cascade = self.cascade, detail = self.detail
        let operation = Task {
            try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: .text("answer"),
                fetch: { try await service.fetch() },
                stillCurrent: { await gate.pauseBeforeSubmission() },
                submit: { try await service.submit($0) })
        }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("Cancellation must stop the answer before submission")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        let fetchCount = await service.fetchCount
        let sent = await service.sent
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(sent.isEmpty)
    }
}
