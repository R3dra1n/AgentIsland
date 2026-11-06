import Foundation
import CryptoKit

/// The local server schema is private and version-dependent. Reject any state
/// that cannot be tied to exactly one unanswered question and trajectory step.
struct AntigravityQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable { let id: String; let text: String }
    let cascadeID: UUID
    let trajectoryID: UUID
    let stepIndex: Int
    let question: String
    let options: [Option]
    let stepFingerprint: Data

    enum Answer: Equatable, Sendable { case text(String), option(String) }

    func matchesDisplayedDetail(_ detail: String) -> Bool {
        // A line inside a question or option that resembles a fresh numbered
        // choice could be mistaken for another UI control. Do not route such a
        // detail, even when the underlying text happens to match exactly.
        func hasAmbiguousLine(_ text: String) -> Bool {
            text.components(separatedBy: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("❓") { return true }
                for (open, close) in [("[", "]"), ("［", "］"), ("【", "】"), ("(", ")"), ("（", "）")] {
                    guard trimmed.hasPrefix(open), let end = trimmed.range(of: close, range: trimmed.index(trimmed.startIndex, offsetBy: open.count)..<trimmed.endIndex) else { continue }
                    let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
                    let number = trimmed[start..<end.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !number.isEmpty && number.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
                }
                let prefix = trimmed.prefix { $0.isNumber }
                guard !prefix.isEmpty else { return false }
                let suffix = trimmed.dropFirst(prefix.count)
                return suffix.first.map { ".、)）".contains($0) } ?? false
            }
        }
        guard !hasAmbiguousLine(question), options.allSatisfy({ !hasAmbiguousLine($0.text) }) else { return false }
        let displayed = ["❓ \(question)"] + options.enumerated().map { "   [\($0.offset + 1)] \($0.element.text)" }
        return detail == displayed.joined(separator: "\n")
    }

    func response(_ answer: Answer) throws -> Data {
        var entry: [String: Any] = ["question": question]
        switch answer {
        case .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 16_384 else { throw AntigravityInteractionError.invalid }
            entry["writeInResponse"] = value
        case .option(let id):
            guard options.contains(where: { $0.id == id }) else { throw AntigravityInteractionError.invalid }
            entry["selectedOptionIds"] = [id]
        }
        let payload: [String: Any] = ["cascadeId": cascadeID.uuidString.lowercased(), "interaction": [
            "trajectoryId": trajectoryID.uuidString.lowercased(), "stepIndex": stepIndex,
            "askQuestion": ["responses": [entry]]
        ]]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

enum AntigravityInteractionError: Error {
    case invalid
    /// The trajectory was read and understood, and no step is waiting. That is
    /// a different fact from a structure that cannot be trusted: the question
    /// is simply not pending any more.
    case noWaitingQuestion
}

enum AntigravityInteractionParser {
    static func parse(_ data: Data, cascadeID: UUID) throws -> AntigravityQuestion {
        guard data.count <= PinnedLoopbackHTTP.maximumResponse,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trajectory = root["trajectory"] as? [String: Any],
              let id = trajectory["trajectoryId"] as? String, let trajectoryID = UUID(uuidString: id),
              let steps = trajectory["steps"] as? [[String: Any]], steps.count <= 100_000 else { throw AntigravityInteractionError.invalid }
        let waiting = steps.enumerated().filter { _, step in
            step["status"] as? String == "CORTEX_STEP_STATUS_WAITING" && step["requestedInteraction"] is [String: Any]
        }
        guard !waiting.isEmpty else { throw AntigravityInteractionError.noWaitingQuestion }
        guard waiting.count == 1 else { throw AntigravityInteractionError.invalid }
        let (index, step) = waiting[0]
        func emptyOrAbsent(_ value: Any?) -> Bool {
            guard let value else { return true }
            guard let list = value as? [Any] else { return false }
            return list.isEmpty
        }
        func falseOrAbsent(_ value: Any?) -> Bool {
            guard let value else { return true }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return !number.boolValue
        }
        guard let requested = step["requestedInteraction"] as? [String: Any], Set(requested.keys) == ["askQuestion"],
              let spec = requested["askQuestion"] as? [String: Any],
              let questions = spec["questions"] as? [[String: Any]], questions.count == 1,
              let question = questions[0]["question"] as? String, !question.isEmpty, question.utf8.count <= 16_384,
              falseOrAbsent(questions[0]["isMultiSelect"]), falseOrAbsent(questions[0]["skipped"]),
              (questions[0]["writeInResponse"] == nil || questions[0]["writeInResponse"] as? String == ""),
              emptyOrAbsent(questions[0]["selectedOptionIds"]), emptyOrAbsent(step["completedInteractions"]),
              falseOrAbsent(step["timedOut"]) else { throw AntigravityInteractionError.invalid }
        var references: [(UUID, Int)] = []
        func collect(_ value: Any, depth: Int) {
            guard depth <= 8 else { return }
            if let object = value as? [String: Any] {
                if let raw = object["trajectoryId"] as? String, let id = UUID(uuidString: raw),
                   let value = object["stepIndex"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                   let number = object["stepIndex"] as? Int { references.append((id, number)) }
                for value in object.values { collect(value, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for value in array { collect(value, depth: depth + 1) }
            }
        }
        collect(step, depth: 0)
        guard references.count == 1, references[0].0 == trajectoryID, references[0].1 == index else { throw AntigravityInteractionError.invalid }
        guard questions[0]["options"] == nil || questions[0]["options"] is [[String: Any]] else { throw AntigravityInteractionError.invalid }
        let rawOptions = questions[0]["options"] as? [[String: Any]] ?? []
        guard rawOptions.count <= 9 else { throw AntigravityInteractionError.invalid }
        var options: [AntigravityQuestion.Option] = []
        for item in rawOptions {
            guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  let text = item["text"] as? String, !text.isEmpty, text.utf8.count <= 16_384,
                  !options.contains(where: { $0.id == id }) else { throw AntigravityInteractionError.invalid }
            options.append(.init(id: id, text: text))
        }
        let serialized = try JSONSerialization.data(withJSONObject: step, options: [.sortedKeys])
        return .init(cascadeID: cascadeID, trajectoryID: trajectoryID, stepIndex: index, question: question, options: options,
                     stepFingerprint: Data(SHA256.hash(data: serialized)))
    }
}
