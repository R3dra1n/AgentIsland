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
    public weak var delegate: AIObserverDelegate?

    private var polling: Task<Void, Never>?
    private let claudeDir: URL

    public init(root: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeDir = root ?? home.appendingPathComponent(".claude")
    }

    public func startObserving() {
        stopObserving()
        guard isEnabled else { return }
        let dir = self.claudeDir
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Self.inspectClaude(at: dir)
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
        guard state != snapshot.state || statusDescription != snapshot.description else { return }
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }

    private nonisolated static func inspectClaude(at dir: URL) async -> ObserverSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            return ObserverSnapshot(state: .idle, description: "未发现 Claude 配置目录", lastActiveDate: nil)
        }

        // Check if claude process is active
        var isProcessRunning = false
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? ""
            let bid = app.bundleIdentifier ?? ""
            if name.localizedCaseInsensitiveContains("Claude") || bid.localizedCaseInsensitiveContains("anthropic") {
                isProcessRunning = true
                break
            }
        }

        // Find most recently modified project session
        let projectsDir = dir.appendingPathComponent("projects")
        var latestFile: URL?
        var latestDate = Date.distantPast

        if let enumerator = fm.enumerator(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            while let fileUrl = enumerator.nextObject() as? URL {
                guard fileUrl.pathExtension == "jsonl" else { continue }
                if let values = try? fileUrl.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = values.contentModificationDate,
                   modDate > latestDate {
                    latestDate = modDate
                    latestFile = fileUrl
                }
            }
        }

        let now = Date()
        let timeSinceLast = now.timeIntervalSince(latestDate)

        if let latestFile = latestFile, timeSinceLast < 120 {
            // Read tail of the active session
            if let tail = try? Self.readTail(of: latestFile, bytes: 4096) {
                let tailStr = tail as NSString
                
                func lastIndex(of keywords: [String]) -> Int {
                    var maxIdx = -1
                    for kw in keywords {
                        let range = tailStr.range(of: kw, options: .backwards)
                        if range.location != NSNotFound && range.location > maxIdx {
                            maxIdx = range.location
                        }
                    }
                    return maxIdx
                }
                
                let askIdx = lastIndex(of: ["\"name\":\"AskUserQuestion\"", "\"name\":\"Bash\"", "\"name\":\"str_replace_editor\""])
                let runIdx = lastIndex(of: ["\"role\":\"user\"", "\"type\":\"tool_result\""])
                let astIdx = lastIndex(of: ["\"role\":\"assistant\""])
                let toolIdx = lastIndex(of: ["\"type\":\"tool_use\""])
                
                // If the most recent event is asking for approval
                if askIdx > runIdx && askIdx >= toolIdx {
                    let detail = "❓ Claude 正在请求执行指令或需要您补充信息：\n   [y] 同意执行 (y)\n   [n] 拒绝执行 (n)\n   [c] 取消操作 (c)"
                    return ObserverSnapshot(state: .awaitingInput, description: "等待用户指令审批", lastActiveDate: latestDate, actionDetail: detail)
                }
                
                // If the most recent event is the user speaking, or the assistant using a fast tool
                if runIdx > astIdx || (toolIdx > astIdx && toolIdx > askIdx) {
                    return ObserverSnapshot(state: .running, description: "正在执行任务与代码生成...", lastActiveDate: latestDate)
                }
                
                // If the most recent event is the assistant speaking (and NOT using a tool)
                if astIdx > toolIdx && astIdx > runIdx {
                    return ObserverSnapshot(state: .completed, description: "本轮对话已完成", lastActiveDate: latestDate)
                }
                
                if timeSinceLast < 8 {
                    return ObserverSnapshot(state: .running, description: "正在与 Claude 交互中...", lastActiveDate: latestDate)
                }
            }
            if timeSinceLast < 15 {
                return ObserverSnapshot(state: .running, description: "正在与 Claude 交互中...", lastActiveDate: latestDate)
            }
        }

        return ObserverSnapshot(state: .idle, description: isProcessRunning ? "待命中 (Claude 已就绪)" : "待命中", lastActiveDate: latestDate == .distantPast ? nil : latestDate)
    }

    private nonisolated static func readTail(of fileUrl: URL, bytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileUrl)
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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

