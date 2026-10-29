import AppKit
import Foundation

struct AntigravityPreparedQuestion: Equatable, Sendable {
    let identity: AntigravityPendingIdentity
    let detail: String
    let question: AntigravityQuestion
    let endpoint: AntigravityLocalTransport.Endpoint
}

private enum AntigravityPreparationResult: Sendable {
    case ready(AntigravityPreparedQuestion)
    case connectionUnavailable, queryFailed, unsupportedQuestion, detailMismatch

    var failureMessage: String {
        switch self {
        case .ready: return ""
        case .connectionUnavailable: return "无法连接 Antigravity 本机服务，请检查版本"
        case .queryFailed: return "无法读取此会话的问题，请在 Antigravity 处理"
        case .unsupportedQuestion: return "问题结构无法确认，请在 Antigravity 处理"
        case .detailMismatch: return "显示的问题与会话不一致，请在 Antigravity 处理"
        }
    }
}

@MainActor
enum AntigravityActionController {
    private static let consentKey = "antigravityLocalReplyConsent"
    private static let prevalidationKey = "antigravityPrevalidationEnabled"
    private static var activeWorker: Task<Bool, Never>?
    private static var preparationTasks: [String: Task<AntigravityPreparationResult, Never>] = [:]
    private static var preparationIDs: [String: UUID] = [:]
    private static var preparationTargets: [String: AntigravityPrevalidationTarget] = [:]
    private static var automaticTasks: Set<String> = []
    private static var automaticPrepared: Set<String> = []
    private static var automaticAttempts: [String: AntigravityPrevalidationTarget] = [:]
    // Contains no credential or question; only retained in memory after the
    // user has explicitly enabled local replies.
    private static var cachedEndpoint: AntigravityLocalTransport.Endpoint?

