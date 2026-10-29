import Foundation

/// Keeps validation and submission ordering testable without a running assistant.
enum AntigravityReplyWorkflow {
    enum Selection: Sendable { case text(String), option(Int) }

    static func run(cascade: UUID, detail: String, selection: Selection,
                    fetch: @Sendable () async throws -> Data,
                    stillCurrent: @Sendable () async -> Bool,
                    submit: @Sendable (Data) async throws -> Void) async throws -> Bool {
        let first = try AntigravityInteractionParser.parse(await fetch(), cascadeID: cascade)
        guard first.matchesDisplayedDetail(detail) else { return false }
        let answer: AntigravityQuestion.Answer
        switch selection {
        case .text(let value): answer = .text(value)
        case .option(let index):
            guard index > 0, index <= first.options.count else { return false }
            answer = .option(first.options[index - 1].id)
        }
        let payload = try first.response(answer)
        let second = try AntigravityInteractionParser.parse(await fetch(), cascadeID: cascade)
        guard first == second, await stillCurrent() else { return false }
        try Task.checkCancellation()
        try await submit(payload)
        return true
    }
}
