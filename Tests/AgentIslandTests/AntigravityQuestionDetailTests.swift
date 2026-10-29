import XCTest
@testable import AgentIsland

final class AntigravityQuestionDetailTests: XCTestCase {
    private func question(_ text: String, _ options: [String]) -> AntigravityQuestion {
        AntigravityQuestion(cascadeID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                            trajectoryID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                            stepIndex: 1, question: text,
                            options: options.enumerated().map { .init(id: "option-\($0.offset)", text: $0.element) },
                            stepFingerprint: Data())
    }

    private func display(_ text: String, _ options: [String]) -> String {
        (["❓ \(text)"] + options.enumerated().map { "   [\($0.offset + 1)] \($0.element)" }).joined(separator: "\n")
    }

    func testExactMultilineQuestionAndOptionsAreAccepted() {
        let text = "Which outcome?\nThe second line contains context."
        let options = ["First choice\nAdditional explanation", "Second choice\nMore detail"]
        let item = question(text, options)
        let expected = display(text, options)
        XCTAssertTrue(item.matchesDisplayedDetail(expected))
        XCTAssertFalse(item.matchesDisplayedDetail(expected + "\n"))
        XCTAssertFalse(item.matchesDisplayedDetail(expected.replacingOccurrences(of: "Additional explanation", with: "Additional  explanation")))
        XCTAssertFalse(item.matchesDisplayedDetail(display(text, options.reversed())))
        XCTAssertFalse(item.matchesDisplayedDetail(display(text, Array(options.prefix(1)))))
    }

    func testQuestionContainingOptionLikeLineIsRejectedEvenForExactDisplay() {
        for line in ["   [1] A misleading choice", "[ 2 ] Misleading", "［２］ full width", "【3】 heading", "(4) alternative", "5. alternative", "6) alternative", "7、alternative"] {
            let text = "Which outcome?\n" + line
            let options = ["First", "Second"]
            XCTAssertFalse(question(text, options).matchesDisplayedDetail(display(text, options)), line)
        }
    }

    func testOptionContainingOptionLikeLineIsRejectedEvenForExactDisplay() {
        for line in ["   [2] Impersonated choice", "[2] Impersonated", "２. Impersonated", "（3） Impersonated"] {
            let options = ["First\n" + line, "Second"]
            XCTAssertFalse(question("Choose", options).matchesDisplayedDetail(display("Choose", options)), line)
        }
    }

    func testNestedQuestionHeaderIsRejected() {
        let text = "First question\n❓ Another question"
        XCTAssertFalse(question(text, ["First"]).matchesDisplayedDetail(display(text, ["First"])))
        let options = ["First\n ❓ Another question"]
        XCTAssertFalse(question("Choose", options).matchesDisplayedDetail(display("Choose", options)))
    }

    func testOrdinaryInlineReferencesAndMultilineWithoutChoicesRemainValid() {
        let text = "Explain list[1] and item 2.\nKeep the reference inline."
        let options = ["Use option [1] here\nOne more line"]
        XCTAssertTrue(question(text, options).matchesDisplayedDetail(display(text, options)))
        XCTAssertTrue(question("Free text question\nPlease explain.", []).matchesDisplayedDetail("❓ Free text question\nPlease explain."))
    }
}