    static func prepare(state: AppState, sessionID: String, expectedIdentity: AntigravityPendingIdentity, expectedDetail: String, automatic: Bool = false) {
        let target = AntigravityPrevalidationTarget(identity: expectedIdentity, detail: expectedDetail)
        if let ready = state.antigravityPreparedQuestions[sessionID], ready.identity == expectedIdentity, ready.detail == expectedDetail {
            if !automatic { automaticPrepared.remove(sessionID) }
            return
        }
        if preparationTasks[sessionID] != nil, preparationTargets[sessionID] == target {
            if !automatic { automaticTasks.remove(sessionID) }
            return
        }
        preparationTasks.removeValue(forKey: sessionID)?.cancel()
        preparationTargets.removeValue(forKey: sessionID)
        automaticTasks.remove(sessionID)
        automaticPrepared.remove(sessionID)
        state.antigravityPreparedQuestions.removeValue(forKey: sessionID)
        let requestID = UUID()
        preparationIDs[sessionID] = requestID
        guard let current = state.antigravityObserver.sessions.first(where: { $0.id == sessionID }),
              current.state == .awaitingInput, current.pendingIdentity == expectedIdentity, current.actionDetail == expectedDetail,
              let cascade = cascadeID(for: expectedIdentity.transcript),
              (automatic ? (state.antigravityPrevalidationEnabled && UserDefaults.standard.bool(forKey: consentKey)) : consent()) else {
            state.antigravitySessionFeedback[sessionID] = "问题已变化或尚未授权，请在原应用确认"
            return
        }
        // The authorization dialog can run a nested event loop; check again.
        guard let afterConsent = state.antigravityObserver.sessions.first(where: { $0.id == sessionID }),
              afterConsent.state == .awaitingInput, afterConsent.pendingIdentity == expectedIdentity,
              afterConsent.actionDetail == expectedDetail, preparationIDs[sessionID] == requestID,
              UserDefaults.standard.bool(forKey: consentKey), (!automatic || state.antigravityPrevalidationEnabled) else {
            state.antigravitySessionFeedback[sessionID] = "问题已变化，请重新打开"
            return
        }
        state.antigravitySessionFeedback[sessionID] = "正在验证此会话的问题…"
        preparationTargets[sessionID] = target
        if automatic { automaticTasks.insert(sessionID) }
        let previousEndpoint = cachedEndpoint
        let task = Task.detached(priority: .userInitiated) { () -> AntigravityPreparationResult in
            let endpoint: AntigravityLocalTransport.Endpoint
            do {
                endpoint = try await AntigravityLocalTransport.endpointForPreparation(cached: previousEndpoint,
                    discover: { try await AntigravityLocalTransport.discover() },
                    revalidate: { try AntigravityLocalTransport.revalidate($0) })
            }
            catch { return .connectionUnavailable }
            let data: Data
            do {
                let query = try JSONSerialization.data(withJSONObject: ["cascadeId": cascade.uuidString.lowercased()])
                data = try await AntigravityLocalTransport.post(endpoint, method: "GetCascadeTrajectory", data: query)
            } catch { return .queryFailed }
            let question: AntigravityQuestion
            do { question = try AntigravityInteractionParser.parse(data, cascadeID: cascade) }
            catch { return .unsupportedQuestion }
            guard !Task.isCancelled, question.matchesDisplayedDetail(expectedDetail) else { return .detailMismatch }
            return .ready(AntigravityPreparedQuestion(identity: expectedIdentity, detail: expectedDetail, question: question, endpoint: endpoint))
        }
        preparationTasks[sessionID] = task
        Task {
            let result = await task.value
            guard preparationIDs[sessionID] == requestID else { return }
            preparationTasks.removeValue(forKey: sessionID)
            preparationTargets.removeValue(forKey: sessionID)
            let wasAutomatic = automaticTasks.remove(sessionID) != nil
            defer { refreshPrevalidation(state: state) }
            let latest = state.antigravityObserver.sessions.first { $0.id == sessionID }
            guard latest?.state == .awaitingInput, latest?.pendingIdentity == expectedIdentity,
                  latest?.actionDetail == expectedDetail, UserDefaults.standard.bool(forKey: consentKey),
                  (!wasAutomatic || state.antigravityPrevalidationEnabled) else {
                state.antigravitySessionFeedback[sessionID] = "问题已变化，请重新打开后确认"
                return
            }
            guard case .ready(let prepared) = result else {
                if case .queryFailed = result, cachedEndpoint == previousEndpoint { cachedEndpoint = nil }
                state.antigravitySessionFeedback[sessionID] = result.failureMessage
                return
            }
            cachedEndpoint = prepared.endpoint
            state.antigravityPreparedQuestions[sessionID] = prepared
            if wasAutomatic { automaticPrepared.insert(sessionID) }
            state.antigravitySessionFeedback.removeValue(forKey: sessionID)
        }
    }

    static func discard(state: AppState, sessionID: String) {
        preparationTasks.removeValue(forKey: sessionID)?.cancel()
        preparationIDs.removeValue(forKey: sessionID)
        preparationTargets.removeValue(forKey: sessionID)
        automaticTasks.remove(sessionID)
        automaticPrepared.remove(sessionID)
        state.antigravityPreparedQuestions.removeValue(forKey: sessionID)
        state.antigravitySessionFeedback.removeValue(forKey: sessionID)
    }

