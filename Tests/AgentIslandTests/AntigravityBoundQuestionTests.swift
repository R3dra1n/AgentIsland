import Foundation
import XCTest
@testable import AgentIsland

/// Synthetic local-server responses only: no real assistant data or configuration.
final class AntigravityBoundQuestionTests: XCTestCase {
    private let cascadeA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let cascadeB = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let trajectoryA = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let trajectoryB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let detail = "❓ Choose\n   [1] First\n   [2] Second"

    private enum FixtureError: Error { case noResponse }

    private actor SimulatedServer {
        private var responses: [Data]
        private(set) var submitted: [Data] = []
        private(set) var fetchCount = 0

        init(_ responses: [Data]) { self.responses = responses }

        func fetch() throws -> Data {
            fetchCount += 1
            guard !responses.isEmpty else { throw FixtureError.noResponse }
            return responses.removeFirst()
        }

        func submit(_ payload: Data) { submitted.append(payload) }
    }

    private func fixture(trajectory: UUID, generation: Int = 1, stepIndex: Int = 1) throws -> Data {
        let question: [String: Any] = ["question": "Choose", "options": [
            ["id": "option-1", "text": "First"], ["id": "option-2", "text": "Second"]
        ]]
        let step: [String: Any] = [
            "status": "CORTEX_STEP_STATUS_WAITING",
            "requestedInteraction": ["askQuestion": ["questions": [question]]],
            "metadata": ["stepGenerationVersion": generation],
            "stepRef": ["trajectoryId": trajectory.uuidString, "stepIndex": stepIndex]
        ]
        let steps: [[String: Any]] = Array(repeating: ["status": "CORTEX_STEP_STATUS_DONE"], count: stepIndex) + [step]
        return try JSONSerialization.data(withJSONObject: ["trajectory": ["trajectoryId": trajectory.uuidString, "steps": steps]])
    }

    func testSameDisplayedQuestionWithNewGenerationIsRejectedBeforeSubmission() async throws {
        let initial = try fixture(trajectory: trajectoryA)
        let nextGeneration = try fixture(trajectory: trajectoryA, generation: 2)
        let expected = try AntigravityInteractionParser.parse(initial, cascadeID: cascadeA)
        let replacement = try AntigravityInteractionParser.parse(nextGeneration, cascadeID: cascadeA)
        XCTAssertTrue(expected.matchesDisplayedDetail(detail))
        XCTAssertTrue(replacement.matchesDisplayedDetail(detail))
        XCTAssertNotEqual(expected, replacement)

        let server = SimulatedServer([nextGeneration])
        let result = try await AntigravityReplyWorkflow.run(cascade: cascadeA, detail: detail,
            selection: .text("answer"), expectedQuestion: expected,
            fetch: { try await server.fetch() }, stillCurrent: { true }, submit: { await server.submit($0) })
        let submitted = await server.submitted
        let fetchCount = await server.fetchCount
        XCTAssertFalse(result)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertTrue(submitted.isEmpty)
    }

    func testSameDisplayedQuestionWithNewTrajectoryOrStepIsRejected() async throws {
        let initial = try fixture(trajectory: trajectoryA)
        let expected = try AntigravityInteractionParser.parse(initial, cascadeID: cascadeA)
        let replacements = [try fixture(trajectory: trajectoryB), try fixture(trajectory: trajectoryA, stepIndex: 2)]
        for data in replacements {
            let replacement = try AntigravityInteractionParser.parse(data, cascadeID: cascadeA)
            XCTAssertTrue(replacement.matchesDisplayedDetail(detail))
            XCTAssertNotEqual(expected, replacement)
            let server = SimulatedServer([data])
            let result = try await AntigravityReplyWorkflow.run(cascade: cascadeA, detail: detail,
                selection: .option(1), expectedQuestion: expected,
                fetch: { try await server.fetch() }, stillCurrent: { true }, submit: { await server.submit($0) })
            let submitted = await server.submitted
            XCTAssertFalse(result)
            XCTAssertTrue(submitted.isEmpty)
        }
    }

    func testIdenticalQuestionBoundToAnotherCascadeCannotBeSubmitted() async throws {
        let data = try fixture(trajectory: trajectoryA)
        let boundA = try AntigravityInteractionParser.parse(data, cascadeID: cascadeA)
        let boundB = try AntigravityInteractionParser.parse(data, cascadeID: cascadeB)
        XCTAssertTrue(boundA.matchesDisplayedDetail(detail))
        XCTAssertTrue(boundB.matchesDisplayedDetail(detail))
        XCTAssertNotEqual(boundA, boundB)

        let wrongSession = SimulatedServer([data])
        let wrongResult = try await AntigravityReplyWorkflow.run(cascade: cascadeB, detail: detail,
            selection: .option(2), expectedQuestion: boundA,
            fetch: { try await wrongSession.fetch() }, stillCurrent: { true }, submit: { await wrongSession.submit($0) })
        let wronglySubmitted = await wrongSession.submitted
        XCTAssertFalse(wrongResult)
        XCTAssertTrue(wronglySubmitted.isEmpty)

        let correctSession = SimulatedServer([data, data])
        let result = try await AntigravityReplyWorkflow.run(cascade: cascadeB, detail: detail,
            selection: .option(2), expectedQuestion: boundB,
            fetch: { try await correctSession.fetch() }, stillCurrent: { true }, submit: { await correctSession.submit($0) })
        let submitted = await correctSession.submitted
        XCTAssertTrue(result)
        XCTAssertEqual(submitted.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(submitted.first)) as? [String: Any])
        XCTAssertEqual(payload["cascadeId"] as? String, cascadeB.uuidString.lowercased())
        let interaction = try XCTUnwrap(payload["interaction"] as? [String: Any])
        let ask = try XCTUnwrap(interaction["askQuestion"] as? [String: Any])
        let response = try XCTUnwrap((ask["responses"] as? [[String: Any]])?.first)
        XCTAssertEqual(response["selectedOptionIds"] as? [String], ["option-2"])
    }
}
