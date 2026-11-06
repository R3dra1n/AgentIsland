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

    // A trajectory holds every step ever taken, so long conversations are far
    // larger than the old 4 MiB limit (a real one reached 56 MB). The parser
    // must still find the single waiting step in one, and must still refuse a
    // payload above the shared cap rather than parse without bound.
    func testParsesATrajectoryAboveTheOldLimitAndRefusesOneAboveTheCap() throws {
        let filler = String(repeating: "x", count: 1024)
        var steps: [[String: Any]] = (0..<6000).map { _ in ["status": "CORTEX_STEP_STATUS_DONE", "pad": filler] }
        let index = steps.count
        steps.append(["status": "CORTEX_STEP_STATUS_WAITING",
                      "requestedInteraction": ["askQuestion": ["questions": [["question": "Choose", "options": [["id": "one", "text": "First"]]]]]],
                      "someMetadata": ["trajectoryId": trajectory.uuidString, "stepIndex": index]])
        let data = try JSONSerialization.data(withJSONObject: ["trajectory": ["trajectoryId": trajectory.uuidString, "steps": steps]])
        XCTAssertGreaterThan(data.count, 4 * 1024 * 1024, "夹具必须大于旧的 4 MiB 上限才有意义")
        XCTAssertLessThan(data.count, PinnedLoopbackHTTP.maximumResponse)

        let question = try AntigravityInteractionParser.parse(data, cascadeID: cascade)
        XCTAssertEqual(question.stepIndex, index)
        XCTAssertEqual(question.question, "Choose")

        // The cap is a hard boundary: one byte over is refused before any parsing.
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(
            Data(count: PinnedLoopbackHTTP.maximumResponse + 1), cascadeID: cascade))
    }
}
