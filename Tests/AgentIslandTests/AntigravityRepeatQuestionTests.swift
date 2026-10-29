import XCTest
@testable import AgentIsland

final class AntigravityRepeatQuestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 42_000)

    private func event(id: String?, question: String = "Choose", options: [String] = ["A", "B"], encoded: Bool = false) throws -> [String: Any] {
        let questions: [[String: Any]] = [["question": question, "options": options]]
        let value: Any = encoded ? String(data: try JSONSerialization.data(withJSONObject: questions), encoding: .utf8)! : questions
        var call: [String: Any] = ["name": "functions.ask_question", "args": ["questions": value]]
        if let id { call["id"] = id }
        return ["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [call]]
    }

    func testIdenticalExplicitIDRemainsUnambiguousAcrossEncodingAndStatus() throws {
        var state = SessionState()
        let first = try event(id: "request-1")
        state.consume(first, source: "antigravity", date: now)
        XCTAssertTrue(state.antigravityQuestionUnambiguous)
        var repeated = try event(id: "request-1", encoded: true)
        repeated["status"] = "RUNNING"
        state.consume(repeated, source: "antigravity", date: now.addingTimeInterval(1))
        XCTAssertTrue(state.antigravityQuestionUnambiguous)
        XCTAssertEqual(state.inputRequests, ["request-1"])
        XCTAssertEqual(state.state, .awaitingInput)
    }

    func testDifferentIDOrMissingIDCannotRegainEligibility() throws {
        var different = SessionState()
        let first = try event(id: "request-1")
        different.consume(first, source: "antigravity", date: now)
        different.consume(try event(id: "request-2"), source: "antigravity", date: now.addingTimeInterval(1))
        XCTAssertFalse(different.antigravityQuestionUnambiguous)
        different.consume(first, source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertFalse(different.antigravityQuestionUnambiguous)

        var absent = SessionState()
        let unknown = try event(id: nil)
        absent.consume(unknown, source: "antigravity", date: now)
        XCTAssertTrue(absent.antigravityQuestionUnambiguous)
        absent.consume(unknown, source: "antigravity", date: now.addingTimeInterval(1))
        XCTAssertFalse(absent.antigravityQuestionUnambiguous)
        absent.consume(unknown, source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertFalse(absent.antigravityQuestionUnambiguous)
    }

    func testChangedQuestionOrOptionsCannotRegainEligibility() throws {
        for changed in [try event(id: "request-1", question: "Different"), try event(id: "request-1", options: ["B", "A"])] {
            var state = SessionState()
            let first = try event(id: "request-1")
            state.consume(first, source: "antigravity", date: now)
            state.consume(changed, source: "antigravity", date: now.addingTimeInterval(1))
            XCTAssertFalse(state.antigravityQuestionUnambiguous)
            state.consume(first, source: "antigravity", date: now.addingTimeInterval(2))
            XCTAssertFalse(state.antigravityQuestionUnambiguous)
        }
    }

    func testRepeatedQuestionAfterResultRemainsIneligible() throws {
        var state = SessionState()
        let first = try event(id: "request-1")
        state.consume(first, source: "antigravity", date: now)
        state.consume(["type": "GENERIC", "status": "DONE"], source: "antigravity", date: now.addingTimeInterval(1))
        state.consume(first, source: "antigravity", date: now.addingTimeInterval(2))
        XCTAssertFalse(state.antigravityQuestionUnambiguous)
    }

    func testFailedOrCancelledRequestCannotRegainEligibilityOnRepeat() throws {
        for status in ["FAILED", "ERROR", "CANCELLED", "CANCELED"] {
            var state = SessionState()
            let question = try event(id: "request-1")
            state.consume(question, source: "antigravity", date: now)
            state.consume(["type": "GENERIC", "status": status], source: "antigravity", date: now.addingTimeInterval(1))
            state.consume(question, source: "antigravity", date: now.addingTimeInterval(2))
            XCTAssertFalse(state.antigravityQuestionUnambiguous)
        }
    }

    func testNewTurnCanStartFreshAfterPreviousAmbiguity() throws {
        var state = SessionState()
        let first = try event(id: nil)
        state.consume(first, source: "antigravity", date: now)
        state.consume(first, source: "antigravity", date: now.addingTimeInterval(1))
        XCTAssertFalse(state.antigravityQuestionUnambiguous)
        state.consume(["type": "USER_INPUT"], source: "antigravity", date: now.addingTimeInterval(2))
        state.consume(try event(id: "request-2"), source: "antigravity", date: now.addingTimeInterval(3))
        XCTAssertTrue(state.antigravityQuestionUnambiguous)
    }
}
