import Foundation
import SwiftUI
import Combine
import os.log
import AppKit

private let logger = Logger(subsystem: "com.antigravity.AgentIsland", category: "AppState")


@MainActor
public final class AppState: ObservableObject, AIObserverDelegate {
    // Screen HUD Settings
    @Published public var isHUDEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isHUDEnabled, forKey: "isHUDEnabled") }
    }

    @Published public var showHUDGlow: Bool = true {
        didSet { UserDefaults.standard.set(showHUDGlow, forKey: "showHUDGlow") }
    }

    
    @Published public var hudDetailMode: HUDDetailMode = .concise {
        didSet {
            UserDefaults.standard.set(hudDetailMode.rawValue, forKey: "hudDetailMode")
        }
    }

    @Published public var hudLayoutMode: HUDLayoutMode = .horizontal {
        didSet {
            UserDefaults.standard.set(hudLayoutMode.rawValue, forKey: "hudLayoutMode")
        }
    }

    @Published public var hudDisplayMode: HUDDisplayMode = .always {
        didSet { UserDefaults.standard.set(hudDisplayMode.rawValue, forKey: "hudDisplayMode") }
    }

    // Status Bar Settings: Three independent toggles
    @Published public var hudOpacity: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(hudOpacity, forKey: "hudOpacity")
            NotificationCenter.default.post(name: NSNotification.Name("HUDOpacityChanged"), object: nil)
        }
    }
    @Published public var appTheme: AppTheme = .auto {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
            NSApp.appearance = appTheme.nsAppearance
        }
    }
    @Published public var showMenuBarIcon: Bool = true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }

    @Published public var showMenuBarDot: Bool = true {
        didSet { UserDefaults.standard.set(showMenuBarDot, forKey: "showMenuBarDot") }
    }

    @Published public var showMenuBarText: Bool = false {
        didSet { UserDefaults.standard.set(showMenuBarText, forKey: "showMenuBarText") }
    }

    @Published public var soundAlertEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundAlertEnabled, forKey: "soundAlertEnabled") }
    }

    @Published public var prominentMenuBarPill: Bool = true {
        didSet { UserDefaults.standard.set(prominentMenuBarPill, forKey: "prominentMenuBarPill") }
    }

    // AI Observers Toggles
    @Published public var codexEnabled: Bool = true {
        didSet {
            codexObserver.isEnabled = codexEnabled
            UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled")
            recalculateAggregatedState()
        }
    }

    @Published public var antigravityEnabled: Bool = true {
        didSet {
            antigravityObserver.isEnabled = antigravityEnabled
            UserDefaults.standard.set(antigravityEnabled, forKey: "antigravityEnabled")
            recalculateAggregatedState()
        }
    }

    @Published public var claudeEnabled: Bool = false {
        didSet {
            claudeObserver.isEnabled = claudeEnabled
            UserDefaults.standard.set(claudeEnabled, forKey: "claudeEnabled")
            recalculateAggregatedState()
        }
    }

    @Published public var codexState: AIState = .idle
    @Published public var codexDescription: String = "待命中"
    @Published public var codexActionFeedback: String?
    @Published public var codexActionInFlight = false
    @Published public var codexPendingRequests: [CodexPendingRequest] = []
    @Published public var codexNeedsAck: Bool = false
    @Published public var codexActionDetail: String?

    @Published public var antigravityState: AIState = .idle
    @Published public var antigravityDescription: String = "待命中"
    @Published public var antigravityNeedsAck: Bool = false
    @Published public var antigravityActionDetail: String?
    @Published public var antigravityActionInFlight = false

    @Published public var claudeState: AIState = .idle
    @Published public var claudeDescription: String = "待命中"
    @Published public var claudeNeedsAck: Bool = false
    @Published public var claudeActionDetail: String?
    @Published public var claudeTier: String = ClaudeObserver.fetchSubscriptionTier()

    @Published public var aggregatedState: AIState = .idle
    @Published public var testModeActive: Bool = false

    @Published public var observerOrder: [String] = ["codex", "antigravity", "claude", "cursor", "windsurf", "trae"] {
        didSet {
            UserDefaults.standard.set(observerOrder, forKey: "observerOrder")
        }
    }

    public let codexObserver = CodexObserver()
    public let antigravityObserver = AntigravityObserver()
    public let claudeObserver = ClaudeObserver()

    @Published public var cursorEnabled: Bool = false { didSet { cursorObserver.isEnabled = cursorEnabled; UserDefaults.standard.set(cursorEnabled, forKey: "cursorEnabled"); recalculateAggregatedState() } }
    @Published public var windsurfEnabled: Bool = false { didSet { windsurfObserver.isEnabled = windsurfEnabled; UserDefaults.standard.set(windsurfEnabled, forKey: "windsurfEnabled"); recalculateAggregatedState() } }

    @Published public var traeEnabled: Bool = false { didSet { traeObserver.isEnabled = traeEnabled; UserDefaults.standard.set(traeEnabled, forKey: "traeEnabled"); recalculateAggregatedState() } }
    @Published public var cursorState: AIState = .idle; @Published public var cursorDescription: String = "待命中"; @Published public var cursorNeedsAck: Bool = false
    @Published public var windsurfState: AIState = .idle; @Published public var windsurfDescription: String = "待命中"; @Published public var windsurfNeedsAck: Bool = false
    @Published public var traeState: AIState = .idle; @Published public var traeDescription: String = "待命中"; @Published public var traeNeedsAck: Bool = false
    public let cursorObserver = GenericProcessObserver(id: "cursor", displayName: "Cursor", iconName: "cursor", processNameKeywords: ["Cursor"])
    public let windsurfObserver = GenericProcessObserver(id: "windsurf", displayName: "Windsurf", iconName: "windsurf", processNameKeywords: ["Windsurf"])
    public let traeObserver = GenericProcessObserver(id: "trae", displayName: "Trae", iconName: "trae", processNameKeywords: ["Trae"])

    public var allObservers: [AIObserverItem] {
        var list: [AIObserverItem] = []
        list.append(AIObserverItem(id: "codex", name: "Codex", icon: "codex", isEnabled: codexEnabled, state: codexState, description: codexActionFeedback ?? codexDescription, actionDetail: codexActionDetail))
        list.append(AIObserverItem(id: "antigravity", name: "Antigravity", icon: "antigravity", isEnabled: antigravityEnabled, state: antigravityState, description: antigravityDescription, actionDetail: antigravityActionDetail))
        list.append(AIObserverItem(id: "claude", name: "Claude", icon: "claude", isEnabled: claudeEnabled, state: claudeState, description: claudeDescription, actionDetail: claudeActionDetail))
        list.append(AIObserverItem(id: "cursor", name: "Cursor", icon: "cursor", isEnabled: cursorEnabled, state: cursorState, description: cursorDescription))
        list.append(AIObserverItem(id: "windsurf", name: "Windsurf", icon: "windsurf", isEnabled: windsurfEnabled, state: windsurfState, description: windsurfDescription))
        list.append(AIObserverItem(id: "trae", name: "Trae", icon: "trae", isEnabled: traeEnabled, state: traeState, description: traeDescription))
        
        list.sort { a, b in
            let idxA = observerOrder.firstIndex(of: a.id) ?? 999
            let idxB = observerOrder.firstIndex(of: b.id) ?? 999
            return idxA < idxB
        }
        return list
    }

    public var displayedObservers: [AIObserverItem] {
        let list = allObservers.filter { $0.isEnabled }
        if testModeActive {
            return list
        }
        switch hudDisplayMode {
        case .always:
            return list
        case .whenActive:
            let active = list.filter { $0.state != .idle }
            return active.isEmpty ? [] : active
        case .onlyAwaitingInput:
            return list.filter { $0.state == .awaitingInput }
        }
    }

    private var previousState: AIState = .idle

    public init() {
        // Load settings
        if UserDefaults.standard.object(forKey: "isHUDEnabled") != nil {
            self.isHUDEnabled = UserDefaults.standard.bool(forKey: "isHUDEnabled")
        }
        
        if let modeStr = UserDefaults.standard.string(forKey: "hudLayoutMode"), let mode = HUDLayoutMode(rawValue: modeStr) {
            self.hudLayoutMode = mode
        }
        
        if let order = UserDefaults.standard.stringArray(forKey: "observerOrder"), !order.isEmpty {
            self.observerOrder = order
        }
        
        if let detailStr = UserDefaults.standard.string(forKey: "hudDetailMode"), let detail = HUDDetailMode(rawValue: detailStr) {
            self.hudDetailMode = detail
        }

        if let modeStr = UserDefaults.standard.string(forKey: "hudDisplayMode"),
           let mode = HUDDisplayMode(rawValue: modeStr) {
            self.hudDisplayMode = mode
        }
        if UserDefaults.standard.object(forKey: "showMenuBarIcon") != nil {
            self.showMenuBarIcon = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        }
        if UserDefaults.standard.object(forKey: "showMenuBarDot") != nil {
            self.showMenuBarDot = UserDefaults.standard.bool(forKey: "showMenuBarDot")
        }
        if UserDefaults.standard.object(forKey: "showMenuBarText") != nil {
            self.showMenuBarText = UserDefaults.standard.bool(forKey: "showMenuBarText")
        }
        if UserDefaults.standard.object(forKey: "soundAlertEnabled") != nil {
            self.soundAlertEnabled = UserDefaults.standard.bool(forKey: "soundAlertEnabled")
        }
        if UserDefaults.standard.object(forKey: "hudOpacity") != nil {
            self.hudOpacity = UserDefaults.standard.double(forKey: "hudOpacity")
        }
        if let themeStr = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: themeStr) {
            self.appTheme = theme
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NSApp.appearance = self.appTheme.nsAppearance
        }

        if UserDefaults.standard.object(forKey: "showHUDGlow") != nil {
            self.showHUDGlow = UserDefaults.standard.bool(forKey: "showHUDGlow")
        }
        if UserDefaults.standard.object(forKey: "prominentMenuBarPill") != nil {
            self.prominentMenuBarPill = UserDefaults.standard.bool(forKey: "prominentMenuBarPill")
        }
        if UserDefaults.standard.object(forKey: "codexEnabled") != nil {
            self.codexEnabled = UserDefaults.standard.bool(forKey: "codexEnabled")
        }
        if UserDefaults.standard.object(forKey: "antigravityEnabled") != nil {
            self.antigravityEnabled = UserDefaults.standard.bool(forKey: "antigravityEnabled")
        }
        if UserDefaults.standard.object(forKey: "claudeEnabled") != nil {
            self.claudeEnabled = UserDefaults.standard.bool(forKey: "claudeEnabled")
        }

        codexObserver.isEnabled = self.codexEnabled
        codexObserver.delegate = self

        antigravityObserver.isEnabled = self.antigravityEnabled
        antigravityObserver.delegate = self

        claudeObserver.isEnabled = self.claudeEnabled
        claudeObserver.delegate = self

        
        if let v = UserDefaults.standard.object(forKey: "cursorEnabled") as? Bool { self.cursorEnabled = v }
        if let v = UserDefaults.standard.object(forKey: "windsurfEnabled") as? Bool { self.windsurfEnabled = v }
        if let v = UserDefaults.standard.object(forKey: "traeEnabled") as? Bool { self.traeEnabled = v }
        cursorObserver.isEnabled = self.cursorEnabled; cursorObserver.delegate = self; cursorObserver.startObserving()
        windsurfObserver.isEnabled = self.windsurfEnabled; windsurfObserver.delegate = self; windsurfObserver.startObserving()
        traeObserver.isEnabled = self.traeEnabled; traeObserver.delegate = self; traeObserver.startObserving()

        codexObserver.startObserving()
        antigravityObserver.startObserving()
        claudeObserver.startObserving()

        // Auto-detect when user switches to an AI app and auto-acknowledge completed tasks
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.checkFrontmostAppAndAutoAcknowledge(app: app) }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            FloatingHUDWindowController.shared.setup(with: self)
            StatusItemPopoverController.shared.setup(with: self)
        }
    }

    var lastAcknowledgedDates: [String: Date] = [:]

    private func isAppActive(name: String, bundleId: String, for observerId: String) -> Bool {
        switch observerId {
        case "antigravity":
            return name.localizedCaseInsensitiveContains("Antigravity") ||
                   bundleId.localizedCaseInsensitiveContains("antigravity")
        case "codex":
            return name.localizedCaseInsensitiveContains("Codex") ||
                   name.localizedCaseInsensitiveContains("ChatGPT") ||
                   bundleId.localizedCaseInsensitiveContains("openai") ||
                   bundleId.localizedCaseInsensitiveContains("codex") ||
                   name.localizedCaseInsensitiveContains("Terminal") ||
                   name.localizedCaseInsensitiveContains("iTerm")
        case "claude":
            return name.localizedCaseInsensitiveContains("Claude") ||
                   bundleId.localizedCaseInsensitiveContains("anthropic") ||
                   bundleId.localizedCaseInsensitiveContains("claude") ||
                   name.localizedCaseInsensitiveContains("Terminal") ||
                   name.localizedCaseInsensitiveContains("iTerm") ||
                   bundleId.localizedCaseInsensitiveContains("cursor") ||
                   bundleId.localizedCaseInsensitiveContains("vscode") ||
                   name.localizedCaseInsensitiveContains("Code")
        default:
            return false
        }
    }

    public func checkFrontmostAppAndAutoAcknowledge(app: NSRunningApplication? = nil) {
        let front = app ?? NSWorkspace.shared.frontmostApplication
        guard let front = front else { return }
        let name = front.localizedName ?? ""
        let bundleId = front.bundleIdentifier ?? ""

        if antigravityNeedsAck && isAppActive(name: name, bundleId: bundleId, for: "antigravity") {
            acknowledgeAntigravity()
        }
        if codexNeedsAck && isAppActive(name: name, bundleId: bundleId, for: "codex") {
            acknowledgeCodex()
        }
        if claudeNeedsAck && isAppActive(name: name, bundleId: bundleId, for: "claude") {
            acknowledgeClaude()
        }
    }

}
