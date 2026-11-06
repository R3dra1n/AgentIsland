import Foundation
import AppKit

@MainActor
public final class ClaudeObserver: AIObserverProtocol {
    public let id = "claude"
    public let displayName = "Claude"
    public let iconName = "claude"
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
    /// Every conversation that currently has something to show, not only the
    /// most recently written one.
    private(set) var sessions: [ClaudeSessionSnapshot] = []
    public weak var delegate: AIObserverDelegate?

    private var polling: Task<Void, Never>?
    private let claudeDir: URL
    private let scanner: ClaudeSessionScanner

    public init(root: URL? = nil, hookURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = root ?? home.appendingPathComponent(".claude")
        self.claudeDir = directory
        self.scanner = ClaudeSessionScanner(projects: directory.appendingPathComponent("projects"),
                                            journal: ClaudeHookJournal(url: hookURL))
    }

    public func startObserving() {
        stopObserving()
        guard isEnabled else { return }
        let dir = self.claudeDir
        let scanner = self.scanner
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Self.inspectClaude(at: dir, scanner: scanner)
                guard !Task.isCancelled else { return }
                self?.publish(snapshot)
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    public func stopObserving() {
        polling?.cancel()
        polling = nil
    }

    private func publish(_ snapshot: ObserverSnapshot) {
        lastActiveDate = snapshot.lastActiveDate
        // A new question can arrive while the state and description stay the
        // same, and a second conversation can appear while the leading one does
        // not change, so both have to be part of the change check.
        let sessionsChanged = sessions != snapshot.claudeSessions
        sessions = snapshot.claudeSessions
        guard state != snapshot.state || statusDescription != snapshot.description
                || actionDetail != snapshot.actionDetail || sessionsChanged else { return }
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }

    private nonisolated static func inspectClaude(at dir: URL, scanner: ClaudeSessionScanner) async -> ObserverSnapshot {
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return ObserverSnapshot(state: .idle, description: "未发现 Claude 配置目录", lastActiveDate: nil)
        }
        let sessions = await scanner.scan()
        // The provider-level state is whichever conversation needs the user most.
        if let leading = ClaudeSessionEvaluator.leading(sessions) {
            return ObserverSnapshot(state: leading.state, description: leading.description,
                                    lastActiveDate: sessions.compactMap(\.lastActiveDate).max(),
                                    actionDetail: leading.actionDetail, claudeSessions: sessions)
        }
        let isProcessRunning = NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName ?? "").localizedCaseInsensitiveContains("Claude")
                || (app.bundleIdentifier ?? "").localizedCaseInsensitiveContains("anthropic")
        }
        return ObserverSnapshot(state: .idle, description: isProcessRunning ? "待命中 (Claude 已就绪)" : "待命中",
                                lastActiveDate: nil)
    }

    /// Dynamically reads the user's actual Claude subscription tier from ~/.claude.json
    public static func fetchSubscriptionTier() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeJsonUrl = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: claudeJsonUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any] else {
            return "API"
        }

        let rawBillingType = (oauth["organizationBillingType"] as? String) ?? (oauth["billingType"] as? String) ?? "api"
        let billingType = rawBillingType.lowercased()

        switch billingType {
        case "api_evaluation", "evaluation":
            return "Free"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "free":
            return "Free"
        case "api", "prepaid":
            return "API"
        default:
            return rawBillingType.capitalized
        }
    }
}
