import Foundation

/// A reducer owns one session. Unrecognized records never imply completion.
struct SessionState: Sendable {
    var state: AIState = .unknown
    var turnID: String?
    var changedAt = Date.distantPast
    var pendingRequests: Set<String> = []
    var asyncRequests: Set<String> = []
    var inputRequests: Set<String> = []
    var antigravitySawInputResult = false
    var antigravityQuestionUnambiguous = false
    // Survives repeated observations of one pending question. Replaying or
    // replacing a transcript creates a fresh epoch, so old panels cannot
    // accidentally bind to a new, identical request.
    let antigravitySessionEpoch = UUID()
    var antigravityRequestGeneration: UInt64 = 0
    var antigravityRequestStartedAt: Date?
    private struct AntigravityQuestionIdentity: Equatable, Sendable {
        let requestID: String
        let question: String
        let options: [String]
    }
    private var antigravityQuestionIdentity: AntigravityQuestionIdentity?
    var commandDigests: [String: String] = [:]
    var requestContexts: [String: String] = [:]
    var seenTurns: Set<String> = []
    /// Rich context about the pending action (e.g. command to approve, question being asked)
    var pendingActionDetail: String?

    mutating func consume(_ json: [String: Any], source: String, date: Date) {
        let payload = json["payload"] as? [String: Any] ?? json
        let kind = payload["type"] as? String ?? ""
        let outer = json["type"] as? String ?? ""
        let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        let incomingTurn = payload["turn_id"] as? String ?? json["turn_id"] as? String ?? metadata?["turn_id"] as? String
        let starts = ["task_started", "turn_started"].contains(kind) || (source == "antigravity" && outer == "USER_INPUT")
        if starts {
            if let incomingTurn, seenTurns.contains(incomingTurn), incomingTurn != turnID { return }
            if let incomingTurn { seenTurns.insert(incomingTurn) }
            turnID = incomingTurn
            pendingRequests.removeAll()
            asyncRequests.removeAll()
            inputRequests.removeAll()
            antigravitySawInputResult = false
            antigravityQuestionUnambiguous = false
            antigravityQuestionIdentity = nil
            requestContexts.removeAll()
            commandDigests.removeAll()
            pendingActionDetail = nil
            transition(.running, date)
            return
        }
        if let incomingTurn, let turnID, incomingTurn != turnID { return }
        if ["task_complete", "turn_complete"].contains(kind) {
            clearRequests(); transition(.completed, date); return
        }
        if ["task_failed", "turn_failed"].contains(kind) {
            clearRequests(); transition(.failed, date); return
        }
        if ["turn_aborted", "task_interrupted", "turn_interrupted"].contains(kind) {
            clearRequests(); transition(.interrupted, date); return
        }
        if ["approval_requested", "confirm_action", "awaiting_input"].contains(kind) {
            pendingRequests.insert(payload["request_id"] as? String ?? "approval")
            transition(.awaitingInput, date); return
        }
        if kind == "approval_resolved", let id = payload["request_id"] as? String {
            resolveRequest(id)
            transition(pendingRequests.isEmpty ? .running : .awaitingInput, date); return
        }
        if source == "codex", ["request_resolved", "user_input_resolved"].contains(kind),
           let id = payload["request_id"] as? String {
            resolveRequest(id)
            transition(pendingRequests.isEmpty ? .running : .awaitingInput, date)
            return
        }
        if source == "codex" && outer == "response_item" {
            if kind == "message", payload["role"] as? String == "user" {
                let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
                let kinds = metadata?["content_item_kinds"] as? [String] ?? []
                if kinds.contains("user.text") {
                    var resolvedId = payload["request_id"] as? String
                    if resolvedId == nil, let content = payload["content"] as? [[String: Any]], let textObj = content.first(where: { ($0["type"] as? String) == "input_text" }), let text = textObj["text"] as? String {
                        if text.contains("<send_user_message_question_reply>"),
                           let range = text.range(of: "call_[a-zA-Z0-9]+", options: .regularExpression) {
                            resolvedId = String(text[range])
                        }
                    }
                    inputSubmitted(requestID: resolvedId)
                    if state == .awaitingInput { transition(pendingRequests.isEmpty ? .running : .awaitingInput, date) }
                }
                return
            }
            if ["function_call", "custom_tool_call"].contains(kind) {
                let name = payload["name"] as? String ?? ""
                if let id = payload["call_id"] as? String,
                   let raw = payload["arguments"] as? String,
                   let bytes = raw.data(using: .utf8),
                   let args = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    var contextStr: String? = nil
                    if let cmd = args["command"] as? String ?? args["cmd"] as? String {
                        contextStr = cmd
                    } else if let questions = args["questions"] as? [[String: Any]], let first = questions.first {
                        let qTitle = first["question"] as? String ?? first["title"] as? String ?? ""
                        if let options = first["options"] as? [String], !options.isEmpty {
                            var formatted = qTitle + "\n"
                            for (i, opt) in options.enumerated() {
                                formatted += "   [\(i + 1)] \(opt)\n"
                            }
                            contextStr = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            contextStr = qTitle
                        }
                    }
                    requestContexts[id] = contextStr.map { String($0.prefix(4000)) }
                }
                if name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") {
                    let id = payload["call_id"] as? String ?? "input"
                    pendingRequests.insert(id)
                    inputRequests.insert(id)
                    if name.hasSuffix("request_user_input_async") { asyncRequests.insert(id) }
                    transition(.awaitingInput, date)
                } else {
                    if state != .completed {
                        transition(pendingRequests.isEmpty ? .running : .awaitingInput, date)
                    }
                }
            } else if ["function_call_output", "custom_tool_call_output"].contains(kind) {
                if let id = payload["call_id"] as? String, !asyncRequests.contains(id) {
                    resolveRequest(id)
                }
                transition(pendingRequests.isEmpty ? .running : .awaitingInput, date)
            }
            return
        }
        if source == "antigravity" {
            let status = json["status"] as? String ?? ""
            if ["FAILED", "ERROR"].contains(status) {
                antigravityQuestionUnambiguous = false; antigravityQuestionIdentity = nil
                pendingActionDetail = nil; transition(.failed, date); return
            }
            if ["CANCELLED", "CANCELED"].contains(status) {
                antigravityQuestionUnambiguous = false; antigravityQuestionIdentity = nil
                pendingActionDetail = nil; transition(.interrupted, date); return
            }
            let calls = json["tool_calls"] as? [[String: Any]] ?? []
            let waiting = calls.contains { call in
                let name = call["name"] as? String ?? ""
                let args = call["args"] as? [String: Any] ?? [:]
                let meta = args["ArtifactMetadata"] as? [String: Any] ?? [:]
                let requiresApproval = name.hasSuffix("run_command") || name.hasSuffix("ask_question") ||
                    name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async")
                return requiresApproval || meta["RequestFeedback"] as? Bool == true
            }
            if waiting {
                // A repeated record is safe only when it has the same explicit
                // request ID and the same question and ordered option texts.
                var eligibleQuestion = false
                var nextIdentity: AntigravityQuestionIdentity?
                if calls.count == 1,
                   let call = calls.first, let name = call["name"] as? String,
                   name.hasSuffix("ask_question"), let args = call["args"] as? [String: Any] {
                    let raw = args["questions"]
                    let questions: [[String: Any]]?
                    if let array = raw as? [[String: Any]] { questions = array }
                    else if let encoded = raw as? String, let data = encoded.data(using: .utf8) {
                        questions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
                    } else { questions = nil }
                    if let questions, questions.count == 1,
                       let text = questions[0]["question"] as? String,
                       questions[0]["options"] == nil || questions[0]["options"] is [String] {
                        let options = questions[0]["options"] as? [String] ?? []
                        let requestID = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        if let requestID {
                            nextIdentity = AntigravityQuestionIdentity(requestID: requestID, question: text, options: options)
                        }
                        if inputRequests.isEmpty {
                            eligibleQuestion = true
                            antigravityRequestGeneration &+= 1
                            antigravityRequestStartedAt = date
                        } else if let nextIdentity,
                                  antigravityQuestionUnambiguous,
                                  !antigravitySawInputResult,
                                  inputRequests == Set([nextIdentity.requestID]),
                                  antigravityQuestionIdentity == nextIdentity {
                            eligibleQuestion = true
                        }
                    }
                }
                antigravityQuestionUnambiguous = eligibleQuestion
                antigravityQuestionIdentity = eligibleQuestion ? nextIdentity : nil
                for (index, call) in calls.enumerated() {
                    let name = call["name"] as? String ?? ""
                    if name.hasSuffix("ask_question") || name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") {
                        // Transcripts may omit IDs. Distinguish simultaneous calls
                        // instead of collapsing them into one pending question.
                        inputRequests.insert(call["id"] as? String ?? "\(name)#\(index)")
                        antigravitySawInputResult = false
                    }
                }
                // Extract rich detail from the tool call that requires approval
                var details: [String] = []
                for call in calls {
                    let name = call["name"] as? String ?? ""
                    let rawArgs = call["args"] as? [String: Any] ?? [:]
                    
                    // Helper to parse JSON string or cast
                    func decodeArg<T>(_ key: String) -> T? {
                        if let val = rawArgs[key] as? T { return val }
                        if let str = rawArgs[key] as? String, let data = str.data(using: .utf8) {
                            if let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? T {
                                return parsed
                            }
                            // Also try to unescape strings that are just "\"foo\""
                            if T.self == String.self {
                                if let parsed = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? T {
                                    return parsed
                                }
                            }
                        }
                        return nil
                    }

                    let summary: String? = decodeArg("toolSummary") ?? decodeArg("toolAction")
                    if name.hasSuffix("run_command") {
                        let cmd: String = decodeArg("CommandLine") ?? ""
                        let shortCmd = cmd.count > 120 ? String(cmd.prefix(120)) + "..." : cmd
                        details.append("🖥 执行命令: \(shortCmd)")
                        details.append("请在 Antigravity 中核对实际审批选项")
                    } else if name.hasSuffix("ask_question") {
                        if let questions: [[String: Any]] = decodeArg("questions"), let first = questions.first {
                            let q = first["question"] as? String ?? ""
                            let options = first["options"] as? [String] ?? []
                            if options.isEmpty {
                                details.append("❓ \(q)")
                            } else {
                                details.append("❓ \(q)")
                                for (i, opt) in options.enumerated() {
                                    details.append("   [\(i + 1)] \(opt)")
                                }
                            }
                        }
                    } else if name.hasSuffix("write_to_file") || name.hasSuffix("replace_file_content") {
                        let targetFile: String = decodeArg("TargetFile") ?? ""
                        let file = targetFile.components(separatedBy: "/").last ?? ""
                        let desc: String = decodeArg("Description") ?? summary ?? ""
                        details.append("📝 修改 \(file): \(desc)")
                        details.append("请在 Antigravity 中核对实际审批选项")
                    } else if let summary = summary {
                        details.append("🔧 \(name): \(summary)")
                    } else {
                        details.append("🔧 \(name)")
                    }
                }
                pendingActionDetail = details.isEmpty ? nil : details.joined(separator: "\n")
                transition(.awaitingInput, date)
            } else if outer == "GENERIC" {
                if status == "DONE", inputRequests.count == 1 {
                    antigravitySawInputResult = true
                }
                if state == .awaitingInput && inputRequests.isEmpty {
                    pendingActionDetail = nil
                    transition(.running, date)
                }
            } else if outer == "USER_INPUT" {
                inputRequests.removeAll()
                if state == .awaitingInput {
                    pendingActionDetail = nil
                    transition(.running, date)
                }
            } else if status == "RUNNING" || !calls.isEmpty {
                // After a single question's result, a subsequent tool call is
                // evidence that the assistant resumed the same transcript.
                if !calls.isEmpty, inputRequests.count == 1, antigravitySawInputResult {
                    inputRequests.removeAll()
                    antigravitySawInputResult = false
                    pendingActionDetail = nil
                    transition(.running, date)
                    return
                }
                if state != .awaitingInput {
                    pendingActionDetail = nil
                    transition(.running, date)
                }
            } else if outer == "PLANNER_RESPONSE" && status == "DONE" && calls.isEmpty {
                if inputRequests.count == 1, antigravitySawInputResult,
                   let content = json["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inputRequests.removeAll()
                    antigravitySawInputResult = false
                }
                guard inputRequests.isEmpty else { return }
                pendingActionDetail = nil
                transition(.completed, date)
            }
        }
    }

    mutating func clearRequests() {
        pendingRequests.removeAll()
        asyncRequests.removeAll()
        inputRequests.removeAll()
        antigravitySawInputResult = false
        antigravityQuestionUnambiguous = false
        antigravityQuestionIdentity = nil
    }

    mutating func resolveRequest(_ id: String) {
        pendingRequests.remove(id)
        asyncRequests.remove(id)
        inputRequests.remove(id)
        commandDigests.removeValue(forKey: id)
    }

    // A legacy hook has no answer ID. Only resolve an unambiguous input request,
    // never a command permission or multiple independent questions.
    mutating func inputSubmitted(requestID: String?) {
        if let requestID {
            if inputRequests.contains(requestID) { resolveRequest(requestID) }
        } else if inputRequests.count == 1, let id = inputRequests.first {
            resolveRequest(id)
        }
    }

    mutating func transition(_ state: AIState, _ date: Date) {
        self.state = state
        changedAt = date
    }

    func visibleState(now: Date) -> AIState {
        // Interrupted, and failed states display for 5s, then seamlessly transition to idle
        if [.interrupted, .failed].contains(state) && now.timeIntervalSince(changedAt) > 5 {
            return .idle
        }
        // A stale session without updates for > 10m safely resets to idle, EXCEPT if it's awaiting input (user might be away from keyboard)
        if state == .running && now.timeIntervalSince(changedAt) > 600 {
            return .idle
        }
        if state == .unknown {
            return .idle
        }
        return state
    }
}

