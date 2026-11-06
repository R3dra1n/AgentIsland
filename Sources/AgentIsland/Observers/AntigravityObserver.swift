import Foundation

@MainActor
public final class AntigravityObserver: AIObserverProtocol {
    public let id = "antigravity"
    public let displayName = "Antigravity"
    public let iconName = "sparkles"
    public var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled { startObserving() } else { stopObserving(); publish(.init(state: .idle, description: "已关闭监控", lastActiveDate: nil)) }
        }
    }
    public private(set) var state: AIState = .unknown
    public private(set) var statusDescription = "等待首次读取"
    public private(set) var actionDetail: String?
    public private(set) var lastActiveDate: Date?
    public private(set) var pendingSessionCount = 0
    private(set) var pendingIdentity: AntigravityPendingIdentity?
    private(set) var sessions: [AntigravitySessionSnapshot] = []
    /// Questions the language server has confirmed are no longer waiting. A
    /// transcript records a question being asked but nothing when its
    /// conversation is closed or cancelled, so without this a session whose
    /// question was cancelled reads as waiting for as long as the file exists.
    private var endedQuestions: Set<AntigravityPendingIdentity> = []
    private var lastRaw: ObserverSnapshot?
    public weak var delegate: AIObserverDelegate?
    private var polling: Task<Void, Never>?
    private let scanner: LogScanner

    public init(root: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = home.appendingPathComponent(".gemini/antigravity/brain")
        scanner = LogScanner(source: id, root: root ?? defaultRoot)
    }

    public func startObserving() {
        stopObserving()
        guard isEnabled else { return }
        let scanner = self.scanner
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await scanner.scan()
                guard !Task.isCancelled else { return }
                self?.publish(snapshot)
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    public func stopObserving() { polling?.cancel(); polling = nil }

    /// Records that the server no longer has this question waiting, and
    /// republishes immediately rather than on the next poll.
    func markQuestionEnded(_ identity: AntigravityPendingIdentity) {
        guard sessions.contains(where: { $0.pendingIdentity == identity && $0.state == .awaitingInput }) else { return }
        endedQuestions.insert(identity)
        if let raw = lastRaw { publish(raw) }
    }

    nonisolated static func description(for state: AIState) -> String {
        switch state {
        case .awaitingInput: return "等待用户操作 / 指令审批"
        case .running: return "正在推理并执行任务..."
        case .completed: return "本轮任务已完成"
        case .interrupted: return "任务已中断"
        case .failed: return "执行出错"
        case .idle, .unknown: return "待命中"
        }
    }

    /// Applies the server-confirmed endings to a scanned snapshot, and forgets
    /// endings whose question is no longer present so the set cannot grow.
    nonisolated static func reconciling(_ snapshot: ObserverSnapshot, ended: Set<AntigravityPendingIdentity>)
        -> (snapshot: ObserverSnapshot, ended: Set<AntigravityPendingIdentity>) {
        let remaining = ended.intersection(Set(snapshot.antigravitySessions.compactMap(\.pendingIdentity)))
        guard !remaining.isEmpty else { return (snapshot, remaining) }
        var result = snapshot
        let listedWaiting = snapshot.antigravitySessions.filter { $0.state == .awaitingInput }.count
        result.antigravitySessions = snapshot.antigravitySessions.map { session in
            guard session.state == .awaitingInput, let identity = session.pendingIdentity, remaining.contains(identity) else { return session }
            return AntigravitySessionSnapshot(id: session.id, state: .idle, description: description(for: .idle),
                                              actionDetail: nil, pendingIdentity: nil, lastActiveDate: session.lastActiveDate)
        }
        // A waiting state that came from somewhere other than these sessions
        // (a hook, say) is not something the server's answer disproves, so the
        // aggregate is left alone in that case; only the rows are corrected.
        guard snapshot.antigravityPendingSessions <= listedWaiting else { return (result, remaining) }
        let stillWaiting = result.antigravitySessions.filter { $0.state == .awaitingInput }
        result.antigravityPendingSessions = stillWaiting.count
        if stillWaiting.isEmpty {
            result.antigravityPendingIdentity = nil
            if snapshot.state == .awaitingInput {
                let next = result.antigravitySessions.map(\.state).max() ?? .idle
                result.state = next
                result.description = description(for: next)
                result.actionDetail = nil
            }
        } else {
            result.antigravityPendingIdentity = stillWaiting.count == 1 ? stillWaiting[0].pendingIdentity : nil
            if let current = snapshot.actionDetail, !stillWaiting.contains(where: { $0.actionDetail == current }) {
                result.actionDetail = stillWaiting.max { ($0.lastActiveDate ?? .distantPast) < ($1.lastActiveDate ?? .distantPast) }?.actionDetail
            }
        }
        return (result, remaining)
    }

    private func publish(_ raw: ObserverSnapshot) {
        lastRaw = raw
        let reconciled = Self.reconciling(raw, ended: endedQuestions)
        endedQuestions = reconciled.ended
        let snapshot = reconciled.snapshot
        lastActiveDate = snapshot.lastActiveDate
        pendingSessionCount = snapshot.antigravityPendingSessions
        pendingIdentity = snapshot.antigravityPendingIdentity
        let sessionsChanged = sessions != snapshot.antigravitySessions
        sessions = snapshot.antigravitySessions
        let detailChanged = actionDetail != snapshot.actionDetail
        guard state != snapshot.state || statusDescription != snapshot.description || detailChanged || sessionsChanged else { return }
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }
}
