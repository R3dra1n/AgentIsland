import Foundation
import SwiftUI
import Combine
import os.log
import AppKit

private let logger = Logger(subsystem: "io.github.r3dra1n.AgentIsland", category: "AppState")


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
    /// Closed capsule shows each assistant's icon (tinted by its state) instead of a dot.
    @Published public var hudShowsIcons: Bool = false {
        didSet { UserDefaults.standard.set(hudShowsIcons, forKey: "hudShowsIcons") }
    }
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
    @Published var antigravitySessionFeedback: [String: String] = [:]
    @Published var antigravityAcknowledgedSessions: [String: Date] = [:]
    /// Every Claude Code conversation that currently has something to show. The
    /// HUD gets one row per conversation once there is more than one.
    @Published var claudeSessions: [ClaudeSessionSnapshot] = []
    /// The conversation the provider-level Claude state was last about. A
    /// finished conversation leaves `claudeSessions` after a couple of minutes,
    /// but its "done" stays on screen until it is seen, and the row still has
    /// to know where to go when it is clicked.
    var lastKnownClaudeSession: ClaudeSessionSnapshot?
    /// Multiple-choice questions Claude Code is waiting on that the island can
    /// answer (see `ClaudeAnswerStore`). Empty unless the hook helper is installed.
    @Published var claudeAnswerRequests: [ClaudeAnswerRequest] = []
    /// Requests already answered here: hidden until their file is gone, so a
    /// second click cannot send a second answer.
    var claudeAnsweredRequestIDs: Set<String> = []
    var claudeAnswerDirectory: URL = ClaudeAnswerStore.defaultDirectory
    var claudeAnswerTimer: Timer?
    /// When the island itself last took the user to a Claude conversation. The
    /// app it brings forward announces its own activation a moment later, and
    /// that is not the user switching over to look at everything it hosts.
    var claudeOpenedByIslandAt: Date?
    @Published var claudeAcknowledgedSessions: [String: Date] = [:] {
        didSet { Self.persistMarks(claudeAcknowledgedSessions, key: "claudeAcknowledgedSessions") }
    }
    /// Every Codex conversation that currently has something to show; one row
    /// each once there is more than one, as for Claude.
    @Published var codexSessions: [CodexSessionSnapshot] = []
    @Published var codexAcknowledgedSessions: [String: Date] = [:] {
        didSet { Self.persistMarks(codexAcknowledgedSessions, key: "codexAcknowledgedSessions") }
    }
    /// When the island itself last took the user to a Codex conversation (see
    /// `claudeOpenedByIslandAt`).
    var codexOpenedByIslandAt: Date?
    private var antigravityViewedMonitor: AntigravityViewedMonitor?
    @Published var antigravityPreparedQuestions: [String: AntigravityPreparedQuestion] = [:]
    @Published var antigravityPrevalidationEnabled = false

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

    static let antigravitySessionPrefix = "antigravity-session:"
    private var antigravitySessionLabels: [String: Int] = [:]
    static let claudeSessionPrefix = "claude-session:"
    private var claudeSessionLabels: [String: Int] = [:]
    static let codexSessionPrefix = "codex-session:"
    private var codexSessionLabels: [String: Int] = [:]

    static let overflowPrefix = "overflow:"
    /// Conversations beyond this many per assistant fold into one "+N" chip, so
    /// the HUD cannot grow without bound however many conversations are open.
    static let maximumRowsPerProvider = 3

    struct SessionRows: Equatable {
        var rows: [AIObserverItem]
        var hidden: [AIObserverItem]
    }

    /// A conversation has a row of its own only while there is something to look
    /// at. One that is idle, or finished and already viewed, is history: it goes
    /// back into its assistant's single icon instead of sitting there as a grey
    /// row, which is what made the HUD grow with every conversation ever opened.
    static func needsAttention(_ state: AIState) -> Bool { state != .idle && state != .unknown }

    /// Chooses which conversations are shown. `all` holds one row per known
    /// conversation, with viewed ones already reported as idle.
    ///
    /// - Nothing needs attention: the plain provider row.
    /// - Exactly one: `soloKeepsProviderRow` decides between the provider row
    ///   and that conversation's own row under the provider's plain name.
    /// - Several: one row each, in their stable order, up to `limit`.
    /// - More than `limit`: the most pressing keep their rows and the rest fold
    ///   into a "+N" chip that takes the colour of the worst state it hides.
    static func arrangeSessionRows(provider: AIObserverItem, all: [AIObserverItem], soloKeepsProviderRow: Bool,
                                   limit: Int = maximumRowsPerProvider) -> SessionRows {
        let attention = all.filter { needsAttention($0.state) }
        if attention.isEmpty || (attention.count == 1 && soloKeepsProviderRow) {
            return SessionRows(rows: [provider], hidden: [])
        }
        guard attention.count > limit else {
            var rows = attention
            if rows.count == 1 { rows[0].name = provider.name }
            return SessionRows(rows: rows, hidden: [])
        }
        // Rank by how much the user is needed, then by the stable order, but show
        // the survivors in the stable order so rows do not jump around.
        let ranked = attention.enumerated().sorted { lhs, rhs in
            lhs.element.state != rhs.element.state ? lhs.element.state > rhs.element.state : lhs.offset < rhs.offset
        }
        let kept = Set(ranked.prefix(limit).map(\.offset))
        let shown = attention.enumerated().filter { kept.contains($0.offset) }.map(\.element)
        let hidden = attention.enumerated().filter { !kept.contains($0.offset) }.map(\.element)
        let chip = AIObserverItem(id: overflowPrefix + provider.id, name: "+\(hidden.count)", icon: provider.icon,
                                  isEnabled: provider.isEnabled, state: hidden.map(\.state).max() ?? .idle,
                                  description: "另有 \(hidden.count) 个会话")
        return SessionRows(rows: shown + [chip], hidden: hidden)
    }

    /// Opening a finished conversation makes its host app rewrite the file the
    /// "last active" time comes from, a few seconds after the "viewed" mark was
    /// taken. Without a margin that rewrite made a conversation the user had
    /// just looked at count as new again, and it came back as "done" the next
    /// time anything else refreshed the state.
    nonisolated static let viewedGrace: TimeInterval = 15

    nonisolated static func viewMarkCovers(acknowledgedAt: Date?, finishedAt: Date?) -> Bool {
        guard let acknowledgedAt, let finishedAt else { return false }
        return acknowledgedAt.addingTimeInterval(viewedGrace) >= finishedAt
    }

    private static func isViewed(completedAt: Date?, lastActive: Date?, state: AIState, acknowledged: [String: Date], id: String) -> Bool {
        state == .completed && viewMarkCovers(acknowledgedAt: acknowledged[id], finishedAt: completedAt ?? lastActive)
    }

    /// Codex's conversations as rows. A finished one is viewed when its own
    /// mark covers it, or when the provider-level mark does: that one is the
    /// only record there was before conversations had rows, and without it
    /// every conversation finished earlier today would come back as "done".
    /// Keeps the number a visible conversation already has, drops the numbers of
    /// the ones that are gone, and gives each new one the smallest number free.
    /// `visible` is oldest first.
    static func assignCodexLabels(existing: [String: Int], visible: [String]) -> [String: Int] {
        var labels = existing.filter { visible.contains($0.key) }
        for id in visible where labels[id] == nil {
            let taken = Set(labels.values)
            labels[id] = (1...).first { !taken.contains($0) }
        }
        return labels
    }

    static func codexSessionIsViewed(_ session: CodexSessionSnapshot, acknowledged: [String: Date], providerAcknowledgedAt: Date?) -> Bool {
        guard session.state == .completed else { return false }
        let finished = session.completedAt ?? session.lastActiveDate
        return viewMarkCovers(acknowledgedAt: acknowledged[session.id], finishedAt: finished)
            || viewMarkCovers(acknowledgedAt: providerAcknowledgedAt, finishedAt: finished)
    }

    static func codexArrangement(_ provider: AIObserverItem, sessions: [CodexSessionSnapshot], labels: [String: Int],
                                 acknowledged: [String: Date], providerAcknowledgedAt: Date?) -> SessionRows {
        let all = sessions.sorted { (labels[$0.id] ?? .max) < (labels[$1.id] ?? .max) }.map { session -> AIObserverItem in
            let viewed = codexSessionIsViewed(session, acknowledged: acknowledged, providerAcknowledgedAt: providerAcknowledgedAt)
            return AIObserverItem(id: codexSessionPrefix + session.id, name: "Codex · 会话 \(labels[session.id] ?? 0)",
                icon: "codex", isEnabled: provider.isEnabled, state: viewed ? .idle : session.state,
                description: viewed ? "待命中" : session.description, actionDetail: session.actionDetail)
        }
        // One conversation keeps the plain provider row, with everything the
        // provider row does (answering requests included).
        return arrangeSessionRows(provider: provider, all: all, soloKeepsProviderRow: true)
    }

    static func expandCodexSessions(_ providers: [AIObserverItem], sessions: [CodexSessionSnapshot], labels: [String: Int],
                                    acknowledged: [String: Date], providerAcknowledgedAt: Date?) -> [AIObserverItem] {
        providers.flatMap { provider in
            guard provider.id == "codex", !sessions.isEmpty else { return [provider] }
            return codexArrangement(provider, sessions: sessions, labels: labels, acknowledged: acknowledged,
                                    providerAcknowledgedAt: providerAcknowledgedAt).rows
        }
    }

    static func claudeArrangement(_ provider: AIObserverItem, sessions: [ClaudeSessionSnapshot], labels: [String: Int],
                                  acknowledged: [String: Date]) -> SessionRows {
        let all = sessions.sorted { (labels[$0.id] ?? .max) < (labels[$1.id] ?? .max) }.map { session -> AIObserverItem in
            let viewed = isViewed(completedAt: session.completedAt, lastActive: session.lastActiveDate, state: session.state,
                                  acknowledged: acknowledged, id: session.id)
            return AIObserverItem(id: claudeSessionPrefix + session.id, name: "Claude · 会话 \(labels[session.id] ?? 0)",
                icon: "claude", isEnabled: provider.isEnabled, state: viewed ? .idle : session.state,
                description: viewed ? "待命中" : session.description, actionDetail: session.actionDetail)
        }
        // A single conversation keeps the plain provider row, so people who only
        // ever run one see no change.
        return arrangeSessionRows(provider: provider, all: all, soloKeepsProviderRow: true)
    }

    static func expandClaudeSessions(_ providers: [AIObserverItem], sessions: [ClaudeSessionSnapshot],
                                     labels: [String: Int], acknowledged: [String: Date] = [:]) -> [AIObserverItem] {
        providers.flatMap { provider in
            guard provider.id == "claude", !sessions.isEmpty else { return [provider] }
            return claudeArrangement(provider, sessions: sessions, labels: labels, acknowledged: acknowledged).rows
        }
    }

    static func antigravityArrangement(_ provider: AIObserverItem, sessions: [AntigravitySessionSnapshot],
                                       feedback: [String: String], labels: [String: Int],
                                       acknowledged: [String: Date]) -> SessionRows {
        let all = sessions.sorted { (labels[$0.id] ?? .max) < (labels[$1.id] ?? .max) }.map { session -> AIObserverItem in
            let viewed = isViewed(completedAt: session.completedAt, lastActive: session.lastActiveDate, state: session.state,
                                  acknowledged: acknowledged, id: session.id)
            return AIObserverItem(id: antigravitySessionPrefix + session.id, name: "Antigravity · 会话 \(labels[session.id] ?? 0)",
                icon: "antigravity", isEnabled: provider.isEnabled, state: viewed ? .idle : session.state,
                description: viewed ? "待命中" : (session.state == .awaitingInput ? (feedback[session.id] ?? session.description) : session.description),
                actionDetail: session.actionDetail)
        }
        // Antigravity answers are bound to a specific conversation, so even a
        // lone one keeps its own row (under the plain name) and its reply path.
        return arrangeSessionRows(provider: provider, all: all, soloKeepsProviderRow: false)
    }

    static func expandAntigravitySessions(_ providers: [AIObserverItem], sessions: [AntigravitySessionSnapshot],
                                          feedback: [String: String], labels: [String: Int],
                                          acknowledged: [String: Date] = [:]) -> [AIObserverItem] {
        providers.flatMap { provider in
            guard provider.id == "antigravity", !sessions.isEmpty else { return [provider] }
            return antigravityArrangement(provider, sessions: sessions, feedback: feedback, labels: labels,
                                          acknowledged: acknowledged).rows
        }
    }

    /// The conversations folded into an assistant's "+N" chip, for its list.
    func hiddenSessionRows(for providerID: String) -> [AIObserverItem] {
        guard let provider = allObservers.first(where: { $0.id == providerID && $0.isEnabled }) else { return [] }
        switch providerID {
        case "claude":
            return Self.claudeArrangement(provider, sessions: claudeSessions, labels: claudeSessionLabels,
                                          acknowledged: claudeAcknowledgedSessions).hidden
        case "codex":
            return Self.codexArrangement(provider, sessions: codexSessions, labels: codexSessionLabels,
                                         acknowledged: codexAcknowledgedSessions,
                                         providerAcknowledgedAt: lastAcknowledgedDates["codex"]).hidden
        case "antigravity":
            return Self.antigravityArrangement(provider, sessions: antigravityObserver.sessions,
                                               feedback: antigravitySessionFeedback, labels: antigravitySessionLabels,
                                               acknowledged: antigravityAcknowledgedSessions).hidden
        default:
            return []
        }
    }

    public var displayedObservers: [AIObserverItem] {
        let providers = allObservers.filter { $0.isEnabled }
        if testModeActive {
            return providers
        }
        let sessions = antigravityObserver.sessions
        for session in sessions where antigravitySessionLabels[session.id] == nil {
            antigravitySessionLabels[session.id] = antigravitySessionLabels.count + 1
        }
        for session in claudeSessions where claudeSessionLabels[session.id] == nil {
            claudeSessionLabels[session.id] = claudeSessionLabels.count + 1
        }
        // Numbered only while a conversation has something to show, and the
        // number is given back afterwards: a day of finished, long-viewed
        // conversations would otherwise leave the two rows on screen as
        // "会话 5" and "会话 6".
        codexSessionLabels = Self.assignCodexLabels(
            existing: codexSessionLabels,
            visible: codexSessions.filter {
                !Self.codexSessionIsViewed($0, acknowledged: codexAcknowledgedSessions, providerAcknowledgedAt: lastAcknowledgedDates["codex"])
            }.map(\.id))
        let list = Self.expandCodexSessions(
            Self.expandClaudeSessions(
                Self.expandAntigravitySessions(providers, sessions: sessions, feedback: antigravitySessionFeedback,
                                               labels: antigravitySessionLabels, acknowledged: antigravityAcknowledgedSessions),
                sessions: claudeSessions, labels: claudeSessionLabels, acknowledged: claudeAcknowledgedSessions),
            sessions: codexSessions, labels: codexSessionLabels, acknowledged: codexAcknowledgedSessions,
            providerAcknowledgedAt: lastAcknowledgedDates["codex"])
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
        PreferenceMigration.runForCurrentApp()
        // Load settings
        self.claudeAcknowledgedSessions = UserDefaults.standard.dictionary(forKey: "claudeAcknowledgedSessions") as? [String: Date] ?? [:]
        self.codexAcknowledgedSessions = UserDefaults.standard.dictionary(forKey: "codexAcknowledgedSessions") as? [String: Date] ?? [:]
        self.lastAcknowledgedDates = UserDefaults.standard.dictionary(forKey: "lastAcknowledgedDates") as? [String: Date] ?? [:]
        self.antigravityAcknowledgedSessions = UserDefaults.standard.dictionary(forKey: "antigravityAcknowledgedSessions") as? [String: Date] ?? [:]
        self.antigravityPrevalidationEnabled = UserDefaults.standard.bool(forKey: "antigravityPrevalidationEnabled") && UserDefaults.standard.bool(forKey: "antigravityLocalReplyConsent")
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
        self.hudShowsIcons = UserDefaults.standard.bool(forKey: "hudShowsIcons")
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

        let viewedMonitor = AntigravityViewedMonitor(state: self)
        self.antigravityViewedMonitor = viewedMonitor
        viewedMonitor.start()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            FloatingHUDWindowController.shared.setup(with: self)
            StatusItemPopoverController.shared.setup(with: self)
            // Only the running app answers Claude's questions; a test process
            // building an AppState must not tell the real hook helper someone is there.
            if NSClassFromString("XCTestCase") == nil { self.startClaudeAnswering() }
        }
    }

    /// When the user last dealt with each assistant as a whole. Kept across
    /// restarts: kept only in memory, a restart made everything the user had
    /// already viewed (a Codex task, say) show up as newly finished.
    var lastAcknowledgedDates: [String: Date] = [:] {
        didSet { Self.persistMarks(lastAcknowledgedDates, key: "lastAcknowledgedDates") }
    }

    /// How long a result that arrives while the user is already in that app
    /// stays visible before it counts as seen. Marking it at once (1.3.7) meant
    /// the island never showed "done" at all for someone watching the task.
    nonisolated static let completionShownFor: TimeInterval = 4
    private var seenWhileInFrontTask: Task<Void, Never>?
    var lastLoggedObserverState: [String: AIState] = [:]

    /// Let a fresh result show for a moment, then count it as seen if the user
    /// is still in that app. Leaving in between keeps it pending.
    func scheduleSeenWhileInFrontCheck() {
        guard seenWhileInFrontTask == nil else { return }
        seenWhileInFrontTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.completionShownFor * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.seenWhileInFrontTask = nil
            self.checkFrontmostAppAndAutoAcknowledge(finishedJustNow: true)
        }
    }

    /// Saves a "viewed" mark table, dropping the oldest marks so it cannot grow
    /// without bound (one entry per conversation ever seen).
    nonisolated static func persistMarks(_ marks: [String: Date], key: String, limit: Int = 300) {
        let kept = marks.count > limit
            ? Dictionary(uniqueKeysWithValues: marks.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) })
            : marks
        UserDefaults.standard.set(kept, forKey: key)
    }

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

    /// Codex's own desktop app. A terminal also counts when the user *switches*
    /// to it, but a task finishing while a terminal happens to be in front says
    /// nothing about the user looking at Codex.
    nonisolated static func isCodexDesktop(name: String, bundleId: String) -> Bool {
        name.localizedCaseInsensitiveContains("Codex") || name.localizedCaseInsensitiveContains("ChatGPT")
            || bundleId.localizedCaseInsensitiveContains("openai") || bundleId.localizedCaseInsensitiveContains("codex")
    }

    /// `finishedJustNow` is for a result that arrives while the user is already
    /// in some app: no activation event follows, so without this check a task
    /// that finished in front of the user stayed "done" until they switched
    /// away and back.
    public func checkFrontmostAppAndAutoAcknowledge(app: NSRunningApplication? = nil, finishedJustNow: Bool = false) {
        let front = app ?? NSWorkspace.shared.frontmostApplication
        guard let front = front else { return }
        let name = front.localizedName ?? ""
        let bundleId = front.bundleIdentifier ?? ""

        // Antigravity needs per-conversation confirmation; merely switching
        // to its app must not acknowledge unrelated completed sessions.
        let codexInFront = finishedJustNow ? Self.isCodexDesktop(name: name, bundleId: bundleId)
                                           : isAppActive(name: name, bundleId: bundleId, for: "codex")
        // Not when the island itself brought Codex forward to open one
        // conversation: that one is marked by `noteCodexConversationOpened`, and
        // the others have not been looked at.
        if codexNeedsAck && codexInFront && !Self.isOwnActivation(openedAt: codexOpenedByIslandAt, now: Date()) {
            acknowledgeCodex()
        }
        // Claude: switching to the app a finished conversation runs in is
        // looking at it. This is decided per conversation: the provider-level
        // flag is false whenever another conversation is still running, which
        // used to leave a finished one waiting for a click.
        acknowledgeClaudeConversationsViewedByActivating(frontName: name, frontBundle: bundleId, now: Date())
        if claudeSessions.isEmpty, claudeNeedsAck, !finishedJustNow, isAppActive(name: name, bundleId: bundleId, for: "claude") {
            acknowledgeClaude()
        }
    }

    /// How long after the island opens a conversation the host app's activation
    /// is taken to be the island's own doing. Long enough for an app that has to
    /// be launched first.
    nonisolated static let ownActivationWindow: TimeInterval = 6

    nonisolated static func isOwnActivation(openedAt: Date?, now: Date) -> Bool {
        guard let openedAt else { return false }
        let elapsed = now.timeIntervalSince(openedAt)
        return elapsed >= 0 && elapsed <= ownActivationWindow
    }

    /// The user switching to the app a finished conversation runs in is looking
    /// at it. Not when the island did the switching to open one particular
    /// conversation: that one is marked by `noteClaudeConversationOpened`, and the
    /// others, which nobody has looked at, stay as they are.
    func acknowledgeClaudeConversationsViewedByActivating(frontName: String, frontBundle: String, now: Date,
                                                          focusedDesktopTranscript: () -> String? = { AppState.claudeDesktopFocusedTranscript() }) {
        guard !Self.isOwnActivation(openedAt: claudeOpenedByIslandAt, now: now) else { return }
        // The desktop app records which conversation the user last focused, so a
        // conversation that finished behind the one on screen is not "seen".
        // Read only when it matters: some finished desktop conversation waits.
        let desktopFront = frontBundle.localizedCaseInsensitiveContains("anthropic") || frontName.localizedCaseInsensitiveContains("Claude")
        let waiting = claudeSessions.contains { $0.state == .completed && ($0.entrypoint ?? "").localizedCaseInsensitiveContains("desktop") }
        let focused = desktopFront && waiting ? focusedDesktopTranscript() : nil
        for id in Self.claudeSessionsViewedByActivating(sessions: claudeSessions, acknowledged: claudeAcknowledgedSessions,
                                                        frontName: frontName, frontBundle: frontBundle,
                                                        focusedDesktopTranscript: focused) {
            acknowledgeClaudeSession(id)
        }
    }

    /// The conversation the desktop app has on screen: the one it recorded as
    /// focused most recently, as the id its transcript carries. The app rewrites
    /// a conversation's file when it is focused, so the newest few files are
    /// enough; only the focus time and the two ids are read. Nil when nothing
    /// can be told, in which case every finished conversation the app hosts
    /// counts, as it did before this was known.
    nonisolated static func claudeDesktopFocusedTranscript(root: URL = claudeDesktopSessionsRoot, newest: Int = 16) -> String? {
        let fm = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((file, modified))
                }
            }
        }
        var best: (id: String, focusedAt: Double)?
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(newest) {
            guard let data = try? Data(contentsOf: file.url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["isArchived"] as? Bool != true,
                  let cli = object["cliSessionId"] as? String, !cli.isEmpty,
                  let focusedAt = (object["lastFocusedAt"] as? NSNumber)?.doubleValue, focusedAt > 0 else { continue }
            if best == nil || focusedAt > best!.focusedAt { best = (cli, focusedAt) }
        }
        return best?.id
    }

    /// Finished, not yet viewed Claude conversations that the activated app is
    /// the host of: the desktop app for conversations started there, a terminal
    /// or editor for the rest. A terminal or editor does not say which
    /// conversation is on screen, so every finished one it hosts counts; the
    /// desktop app does (`focusedDesktopTranscript`), and then only that one does.
    nonisolated static func claudeSessionsViewedByActivating(sessions: [ClaudeSessionSnapshot], acknowledged: [String: Date],
                                                             frontName: String, frontBundle: String,
                                                             focusedDesktopTranscript: String? = nil) -> [String] {
        let desktopFront = frontBundle.localizedCaseInsensitiveContains("anthropic") || frontName.localizedCaseInsensitiveContains("Claude")
        let terminalFront = !desktopFront && (frontName.localizedCaseInsensitiveContains("Terminal") || frontName.localizedCaseInsensitiveContains("iTerm")
            || frontName.localizedCaseInsensitiveContains("Ghostty") || frontName.localizedCaseInsensitiveContains("Warp")
            || frontBundle.localizedCaseInsensitiveContains("cursor") || frontBundle.localizedCaseInsensitiveContains("vscode")
            || frontName.localizedCaseInsensitiveContains("Code"))
        guard desktopFront || terminalFront else { return [] }
        return sessions.compactMap { session in
            guard session.state == .completed else { return nil }
            let finished = session.completedAt ?? session.lastActiveDate
            if let finished, (acknowledged[session.id] ?? .distantPast) >= finished { return nil }
            let onDesktop = (session.entrypoint ?? "").localizedCaseInsensitiveContains("desktop")
            guard onDesktop == desktopFront else { return nil }
            // With the desktop app in front and the conversation on screen
            // known, only that one is being looked at.
            if desktopFront, let focused = focusedDesktopTranscript, session.id != focused { return nil }
            return session.id
        }
    }

}
