import XCTest
@testable import AgentIsland

final class AntigravityInteractionTests: XCTestCase {
    private let cascade = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let trajectory = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func payload(question: [String: Any] = ["question": "Choose", "options": [["id": "one", "text": "First"]]],
                         extraRequest: [String: Any] = [:], completed: [Any] = [], reference: Any = 1,
                         otherWaiting: Bool = false) throws -> Data {
        var request = extraRequest
        request["askQuestion"] = ["questions": [question]]
        let step: [String: Any] = ["status": "CORTEX_STEP_STATUS_WAITING", "requestedInteraction": request,
                                   "completedInteractions": completed,
                                   "someMetadata": ["trajectoryId": trajectory.uuidString, "stepIndex": reference]]
        var steps: [[String: Any]] = [["status": "CORTEX_STEP_STATUS_DONE"], step]
        if otherWaiting { steps.append(step) }
        return try JSONSerialization.data(withJSONObject: ["trajectory": ["trajectoryId": trajectory.uuidString, "steps": steps]])
    }

    func testTextAndOptionRepliesUseSameObservedQuestionIdentity() throws {
        let question = try AntigravityInteractionParser.parse(payload(), cascadeID: cascade)
        XCTAssertTrue(question.matchesDisplayedDetail("❓ Choose\n   [1] First"))
        XCTAssertFalse(question.matchesDisplayedDetail("❓ Different\n   [1] First"))
        XCTAssertFalse(question.matchesDisplayedDetail("❓ Choose\n   [1] Different"))
        XCTAssertFalse(question.matchesDisplayedDetail("❓ Choose\n   [1] First\n   [2] Unexpected"))
        let textData = try question.response(.text("你好 AGENTISLAND_TEST"))
        let text = try XCTUnwrap(JSONSerialization.jsonObject(with: textData) as? [String: Any])
        let interaction = try XCTUnwrap(text["interaction"] as? [String: Any])
        let ask = try XCTUnwrap(interaction["askQuestion"] as? [String: Any])
        let response = try XCTUnwrap((ask["responses"] as? [[String: Any]])?.first)
        XCTAssertEqual(interaction["stepIndex"] as? Int, 1)
        XCTAssertEqual(response["writeInResponse"] as? String, "你好 AGENTISLAND_TEST")
        let optionData = try question.response(.option("one"))
        let option = try XCTUnwrap(JSONSerialization.jsonObject(with: optionData) as? [String: Any])
        let optionInteraction = try XCTUnwrap(option["interaction"] as? [String: Any])
        let optionAsk = try XCTUnwrap(optionInteraction["askQuestion"] as? [String: Any])
        XCTAssertEqual((optionAsk["responses"] as? [[String: Any]])?.first?["selectedOptionIds"] as? [String], ["one"])
        XCTAssertThrowsError(try question.response(.option("unknown")))
    }

    func testRejectsAmbiguousExpiredAndMalformedRequests() throws {
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(otherWaiting: true), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(extraRequest: ["permission": [:]]), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(completed: [[:]]), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(reference: true), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(reference: 2), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(question: ["question": "Choose", "isMultiSelect": true]), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(question: ["question": "Choose", "selectedOptionIds": "invalid"]), cascadeID: cascade))
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(payload(question: ["question": "Choose", "options": "invalid"]), cascadeID: cascade))
    }
}