    static func setPrevalidation(_ enabled: Bool, state: AppState) {
        if enabled {
            guard consent() else { return }
            let alert = NSAlert()
            alert.messageText = "启用 Antigravity 提前验证？"
            alert.informativeText = "检测到待回答问题时，AgentIsland 会在你打开面板前读取 Antigravity 本机进程的临时认证信息并查询对应问题，以减少等待。认证信息不会保存或上传；问题暂存在内存，不会自动发送回复。你可随时关闭此功能。"
            alert.addButton(withTitle: "启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn, UserDefaults.standard.bool(forKey: consentKey) else { return }
            UserDefaults.standard.set(true, forKey: prevalidationKey)
            state.antigravityPrevalidationEnabled = true
            refreshPrevalidation(state: state)
        } else {
            UserDefaults.standard.set(false, forKey: prevalidationKey)
            state.antigravityPrevalidationEnabled = false
            stopAutomaticPrevalidation(state: state)
        }
    }

    private static func stopAutomaticPrevalidation(state: AppState) {
        for id in Array(automaticTasks.union(automaticPrepared)) { discard(state: state, sessionID: id) }
        automaticAttempts.removeAll()
    }

    /// Never auto-send. Skip ambiguous sessions and bound concurrent reads.
    static func refreshPrevalidation(state: AppState) {
        let sessions = state.antigravityObserver.sessions
        let targets = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            AntigravityPrevalidationPolicy.target(for: session).map { (session.id, $0) }
        })
        for id in Array(automaticAttempts.keys) where automaticAttempts[id] != targets[id] {
            automaticAttempts.removeValue(forKey: id)
        }
        for id in Array(preparationTargets.keys) where preparationTargets[id] != targets[id] {
            discard(state: state, sessionID: id)
        }
        for id in Array(state.antigravityPreparedQuestions.keys) {
            guard let prepared = state.antigravityPreparedQuestions[id] else { continue }
            if targets[id] != AntigravityPrevalidationTarget(identity: prepared.identity, detail: prepared.detail) {
                discard(state: state, sessionID: id)
            }
        }
        guard state.antigravityPrevalidationEnabled, state.antigravityEnabled,
              UserDefaults.standard.bool(forKey: consentKey), UserDefaults.standard.bool(forKey: prevalidationKey) else {
            stopAutomaticPrevalidation(state: state)
            return
        }
        let candidates = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true, sessions: sessions,
            inFlight: Set(preparationTasks.keys), attempted: automaticAttempts, prepared: state.antigravityPreparedQuestions,
            limit: max(0, 2 - automaticTasks.count))
        for (id, target) in candidates {
            automaticAttempts[id] = target
            prepare(state: state, sessionID: id, expectedIdentity: target.identity, expectedDetail: target.detail, automatic: true)
        }
    }

    static func submit(_ selection: AntigravityReplyWorkflow.Selection, state: AppState, sessionID: String? = nil,
                       expectedIdentity: AntigravityPendingIdentity? = nil, expectedDetail: String? = nil,
                       expectedQuestion: AntigravityQuestion? = nil) {
        func feedback(_ message: String) {
            if let sessionID { state.antigravitySessionFeedback[sessionID] = message }
            else { state.antigravityDescription = message }
        }
        guard !state.antigravityActionInFlight else {
            feedback("另一条回复正在处理，请稍候")
            return
        }
        let selected = sessionID.flatMap { id in state.antigravityObserver.sessions.first { $0.id == id } }
        if sessionID != nil, selected == nil {
            feedback("会话已变化，请在 Antigravity 中确认")
            return
        }
        if let selected, selected.state != .awaitingInput {
            feedback("此会话不再等待回复，请在 Antigravity 中确认")
            return
        }
        let identity = sessionID == nil ? state.antigravityObserver.pendingIdentity : selected?.pendingIdentity
        let detail = sessionID == nil ? state.antigravityObserver.actionDetail : selected?.actionDetail
        guard let identity else {
            feedback("问题身份不明确，请在 Antigravity 中回答")
            return
        }
        guard let detail,
              let cascade = cascadeID(for: identity.transcript) else {
            feedback("问题详情或会话标识不可用，请在 Antigravity 中回答")
            return
        }
        var preparedEndpoint: AntigravityLocalTransport.Endpoint?
        if let sessionID {
            guard identity == expectedIdentity, detail == expectedDetail, let expectedQuestion,
                  let prepared = state.antigravityPreparedQuestions[sessionID],
                  prepared.identity == identity, prepared.detail == detail, prepared.question == expectedQuestion else {
                feedback("问题已变化，请重新打开后确认")
                return
            }
            preparedEndpoint = prepared.endpoint
        }
        guard consent() else { return }
        if let sessionID {
            let current = state.antigravityObserver.sessions.first { $0.id == sessionID }
            guard current?.state == .awaitingInput, current?.pendingIdentity == identity, current?.actionDetail == detail,
                  UserDefaults.standard.bool(forKey: consentKey), let expectedQuestion,
                  let prepared = state.antigravityPreparedQuestions[sessionID],
                  prepared.identity == identity, prepared.detail == detail, prepared.question == expectedQuestion,
                  prepared.endpoint == preparedEndpoint else {
                feedback("问题已变化，请重新打开后确认")
                return
            }
        }
        state.antigravityActionInFlight = true
        feedback("正在验证 Antigravity 问题…")
        let capturedEndpoint = preparedEndpoint
        let worker = Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    let endpoint = try await AntigravityLocalTransport.endpointForReply(prepared: capturedEndpoint,
                        discover: { try await AntigravityLocalTransport.discover() },
                        revalidate: { try AntigravityLocalTransport.revalidate($0) })
                    let query = try JSONSerialization.data(withJSONObject: ["cascadeId": cascade.uuidString.lowercased()])
                    return try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: selection, expectedQuestion: expectedQuestion,
                        fetch: { try await AntigravityLocalTransport.post(endpoint, method: "GetCascadeTrajectory", data: query) },
                        stillCurrent: {
                            await MainActor.run {
                                let sameTarget: Bool
                                if let sessionID {
                                    let current = state.antigravityObserver.sessions.first { $0.id == sessionID }
                                    sameTarget = current?.state == .awaitingInput && current?.pendingIdentity == identity && current?.actionDetail == detail
                                } else {
                                    sameTarget = state.antigravityObserver.pendingIdentity == identity && state.antigravityObserver.actionDetail == detail
                                }
                                return sameTarget && UserDefaults.standard.bool(forKey: consentKey)
                            }
                        },
                        submit: { payload in
                            _ = try await AntigravityLocalTransport.post(endpoint, method: "HandleCascadeUserInteraction", data: payload)
                        })
                } catch { return false }
        }
        activeWorker = worker
        Task {
            let result = await worker.value
            activeWorker = nil
            state.antigravityActionInFlight = false
            if let sessionID { state.antigravityPreparedQuestions.removeValue(forKey: sessionID) }
            feedback(result ? "已发送，等待 Antigravity 状态更新" : "未能确认送达，请在 Antigravity 中检查后再操作")
        }
    }

    private static func cascadeID(for transcript: URL) -> UUID? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true).standardizedFileURL
        let path = transcript.standardizedFileURL
        let rootParts = root.pathComponents, parts = path.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts,
              parts.last == "transcript.jsonl" else { return nil }
        return UUID(uuidString: parts[rootParts.count])
    }

    private static func consent() -> Bool {
        if UserDefaults.standard.bool(forKey: consentKey) { return true }
        let alert = NSAlert()
        alert.messageText = "启用 Antigravity 后台回复？"
        alert.informativeText = "AgentIsland 将在你打开或提交回复时读取 Antigravity 本机进程的临时认证信息，并访问该问题所属的本机会话。认证信息仅用于本机连接，不会保存；问题内容可能在内存中处理。该接口尚未公开，版本变化可能导致回复失败。"
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: consentKey)
        return true
    }

    static func revokeConsent(state: AppState) {
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: prevalidationKey)
        state.antigravityPrevalidationEnabled = false
        cachedEndpoint = nil
        activeWorker?.cancel()
        for (id, task) in preparationTasks {
            task.cancel()
            state.antigravitySessionFeedback[id] = "已撤销后台回复授权"
        }
        preparationTasks.removeAll()
        preparationIDs.removeAll()
        preparationTargets.removeAll()
        automaticTasks.removeAll()
        automaticPrepared.removeAll()
        automaticAttempts.removeAll()
        state.antigravityPreparedQuestions.removeAll()
    }
}