struct AntigravityPendingIdentity: Equatable, Sendable {
    let transcript: URL
    let fileID: UInt64
    let changedAt: Date
    let requestID: String?
    let sessionEpoch: UUID?
    let generation: UInt64?

    init(transcript: URL, fileID: UInt64, changedAt: Date, requestID: String? = nil, sessionEpoch: UUID? = nil, generation: UInt64? = nil) {
        self.transcript = transcript
        self.fileID = fileID
        self.changedAt = changedAt
        self.requestID = requestID
        self.sessionEpoch = sessionEpoch
        self.generation = generation
    }
}

/// A session ID is an opaque stable digest, never a title or a local path.
/// Hook-only sessions can be displayed but cannot be replied to here.
struct AntigravitySessionSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let state: AIState
    let description: String
    let actionDetail: String?
    let pendingIdentity: AntigravityPendingIdentity?
    let lastActiveDate: Date?
}

struct ObserverSnapshot: Sendable {
    var state: AIState
    var description: String
    var lastActiveDate: Date?
    /// Rich context about the pending action (command, question, file edit details)
    var actionDetail: String?
    var codexRequests: [CodexPendingRequest] = []
    var antigravityPendingSessions: Int = 0
    var antigravityPendingIdentity: AntigravityPendingIdentity?
    var antigravitySessions: [AntigravitySessionSnapshot] = []
}

/// Keeps incomplete UTF-8/JSON records across reads. All offsets belong to this reader.
struct JSONLReader: Sendable {
    var offset: UInt64 = 0
    var pending = Data()
    var fileID: UInt64?
    var lastModification: Date?

    mutating func read(_ url: URL, consume: ([String: Any]) -> Void) throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let modification = attrs[.modificationDate] as? Date
        let reset = fileID != id || size < offset || (size == offset && modification != lastModification)
        if reset { offset = 0; pending.removeAll() }
        fileID = id; lastModification = modification
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        // Bound each read, but process the entire snapshot before publishing state.
        while offset < size {
            let data = try handle.read(upToCount: Int(min(262144, size - offset))) ?? Data()
            if data.isEmpty { break }
            offset += UInt64(data.count)
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let record = pending.prefix(upTo: newline)
                if let json = try? JSONSerialization.jsonObject(with: record) as? [String: Any] { consume(json) }
                pending.removeSubrange(...newline)
            }
            if pending.count > 16 * 1024 * 1024 { throw CocoaError(.fileReadTooLarge) }
        }
        return reset
    }
}
