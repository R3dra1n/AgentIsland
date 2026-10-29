import AppKit
import Foundation

@MainActor
enum AntigravityActionController {
    private static let consentKey = "antigravityLocalReplyConsent"
    private static var activeWorker: Task<Bool, Never>?

    static func submit(_ selection: AntigravityReplyWorkflow.Selection, state: AppState) {
        guard !state.antigravityActionInFlight else { return }
        guard let identity = state.antigravityObserver.pendingIdentity else {
            state.antigravityDescription = "问题身份不明确，请在 Antigravity 中回答"
            return
        }
        guard let detail = state.antigravityObserver.actionDetail,
              let cascade = cascadeID(for: identity.transcript) else {
            state.antigravityDescription = "问题详情或会话标识不可用，请在 Antigravity 中回答"
            return
        }
        guard consent() else { return }
        state.antigravityActionInFlight = true
        state.antigravityDescription = "正在验证 Antigravity 问题…"
        let worker = Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    let endpoint = try await AntigravityLocalTransport.discover()
                    let query = try JSONSerialization.data(withJSONObject: ["cascadeId": cascade.uuidString.lowercased()])
                    return try await AntigravityReplyWorkflow.run(cascade: cascade, detail: detail, selection: selection,
                        fetch: { try await AntigravityLocalTransport.post(endpoint, method: "GetCascadeTrajectory", data: query) },
                        stillCurrent: {
                            await MainActor.run {
                                state.antigravityObserver.pendingIdentity == identity &&
                                state.antigravityObserver.actionDetail == detail &&
                                UserDefaults.standard.bool(forKey: consentKey)
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
            state.antigravityDescription = result
                ? "已发送，等待 Antigravity 状态更新"
                : "未能确认送达，请在 Antigravity 中检查后再操作"
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
        alert.informativeText = "AgentIsland 将在你提交回复时读取 Antigravity 本机进程的临时认证信息，并访问该问题所属的本机会话。认证信息仅用于本机连接，不会保存；问题内容可能在内存中处理。该接口尚未公开，版本变化可能导致回复失败。"
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: consentKey)
        return true
    }

    static func revokeConsent() {
        UserDefaults.standard.removeObject(forKey: consentKey)
        activeWorker?.cancel()
    }
}
