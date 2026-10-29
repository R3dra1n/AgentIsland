import Foundation

struct HookStateStore: Sendable {
    struct Owner: Hashable, Sendable { let session: String; let agent: String }
    var owners: [Owner: SessionState] = [:]
    var sessionTurns: [String: String] = [:]
    var seenTurns: [String: Set<String>] = [:]
    var sessionDates: [String: Date] = [:]
    var hookedSessions: Set<String> = []

    mutating func consume(_ event: [String: Any]) {
        guard let session = event["session_id"] as? String,
              let name = event["hook_event_name"] as? String,
              let timestamp = event["received_at"] as? Double else { return }
        let date = Date(timeIntervalSince1970: timestamp)
        guard date >= sessionDates[session] ?? .distantPast else { return }
        let turn = event["turn_id"] as? String
        let agent = event["agent_id"] as? String ?? "main"
        let owner = Owner(session: session, agent: agent)
        if ["SessionStart", "SessionEnd"].contains(name) {
            owners = owners.filter { $0.key.session != session }
            sessionTurns.removeValue(forKey: session)
            sessionDates[session] = date
            hookedSessions.insert(session)
            return
        }
        if name == "UserPromptSubmit" {
            if turn == sessionTurns[session], turn != nil {
                var value = owners[owner] ?? SessionState()
                value.inputSubmitted(requestID: event["request_id"] as? String)
                value.transition(value.pendingRequests.isEmpty ? .running : .awaitingInput, date)
                owners[owner] = value
                sessionDates[session] = date
                hookedSessions.insert(session)
                return
            }
            guard let turn else { return }
            if seenTurns[session, default: []].contains(turn), sessionTurns[session] != turn { return }
            owners = owners.filter { $0.key.session != session }
            sessionTurns[session] = turn
            seenTurns[session, default: []].insert(turn)
        } else if let turn, let active = sessionTurns[session], turn != active { return }
        if sessionTurns[session] == nil, let turn { sessionTurns[session] = turn }
        var value = owners[owner] ?? SessionState()
        value.turnID = turn ?? value.turnID
        switch name {
        case "UserPromptSubmit", "SubagentStart":
            value.clearRequests()
            value.transition(.running, date)
        case "PreInvocation":
            value.transition(value.pendingRequests.isEmpty ? .running : .awaitingInput, date)
        case "PermissionRequest":
            let id = event["tool_use_id"] as? String ?? event["tool_name"] as? String ?? "permission"
            value.pendingRequests.insert(id)
            if let digest = event["command_digest"] as? String, digest.count == 64 {
                value.commandDigests[id] = digest
            }
            value.transition(.awaitingInput, date)
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? ""
            let requiresApproval = tool.hasSuffix("run_command") || tool.hasSuffix("ask_question") ||
                tool.hasSuffix("request_user_input") || tool.hasSuffix("request_user_input_async")
            if requiresApproval {
                let id = event["tool_use_id"] as? String ?? tool
                value.pendingRequests.insert(id)
                if tool.hasSuffix("ask_question") || tool.hasSuffix("request_user_input") || tool.hasSuffix("request_user_input_async") {
                    value.inputRequests.insert(id)
                }
                if tool.hasSuffix("request_user_input_async") { value.asyncRequests.insert(id) }
                value.transition(.awaitingInput, date)
            } else {
                // Active tool execution: command/tool is running, do not clear async pending approvals
                value.transition(value.pendingRequests.isEmpty ? .running : .awaitingInput, date)
            }
        case "PostToolUse":
            let tool = event["tool_name"] as? String ?? ""
            let id = event["tool_use_id"] as? String ?? tool
            if !value.asyncRequests.contains(id) && !tool.hasSuffix("request_user_input_async") {
                value.resolveRequest(id)
            }
            value.transition(value.pendingRequests.isEmpty ? .running : .awaitingInput, date)
        case "Stop", "AgentResponse":
            value.clearRequests()
            let hasError = event["has_error"] as? Bool == true
            let reason = event["termination_reason"] as? String
            let fullyIdle = event["fully_idle"] as? Bool ?? true
            if hasError || reason == "error" || reason == "max_steps_exceeded" {
                value.transition(.failed, date)
            } else if reason == "cancelled" || reason == "interrupted" {
                value.transition(.interrupted, date)
            } else if !fullyIdle {
                value.transition(.running, date)
            } else {
                value.transition(.completed, date)
            }
        case "Interrupt": value.clearRequests(); value.transition(.interrupted, date)
        case "SubagentStop": owners.removeValue(forKey: owner); sessionDates[session] = date; hookedSessions.insert(session); return
        default: return
        }
        owners[owner] = value
        sessionDates[session] = date
        hookedSessions.insert(session)
    }

    func states(now: Date) -> [AIState] { owners.values.map { $0.visibleState(now: now) } }
}
