import Foundation
import AppKit

@MainActor
public final class GenericProcessObserver: AIObserverProtocol {
    public let id: String
    public let displayName: String
    public let iconName: String
    public let processNameKeywords: [String]
    
    public var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled {
                startObserving()
            } else {
                stopObserving()
                publish(ObserverSnapshot(state: .idle, description: "已关闭监控", lastActiveDate: nil))
            }
        }
    }
    
    public private(set) var state: AIState = .unknown
    public private(set) var statusDescription = "等待首次读取"
    public private(set) var actionDetail: String?
    public private(set) var lastActiveDate: Date?
    public weak var delegate: AIObserverDelegate?

    private var polling: Task<Void, Never>?

    public init(id: String, displayName: String, iconName: String, processNameKeywords: [String]) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.processNameKeywords = processNameKeywords
    }

    public func startObserving() {
        stopObserving()
        guard isEnabled else { return }
        let keywords = self.processNameKeywords
        let provider = self.id
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Self.inspectProcess(keywords: keywords, provider: provider)
                guard !Task.isCancelled else { return }
                self?.publish(snapshot)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    public func stopObserving() {
        polling?.cancel()
        polling = nil
    }

    private func publish(_ snapshot: ObserverSnapshot) {
        lastActiveDate = snapshot.lastActiveDate
        guard state != snapshot.state || statusDescription != snapshot.description else { return }
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }

    private static func inspectProcess(keywords: [String], provider: String) async -> ObserverSnapshot {
        var isProcessRunning = false
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? ""
            let bid = app.bundleIdentifier ?? ""
            if keywords.contains(where: { name.localizedCaseInsensitiveContains($0) || bid.localizedCaseInsensitiveContains($0) }) {
                isProcessRunning = true
                break
            }
        }
        
        if provider == "trae" {
            return await TraeStatusProbe.inspect()
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentIsland/providers/\(provider)")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var states: [(AIState, Date)] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(ProviderRecord.self, from: data),
                  let state = AIState(rawValue: record.state) else { continue }
            let date = Date(timeIntervalSince1970: record.updatedAt)
            guard Date().timeIntervalSince(date) < 86400 else { continue }
            states.append((state, date))
        }
        if let winner = states.max(by: { $0.0 < $1.0 }) {
            let state: AIState = !isProcessRunning && winner.0 == .running ? .unknown : winner.0
            return ObserverSnapshot(state: state, description: state == .unknown ? "应用已退出，任务状态未知" : "Hook：\(state.title)", lastActiveDate: winner.1)
        }
        if provider == "cursor" { return await CursorStatusProbe.inspect() }
        return ObserverSnapshot(state: .unknown, description: isProcessRunning ? "等待首个任务 Hook（仅状态监控）" : "应用未运行", lastActiveDate: nil)
    }
}

private struct ProviderRecord: Decodable {
    var state: String
    var updatedAt: Double
}
