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

    private func publish(_ snapshot: ObserverSnapshot) {
        lastActiveDate = snapshot.lastActiveDate
        pendingSessionCount = snapshot.antigravityPendingSessions
        pendingIdentity = snapshot.antigravityPendingIdentity
        let detailChanged = actionDetail != snapshot.actionDetail
        guard state != snapshot.state || statusDescription != snapshot.description || detailChanged else { return }
        state = snapshot.state
        statusDescription = snapshot.description
        actionDetail = snapshot.actionDetail
        delegate?.observer(self, didUpdateState: state, description: statusDescription, actionDetail: actionDetail)
    }
}
