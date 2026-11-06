import Foundation

struct CodexLiveActivity: Sendable {
    var sessionID: String
    var turnID: String?
    var state: AIState
    var startedAt: Date?
}

@MainActor
public final class CodexObserver: AIObserverProtocol {
    public let id = "codex"
    public let displayName = "Codex"
    public let iconName = "terminal"
    public var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled { startObserving() } else { stopObserving(); publish(.init(state: .idle, description: "已关闭监控", lastActiveDate: nil)) }
        }
    }
    public private(set) var state: AIState = .unknown
    public private(set) var statusDescription = "等待首次读取"
    public private(set) var actionDetail: String?
    public private(set) var pendingRequests: [CodexPendingRequest] = []
    public private(set) var lastActiveDate: Date?
    public weak var delegate: AIObserverDelegate?
    private var polling: Task<Void, Never>?
    private let scanner: LogScanner
    /// When each session's requests were last confirmed by a source that could
    /// actually see them, so a session the desktop can no longer reach cannot
    /// keep its requests on screen forever.
    private var lastConfirmed: [String: Date] = [:]

    public init(root: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("sessions") } ?? home.appendingPathComponent(".codex/sessions")
        scanner = LogScanner(source: id, root: root ?? defaultRoot,
            // The recorder can create its journal after the app starts.
            hookURL: root == nil ? Self.hookJournalURL(home: home) : nil)
    }

    /// Where the Codex hook recorder writes its journal. Both recorders write
    /// under `AgentIsland`, but this once read the pre-rename `AiKeyboardLight`
    /// location, so events from a hook installed through the app were never
    /// seen. The old location is still honoured, but only for someone who has a
    /// journal there and none in the current place.
    nonisolated static func hookJournalURL(home: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = support.appendingPathComponent("AgentIsland/events/codex.jsonl")
        let legacy = support.appendingPathComponent("AiKeyboardLight/events/codex.jsonl")
        return !fileExists(current.path) && fileExists(legacy.path) ? legacy : current
    }

    public func startObserving() {
        stopObserving()
        guard isEnabled else { return }
        let scanner = self.scanner
        polling = Task { [weak self] in
            while !Task.isCancelled {
                var snapshot = await scanner.scan()
                let previousRequests = self?.pendingRequests ?? []
                let pendingSessions = Set((snapshot.codexRequests + previousRequests).map(\.sessionID))
                let historyNeededSessions = Self.sessionsNeedingHistory(scanned: snapshot.codexRequests, previous: previousRequests)
                let fallbackActive = await scanner.activeCodexSessionStates()
                let recent = await scanner.recentCodexSessionIDs()
                let sessions = pendingSessions.union(recent).union(fallbackActive.keys).filter { !$0.isEmpty }
                var liveStates: [CodexLiveActivity] = []
                await withTaskGroup(of: (String, [CodexPendingRequest]?, CodexLiveActivity?, Set<String>, Set<String>).self) { group in
                    for session in sessions {
                        group.addTask {
                            let live = await CodexDesktopBridge.shared.requests(session: session, force: pendingSessions.contains(session) || fallbackActive[session] != nil,
                                                                                loadFullHistory: historyNeededSessions.contains(session))
                            return (session, live?.requests, live?.activity, live?.resolvedAsyncCallIDs ?? [], live?.historicalAsyncCallIDs ?? [])
                        }
                    }
                    let now = Date()
                    for await (session, requests, state, resolved, historical) in group {
                        if let requests, let state {
                            snapshot.codexRequests = Self.mergeRequests(snapshot.codexRequests, live: requests, session: session, resolvedAsyncCallIDs: resolved, historicalAsyncCallIDs: historical)
                            if state.state != .unknown { liveStates.append(state) }
                            self?.confirm(session: session, at: now)
                        } else if !snapshot.codexRequests.contains(where: { $0.sessionID == session }) {
                            // The desktop could not be asked about this session.
                            // Carrying its previous requests bridges a transient
                            // failure, but only for a bounded time: a session the
                            // desktop has stopped serving would otherwise keep its
                            // questions on screen for as long as the app runs,
                            // long after every source has stopped reporting them.
                            let confirmed = self?.lastConfirmation(session: session)
                            if Self.mayCarryOver(lastConfirmed: confirmed, now: now) {
                                snapshot.codexRequests.append(contentsOf: previousRequests.filter { $0.sessionID == session })
                            }
                        }
                    }
                }
                snapshot.codexRequests.sort { $0.id < $1.id }
                if !snapshot.codexRequests.isEmpty {
                    snapshot.state = .awaitingInput
                    snapshot.description = "Codex 正在等待操作"
                    snapshot.actionDetail = snapshot.codexRequests.first?.context
                } else if let live = Self.aggregateLiveAndFallback(liveStates, fallback: fallbackActive) {
                    snapshot.state = live.state
                    snapshot.description = "Codex：\(live.state.title)"
                    snapshot.lastActiveDate = live.startedAt ?? snapshot.lastActiveDate
                    snapshot.actionDetail = nil
                }
                guard !Task.isCancelled else { return }
                self?.publish(snapshot)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    public func stopObserving() { polling?.cancel(); polling = nil }

    /// How long a session's requests may be carried across desktop IPC
    /// failures. Long enough to ride out a restart or a busy desktop, short
    /// enough that a session nothing can see any more stops being displayed.
    nonisolated static let carryOverGrace: TimeInterval = 120

    nonisolated static func mayCarryOver(lastConfirmed: Date?, now: Date) -> Bool {
        // Never confirmed means the request came from the log scanner, which
        // re-derives it every poll; there is nothing to bridge.
        guard let lastConfirmed else { return false }
        return now.timeIntervalSince(lastConfirmed) <= carryOverGrace
    }

    private func confirm(session: String, at date: Date) { lastConfirmed[session] = date }

    private func lastConfirmation(session: String) -> Date? { lastConfirmed[session] }

    /// Which sessions should ask the desktop to load their complete history.
    /// Reconciling an async question against the full transcript is the only
    /// way to tell an answered or abandoned question from one still waiting.
    ///
    /// The questions actually displayed usually come from the desktop IPC and
    /// are merged in *after* the scan, so on any given poll they appear only in
    /// the previous poll's requests and carry `desktopMethod` rather than the
    /// scanner's `isAsynchronous`. Looking at the freshly scanned requests
    /// alone never matched them, so complete history was never requested for
    /// exactly the sessions that needed it.
    nonisolated static func sessionsNeedingHistory(scanned: [CodexPendingRequest], previous: [CodexPendingRequest]) -> Set<String> {
        Set((scanned + previous)
            .filter { $0.isAsynchronous || $0.desktopMethod == "async-question" }
            .map(\.sessionID))
    }

    nonisolated static func mergeRequests(_ existing: [CodexPendingRequest], live: [CodexPendingRequest], session: String, resolvedAsyncCallIDs: Set<String> = [], historicalAsyncCallIDs: Set<String> = []) -> [CodexPendingRequest] {
        let hidden = resolvedAsyncCallIDs.union(historicalAsyncCallIDs)
        let asyncQuestions = existing.filter { $0.sessionID == session && $0.isQuestion && $0.isAsynchronous && !hidden.contains($0.requestID) }
        var result = existing.filter { $0.sessionID != session }
        func sourceID(_ request: CodexPendingRequest) -> String {
            guard request.desktopMethod == "async-question", let bytes = request.requestID.data(using: .utf8),
                  let parts = (try? JSONSerialization.jsonObject(with: bytes)) as? [Any], parts.count == 3,
                  parts[0] as? String == "request_user_input_async", let callID = parts[1] as? String,
                  parts[2] is NSNumber else { return request.requestID }
            return callID
        }
        for var request in live {
            if request.desktopMethod == "async-question" && historicalAsyncCallIDs.contains(sourceID(request)) { continue }
            if asyncQuestions.contains(where: { $0.requestID == sourceID(request) }) { request.isAsynchronous = true }
            result.append(request)
        }
        result.append(contentsOf: asyncQuestions.filter { previous in
            !live.contains { $0.sessionID == previous.sessionID && sourceID($0) == previous.requestID }
        })
        return result
    }

    nonisolated static func aggregateLiveAndFallback(_ liveStates: [CodexLiveActivity], fallback: [String: AIState]) -> CodexLiveActivity? {
        let authoritativeSessions = Set(liveStates.filter { $0.state != .unknown }.map(\.sessionID))
        let activeFallback = fallback.compactMap { session, state -> CodexLiveActivity? in
            guard !authoritativeSessions.contains(session), state == .running || state == .awaitingInput else { return nil }
            return .init(sessionID: session, turnID: nil, state: state, startedAt: nil)
        }
        return aggregateLiveStates(liveStates + activeFallback)
    }

    // Active work wins. Once inactive, show the newest turn, not the most severe
    // outcome in historical conversations. Poll time must never refresh an old result.
    nonisolated static func aggregateLiveStates(_ states: [CodexLiveActivity]) -> CodexLiveActivity? {
        let known = states.filter { $0.state != .unknown }
        let active = known.filter { $0.state == .awaitingInput || $0.state == .running }
        if !active.isEmpty {
            return active.max { $0.state.priority < $1.state.priority }
        }
        return known.max {
            let lhs = $0.startedAt ?? .distantPast, rhs = $1.startedAt ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            if $0.state != $1.state { return $0.state.priority < $1.state.priority }
            return $0.sessionID < $1.sessionID
        }
    }

    private func publish(_ snapshot: ObserverSnapshot) {
        let activityChanged = lastActiveDate != snapshot.lastActiveDate
        lastActiveDate = snapshot.lastActiveDate
        guard activityChanged || state != snapshot.state || statusDescription != snapshot.description || actionDetail != snapshot.actionDetail || pendingRequests != snapshot.codexRequests else { return }
        pendingRequests = snapshot.codexRequests
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }
}
