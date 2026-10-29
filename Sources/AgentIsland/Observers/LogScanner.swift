import Foundation
import CryptoKit

/// File I/O and mutable parser state are isolated from the UI and from other polls.
actor LogScanner {
    private let source: String
    private let root: URL
    private var readers: [URL: JSONLReader] = [:]
    private var sessions: [URL: SessionState] = [:]
    private var candidates: [URL] = []
    private var hooks = HookStateStore()
    private var hookReader = JSONLReader()
    private var sessionIDs: [URL: String] = [:]
    private let hookURL: URL
    private var lastDiscovery = Date.distantPast

    init(source: String, root: URL, hookURL: URL? = nil) {
        self.source = source; self.root = root
        self.hookURL = hookURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland/events/\(source).jsonl")
    }

    func scan(now: Date = Date()) -> ObserverSnapshot {
        let fm = FileManager.default
        var hookFailed = false
        if fm.fileExists(atPath: hookURL.path) {
            do { _ = try hookReader.read(hookURL) { hooks.consume($0) } }
            catch { hookFailed = true }
        }
        guard fm.fileExists(atPath: root.path) else {
            if !hooks.hookedSessions.isEmpty {
                var values = hooks.states(now: now)
                if hookFailed { values.append(.unknown) }
                return ObserverSnapshot(state: values.max() ?? .idle, description: "Hooks 事件 · 日志目录未发现", lastActiveDate: hooks.sessionDates.values.max(), codexRequests: pendingCodexRequests(), antigravitySessions: antigravitySessionSnapshots(now: now))
            }
            return ObserverSnapshot(state: .unknown, description: "未找到日志目录；无法确认状态", lastActiveDate: nil)
        }
        // New Antigravity transcripts should appear promptly; existing files
        // are still read on every poll. Keep other providers' cadence intact.
        let discoveryInterval: TimeInterval = source == "antigravity" ? 2 : 5
        if now.timeIntervalSince(lastDiscovery) >= discoveryInterval {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: source == "antigravity" ? [] : [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
                return ObserverSnapshot(state: .idle, description: "日志目录不可读取", lastActiveDate: nil)
            }
            candidates = enumerator.compactMap { item -> URL? in
                guard let url = item as? URL else { return nil }
                guard source == "codex" ? url.pathExtension == "jsonl" : url.lastPathComponent == "transcript.jsonl" else { return nil }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { return nil }
                // Do not resurrect all historical sessions on startup. Retain monitored sessions.
                guard readers[url] != nil || now.timeIntervalSince(values.contentModificationDate ?? .distantPast) < 86400 else { return nil }
                return url
            }
            let present = Set(candidates)
            readers = readers.filter { present.contains($0.key) }
            sessions = sessions.filter { present.contains($0.key) }
            lastDiscovery = now
        }
        var lastActive: Date?
        for url in candidates {
            do {
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let date = attrs[.modificationDate] as? Date ?? now
                lastActive = max(lastActive ?? .distantPast, date)
                var reader = readers[url] ?? JSONLReader()
                var session = sessions[url] ?? SessionState()
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
                if reader.fileID != id || size < reader.offset || (size == reader.offset && reader.lastModification != date) { session = SessionState() }
                var sessionID = sessionIDs[url] ?? (source == "antigravity" ? url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : url.path)
                _ = try reader.read(url) { json in
                    if json["type"] as? String == "session_meta", let payload = json["payload"] as? [String: Any], let id = payload["id"] as? String { sessionID = id }
                    let stamp = json["timestamp"] as? String ?? json["created_at"] as? String
                    session.consume(json, source: source, date: Self.parseDate(stamp) ?? date)
                }
                sessionIDs[url] = sessionID
                readers[url] = reader
                sessions[url] = session
            } catch {
                // The state was discarded, so retain no old offset: the next
                // successful read must rebuild it from the complete transcript.
                sessions[url] = SessionState()
                readers.removeValue(forKey: url)
            }
        }
        var states = sessions.filter { !hooks.hookedSessions.contains(sessionIDs[$0.key] ?? "") }.values.map { $0.visibleState(now: now) }
        // If any session in transcript is actively awaiting input/approval,
        // it must always be included. Hooks (like PreInvocation) do not detect approval modals.
        for (url, value) in sessions {
            let visState = value.visibleState(now: now)
            if visState == .awaitingInput {
                let id = sessionIDs[url] ?? ""
                if source == "codex", hooks.hookedSessions.contains(id) { continue }
                if value.inputRequests.isEmpty, let hookDate = hooks.sessionDates[id], hookDate.timeIntervalSince(value.changedAt) > 5 {
                    continue
                }
                states.append(.awaitingInput)
            }
        }
        states += hooks.states(now: now)
        let resolvedWinner = states.max() ?? .idle
        let winner = (resolvedWinner == .unknown) ? .idle : resolvedWinner
        let count = states.filter { $0 == .running || $0 == .awaitingInput }.count

        // Extract the most recently updated actionDetail from sessions awaiting input
        var actionDetail: String? = {
            if winner == .awaitingInput {
                let awaiting = sessions.values.filter { $0.visibleState(now: now) == .awaitingInput && $0.pendingActionDetail != nil }
                if let mostRecent = awaiting.max(by: { $0.changedAt < $1.changedAt }) {
                    return mostRecent.pendingActionDetail
                }
            }
            return nil
        }()
        
        if actionDetail == nil && winner == .awaitingInput && source == "codex" {
            actionDetail = "❓ ChatGPT (Codex) 正在请求执行指令或需要您补充信息：\n   [y] 同意执行 (y)\n   [n] 拒绝执行 (n)\n   [c] 取消操作 (c)"
        }

        let detail: String
        switch winner {
        case .awaitingInput:
            detail = "等待用户操作 / 指令审批"
        case .running:
            detail = count > 1 ? "\(count) 个任务正在执行中..." : "正在推理并执行任务..."
        case .completed:
            detail = "本轮任务已完成"
        case .interrupted:
            detail = "任务已中断"
        case .failed:
            detail = "执行出错"
        case .idle, .unknown:
            detail = "待命中"
        }

        let requests = pendingCodexRequests()
        let codexDetail = requests.count == 1 ? requests.first?.context : nil
        let pendingAntigravity = source == "antigravity" ? sessions.filter { $0.value.visibleState(now: now) == .awaitingInput } : [:]
        let hookWaiting = source == "antigravity" ? hooks.owners.filter { $0.value.visibleState(now: now) == .awaitingInput } : [:]
        var pendingIDs = Set(pendingAntigravity.keys.map { Self.normalizedSessionID(sessionIDs[$0] ?? $0.path) })
        pendingIDs.formUnion(hookWaiting.keys.map { Self.normalizedSessionID($0.session) })
        let pendingCount = max(pendingAntigravity.count, pendingIDs.count)
        // The UI displays one concrete question. Resolve its transcript only
        // when that exact detail belongs to a single waiting transcript; the
        // RPC later verifies the cascade and live step again before sending.
        let matching = actionDetail.map { shown in
            pendingAntigravity.filter { $0.value.pendingActionDetail == shown }
        } ?? [:]
        var pendingIdentity: AntigravityPendingIdentity?
        if matching.count == 1, let (url, session) = matching.first,
           session.inputRequests.count == 1, session.antigravityQuestionUnambiguous,
           hooksPermitReply(session: session, id: sessionIDs[url] ?? url.path, now: now),
           let fileID = readers[url]?.fileID {
            pendingIdentity = AntigravityPendingIdentity(transcript: url, fileID: fileID, changedAt: session.antigravityRequestStartedAt ?? session.changedAt, requestID: session.inputRequests.first, sessionEpoch: session.antigravitySessionEpoch, generation: session.antigravityRequestGeneration)
        }
        return ObserverSnapshot(state: winner, description: detail, lastActiveDate: lastActive,
            actionDetail: source == "codex" ? (codexDetail ?? actionDetail) : actionDetail, codexRequests: requests,
            antigravityPendingSessions: pendingCount, antigravityPendingIdentity: pendingIdentity,
            antigravitySessions: antigravitySessionSnapshots(now: now))
    }

    /// Group Hook and transcript observations by session. A session can be
    /// shown without being replyable: only a single unambiguous transcript can
    /// supply the file identity required for target validation.
    private func antigravitySessionSnapshots(now: Date) -> [AntigravitySessionSnapshot] {
        guard source == "antigravity" else { return [] }
        let transcripts = Dictionary(grouping: sessions.map { ($0.key, $0.value) }) { entry in
            Self.normalizedSessionID(sessionIDs[entry.0] ?? entry.0.path)
        }
        let hookGroups = Dictionary(grouping: hooks.owners.map { ($0.key, $0.value) }) { Self.normalizedSessionID($0.0.session) }
        let ids = Set(transcripts.keys).union(hookGroups.keys)
        let snapshots: [AntigravitySessionSnapshot] = ids.compactMap { id in
            let records = transcripts[id] ?? []
            let hookRecords = hookGroups[id] ?? []
            let states = records.map { $0.1.visibleState(now: now) } + hookRecords.map { $0.1.visibleState(now: now) }
            guard let state = states.max(), state != .idle, state != .unknown else { return nil }
            let lastChanged = (records.map { $0.1.changedAt } + hookRecords.map { $0.1.changedAt }).max() ?? .distantPast
            // Historical completed sessions are not resurrected indefinitely.
            if state == .completed && now.timeIntervalSince(lastChanged) > 600 { return nil }
            let waiting = records.filter { $0.1.visibleState(now: now) == .awaitingInput && $0.1.pendingActionDetail != nil }
            let detail = state == .awaitingInput ? waiting.max(by: { $0.1.changedAt < $1.1.changedAt })?.1.pendingActionDetail : nil
            var identity: AntigravityPendingIdentity?
            if state == .awaitingInput, records.count == 1, waiting.count == 1,
               let (url, session) = waiting.first, session.inputRequests.count == 1,
               session.antigravityQuestionUnambiguous, hooksPermitReply(session: session, id: id, now: now),
               let fileID = readers[url]?.fileID {
                identity = AntigravityPendingIdentity(transcript: url, fileID: fileID, changedAt: session.antigravityRequestStartedAt ?? session.changedAt, requestID: session.inputRequests.first, sessionEpoch: session.antigravitySessionEpoch, generation: session.antigravityRequestGeneration)
            }
            let description: String
            switch state {
            case .awaitingInput: description = "等待用户操作 / 指令审批"
            case .running: description = "正在推理并执行任务…"
            case .completed: description = "本轮任务已完成"
            case .failed: description = "执行出错"
            case .interrupted: description = "任务已中断"
            case .idle, .unknown: description = "待命中"
            }
            let opaqueID = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            let lastActive = (records.compactMap { readers[$0.0]?.lastModification } + hookRecords.map { $0.1.changedAt }).max()
            return .init(id: "ag:" + opaqueID, state: state, description: description,
                         actionDetail: detail, pendingIdentity: identity, lastActiveDate: lastActive)
        }
        return snapshots.sorted {
            let left = $0.lastActiveDate ?? .distantPast, right = $1.lastActiveDate ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }

    private static func normalizedSessionID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    /// A concurrent hook-only approval or different input request in the same
    /// session cannot safely be treated as the displayed transcript question.
    private func hooksPermitReply(session: SessionState, id: String, now: Date) -> Bool {
        let normalized = Self.normalizedSessionID(id)
        for (owner, state) in hooks.owners where Self.normalizedSessionID(owner.session) == normalized && state.visibleState(now: now) == .awaitingInput {
            guard state.pendingRequests.count == 1, state.inputRequests.count == 1,
                  state.inputRequests == session.inputRequests else { return false }
        }
        return true
    }

    // Codex live status must also be queried when there is no approval/question.
    // Keep other providers' existing parsing and aggregation unchanged.
    func recentCodexSessionIDs(limit: Int = 8) -> [String] {
        guard source == "codex" else { return [] }
        var dates = hooks.sessionDates
        for (url, id) in sessionIDs where UUID(uuidString: id) != nil {
            let date = readers[url]?.lastModification ?? .distantPast
            dates[id] = max(dates[id] ?? .distantPast, date)
        }
        return dates.filter { UUID(uuidString: $0.key) != nil }
            .sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Preserve active sessions whose desktop IPC is temporarily unavailable.
    /// A live response may replace only the fallback for the same session.
    func activeCodexSessionStates(now: Date = Date()) -> [String: AIState] {
        guard source == "codex" else { return [:] }
        var result: [String: AIState] = [:]
        func record(_ id: String, _ state: AIState) {
            guard UUID(uuidString: id) != nil, state == .running || state == .awaitingInput else { return }
            result[id] = max(result[id] ?? .unknown, state)
        }
        for (url, session) in sessions {
            guard let id = sessionIDs[url], !hooks.hookedSessions.contains(id) else { continue }
            record(id, session.visibleState(now: now))
        }
        for (owner, session) in hooks.owners { record(owner.session, session.visibleState(now: now)) }
        return result
    }

    private func pendingCodexRequests() -> [CodexPendingRequest] {
        var requests: [CodexPendingRequest] = []
        if source == "codex" {
            for (owner, value) in hooks.owners where value.state == .awaitingInput {
                let log = sessions.first { sessionIDs[$0.key] == owner.session }?.value
                for id in value.pendingRequests {
                    requests.append(.init(sessionID: owner.session, turnID: value.turnID, requestID: id,
                        isQuestion: value.inputRequests.contains(id), context: log?.requestContexts[id], commandDigest: value.commandDigests[id],
                        isAsynchronous: value.asyncRequests.contains(id)))
                }
            }
            for (url, value) in sessions where !hooks.hookedSessions.contains(sessionIDs[url] ?? "") && value.state == .awaitingInput {
                for id in value.pendingRequests {
                    requests.append(.init(sessionID: sessionIDs[url] ?? "", turnID: value.turnID, requestID: id,
                        isQuestion: value.inputRequests.contains(id), context: value.requestContexts[id],
                        isAsynchronous: value.asyncRequests.contains(id)))
                }
            }
            requests.sort { $0.id < $1.id }
        }
        return requests
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
