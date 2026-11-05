import Foundation

public struct CodexQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var options: [String]
}

actor CodexDesktopBridge {
    static let shared = CodexDesktopBridge()
    private static let ioQueue = DispatchQueue(label: "AgentIsland.CodexIPC", qos: .utility, attributes: .concurrent)
    private var retryAfter: [String: Date] = [:]
    private var historyRetryAfter: [String: Date] = [:]
    struct Reply: Decodable, Sendable {
        var ok: Bool
        var error: String?
        var message: String?
        var runtime: String?
        var activity: String?
        var turnID: String?
        var turnStartedAtMs: Double?
        var requests: [Request]?
        var resolvedAsyncCallIDs: [String]?
        var historicalAsyncCallIDs: [String]?
    }
    struct Request: Decodable, Sendable {
        var requestID: String
        var method: String
        var context: String
        var questions: [CodexQuestion]
    }
    private func call(_ input: [String: Any]) async throws -> Reply {
        let data = try JSONSerialization.data(withJSONObject: input)
        // poll/recv are bounded blocking calls. Keep them off both the main actor
        // and Swift's cooperative executor so polling cannot starve a reply.
        return try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do { continuation.resume(returning: try Self.execute(data)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private nonisolated static func execute(_ input: Data) throws -> Reply {
        let data = try CodexNativeBridge.run(input)
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    func requests(session: String, force: Bool = false, loadFullHistory: Bool = false) async -> (requests: [CodexPendingRequest], activity: CodexLiveActivity, resolvedAsyncCallIDs: Set<String>, historicalAsyncCallIDs: Set<String>)? {
        if !force, let retry = retryAfter[session], retry > Date() { return nil }
        let loadHistory = loadFullHistory && (historyRetryAfter[session] ?? .distantPast) <= Date()
        if loadHistory { historyRetryAfter[session] = Date().addingTimeInterval(30) }
        guard let reply = try? await call(["sessionID": session, "loadCompleteHistory": loadHistory]), reply.ok else {
            retryAfter[session] = Date().addingTimeInterval(30)
            return nil
        }
        retryAfter.removeValue(forKey: session)
        let requests: [CodexPendingRequest] = (reply.requests ?? []).map { .init(sessionID: session, turnID: nil, requestID: $0.requestID,
            isQuestion: !$0.questions.isEmpty, context: $0.context, questions: $0.questions, desktopMethod: $0.method) }
        let state = reply.activity.flatMap(AIState.init(rawValue:)) ?? (reply.runtime == "active" ? .running : .unknown)
        let startedAt = reply.turnStartedAtMs.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return (requests, CodexLiveActivity(sessionID: session, turnID: reply.turnID, state: state, startedAt: startedAt), Set(reply.resolvedAsyncCallIDs ?? []), Set(reply.historicalAsyncCallIDs ?? []))
    }
    func respond(_ request: CodexPendingRequest, answers: [String: String] = [:], approve: Bool = false) async -> String {
        do {
            let result = try await call(["action": "reply", "sessionID": request.sessionID, "requestID": request.requestID,
                                   "answers": answers, "decision": approve ? "accept" : "decline"])
            return result.ok ? (result.message ?? "已发送") : (result.error ?? "Codex 未接受操作")
        } catch { return "Codex 回传失败：\(error.localizedDescription)" }
    }
}
