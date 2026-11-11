import SwiftUI

/// The floating HUD: one black capsule that morphs between a small pill of
/// status dots and an open list of rows. Which rows exist is decided by
/// `AppState.displayedObservers` (see `docs/hud-session-rows.md`); this view only
/// draws them. The look and motion numbers are in `HUDStyle`.
public struct FloatingHUDView: View {
    @ObservedObject var appState: AppState
    /// Tapped open by the user while nothing needs them. Closes again on a second
    /// tap, or by itself once something does need them and then is dealt with.
    @State private var manuallyOpen = false
    /// What is drawn. It follows the wanted state one beat later when opening, so
    /// the window has already grown and the first frames are not torn.
    @State private var shownOpen = false
    /// Attention the user has already collapsed the capsule on. The capsule
    /// stays shut for these and opens again only for something new.
    @State private var dismissedAttention: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onContentSizeChange: (CGSize) -> Void
    /// What a click on a row's light does. Opens the conversation unless a
    /// caller (a test, which must not open real windows) says otherwise.
    private let onFocusRow: (AIObserverItem) -> Void

    public init(appState: AppState, onContentSizeChange: @escaping (CGSize) -> Void = { _ in },
                onFocusRow: ((AIObserverItem) -> Void)? = nil) {
        self.appState = appState
        self.onContentSizeChange = onContentSizeChange
        self.onFocusRow = onFocusRow ?? { appState.focusSession($0) }
    }

    private var itemsToShow: [AIObserverItem] {
        return appState.displayedObservers
    }

    @ViewBuilder
    private func segment(_ item: AIObserverItem) -> some View {
        if item.id.hasPrefix(AppState.overflowPrefix) {
            OverflowChipView(appState: appState, item: item)
        } else {
            sessionSegment(item)
        }
    }

    @ViewBuilder
    private func sessionSegment(_ item: AIObserverItem) -> some View {
        let claudeSessionRow = item.id.hasPrefix(AppState.claudeSessionPrefix)
        let codexSessionRow = item.id.hasPrefix(AppState.codexSessionPrefix)
        let provider = item.icon == "antigravity" ? "antigravity" : (claudeSessionRow ? "claude" : (codexSessionRow ? "codex" : item.id))
        let sessionRow = item.id.hasPrefix(AppState.antigravitySessionPrefix)
        AISegmentView(appState: appState, item: item,
            // A blind keystroke cannot be aimed at the right Claude Code
            // conversation, nor choose one of its options, so Claude's rows
            // only bring the original window forward (the real app, outside
            // the demo/test mode) instead of approving by key press.
            onApprove: { claudeSessionRow ? appState.focusSession(item) : appState.approve(for: provider) },
            onReject: { claudeSessionRow ? appState.focusSession(item) : appState.reject(for: provider) },
            onFocus: { onFocusRow(item) },
            onAcknowledge: {
                if provider == "claude", claudeSessionRow {
                    appState.acknowledgeClaudeSession(String(item.id.dropFirst(AppState.claudeSessionPrefix.count)))
                }
                else if provider == "codex", codexSessionRow {
                    appState.acknowledgeCodexSession(String(item.id.dropFirst(AppState.codexSessionPrefix.count)))
                }
                else if provider == "codex" { appState.acknowledgeCodex() }
                else if provider == "antigravity", sessionRow {
                    appState.acknowledgeAntigravitySession(String(item.id.dropFirst(AppState.antigravitySessionPrefix.count)))
                }
                else if provider == "antigravity" { appState.acknowledgeAntigravity() }
                else if provider == "claude" { appState.acknowledgeClaude(reason: "island row button") }
            })
    }

    private var maximumOpenHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 200
    }

    public var body: some View {
        let items = itemsToShow
        let lights = HUDStyle.closedLights(items)
        let attention = HUDStyle.attentionKeys(items)
        let opensByItself = !attention.subtracting(dismissedAttention).isEmpty
        let targetOpen = opensByItself || manuallyOpen
        let isOpen = shownOpen
        let vertical = appState.hudLayoutMode == .vertical
        let closed = HUDStyle.closedCapsule(dots: lights.count, icons: appState.hudShowsIcons, vertical: vertical)
        let dominant = items.map(\.state).max() ?? .idle
        let capsule = HUDStyle.capsuleSize(isOpen: isOpen, rows: items.count, dots: lights.count, icons: appState.hudShowsIcons, vertical: vertical, maxOpenHeight: maximumOpenHeight)
        let targetCapsule = HUDStyle.capsuleSize(isOpen: targetOpen, rows: items.count, dots: lights.count, icons: appState.hudShowsIcons, vertical: vertical, maxOpenHeight: maximumOpenHeight)
        let openHeight = HUDStyle.openHeight(rows: items.count)
        let rowsNeedScroll = openHeight > capsule.height && isOpen
        let shape = RoundedRectangle(cornerRadius: isOpen ? HUDStyle.openCornerRadius : HUDStyle.closedCornerRadius, style: .continuous)
        let morph: Animation? = reduceMotion ? nil : HUDStyle.morph

        ZStack(alignment: .top) {
            // Closed layer: one dot per assistant.
            dotStack(vertical: vertical, spacing: appState.hudShowsIcons ? HUDStyle.iconSpacing : HUDStyle.dotSpacing) {
                ForEach(lights) { dot in
                    HUDDotView(state: dot.state, reduceMotion: reduceMotion, icon: appState.hudShowsIcons ? dot.icon : nil)
                        .help("\(dot.name)：\(dot.state.title)")
                        // An assistant arriving or leaving fades; it never slides
                        // the others sideways.
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: lights.map(\.id))
            .frame(width: closed.width, height: closed.height)
            .opacity(isOpen ? 0 : 1)
            .animation(reduceMotion ? nil : HUDStyle.dotsFade, value: isOpen)
            .allowsHitTesting(!isOpen)
            .accessibilityHidden(isOpen)

            // Open layer: laid out at its full size and revealed by the capsule
            // growing over it, so the rows never squash while it morphs.
            Group {
                if rowsNeedScroll {
                    ScrollView(.vertical, showsIndicators: false) { rowsStack(items) }
                } else {
                    rowsStack(items)
                }
            }
            .frame(width: HUDStyle.openWidth, height: rowsNeedScroll ? capsule.height : openHeight, alignment: .top)
            .scaleEffect(isOpen ? 1 : 0.94, anchor: .top)
            .opacity(isOpen ? 1 : 0)
            .animation(reduceMotion ? nil : HUDStyle.rowsFade(opening: isOpen), value: isOpen)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
        }
        .frame(width: capsule.width, height: capsule.height, alignment: .top)
        .background(
            shape
                .fill(Color.black.opacity(appState.hudOpacity))
                .shadow(color: .black.opacity(0.5), radius: 17, x: 0, y: 10)
        )
        .clipShape(shape)
        .overlay { if appState.showHUDGlow { HUDGlowView(state: dominant, shape: shape, reduceMotion: reduceMotion) } }
        .contentShape(shape)
        .onTapGesture {
            if opensByItself {
                // Close what opened by itself, and keep it closed for exactly
                // this attention; a new red or green row opens it again.
                dismissedAttention.formUnion(attention)
                manuallyOpen = false
            } else {
                manuallyOpen.toggle()
            }
        }
        #if AGENTISLAND_ISOLATED_PREVIEW
        .overlay(alignment: .bottom) {
            Text("隔离测试版").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow)
                .fixedSize().offset(y: 16).allowsHitTesting(false)
        }
        #endif
        .animation(morph, value: isOpen)
        .animation(morph, value: items.count)
        // Width changes from dots coming and going use a plain ease, not the
        // spring, whose overshoot made the dots wobble left and right.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: lights.count)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: appState.hudShowsIcons)
        .padding(HUDStyle.windowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu { contextMenuItems() }
        .onChange(of: opensByItself) { _, now in
            if !now { manuallyOpen = false }
        }
        .onChange(of: attention) { _, now in
            // Forget what is no longer there, so the next one is news again.
            dismissedAttention.formIntersection(now)
        }
        .onChange(of: HUDStyle.windowSize(for: targetCapsule), initial: true) { _, size in
            onContentSizeChange(size)
        }
        .task(id: targetOpen) {
            if reduceMotion || !targetOpen {
                shownOpen = targetOpen
            } else {
                try? await Task.sleep(for: .seconds(HUDStyle.windowGrowLead))
                if !Task.isCancelled { shownOpen = true }
            }
        }
    }

    @ViewBuilder
    private func dotStack<Content: View>(vertical: Bool, spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        if vertical { VStack(spacing: spacing, content: content) } else { HStack(spacing: spacing, content: content) }
    }

    private func rowsStack(_ items: [AIObserverItem]) -> some View {
        VStack(spacing: HUDStyle.rowSpacing) {
            ForEach(items) { item in
                segment(item)
                    .transition(.opacity)
            }
        }
        .padding(HUDStyle.containerPadding)
        .frame(width: HUDStyle.openWidth)
    }

    @ViewBuilder
    private func contextMenuItems() -> some View {
        Group {
            Button("打开设置面板 (Popover)") {
                StatusItemPopoverController.shared.togglePopover()
            }
            Divider()
            Toggle("始终显示灵动岛", isOn: Binding(
                get: { appState.hudDisplayMode == .always },
                set: { if $0 { appState.hudDisplayMode = .always } else { appState.hudDisplayMode = .whenActive } }
            ))
            Toggle("收起时显示图标", isOn: $appState.hudShowsIcons)
            Toggle("发光效果", isOn: $appState.showHUDGlow)
            Divider()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出 AgentIsland")
            }
        }
    }
}

/// A 10 pt status light. A running one breathes: opacity 1 → 0.45 and scale
/// 1 → 0.8 over 1.4 s, forever (held still under Reduce Motion).
struct HUDDotView: View {
    let state: AIState
    var reduceMotion: Bool = false
    /// Provider id ("codex", "claude", "antigravity") to draw its icon, tinted by
    /// the state, instead of a plain dot.
    var icon: String? = nil

    private var shouldPulse: Bool { state == .running && !reduceMotion }

    @ViewBuilder
    private var light: some View {
        if let icon {
            AIIconView(provider: icon, size: HUDStyle.iconSize, color: HUDStyle.light(for: state))
        } else {
            Circle()
                .fill(HUDStyle.light(for: state))
                .frame(width: HUDStyle.dotSize, height: HUDStyle.dotSize)
        }
    }

    var body: some View {
        // A running light breathes (opacity 1 -> 0.45, scale 1 -> 0.8). The
        // phase comes from the clock, and the timeline only ticks while running,
        // so a standby HUD does no work at all.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldPulse)) { context in
            let phase = shouldPulse ? HUDStyle.pulsePhase(at: context.date.timeIntervalSinceReferenceDate) : 0
            light
                .opacity(1 - (1 - HUDStyle.pulseOpacity) * phase)
                .scaleEffect(1 - (1 - HUDStyle.pulseScale) * CGFloat(phase))
        }
        .accessibilityLabel(state.title)
    }
}

/// Capsule button used on the HUD's rows. Primary (approve / open) is white with
/// black text, secondary (deny / mark viewed) is white at 14% with light text.
/// Built on a real `Button`, so keyboard focus and its ring keep working.
struct HUDPillButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(primary ? HUDStyle.primaryButtonText : HUDStyle.secondaryButtonText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(primary ? HUDStyle.primaryButtonFill : HUDStyle.secondaryButtonFill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension View {
    /// The row chrome: 52 pt tall, 15 pt corners, 12 pt side padding, a faint
    /// white fill (red when the row needs the user).
    /// Makes a row's light open its conversation. The hit area is a margin
    /// larger than the 10-16 pt drawing, which is hard to land on, and grows
    /// outward without moving anything: the margin is added and taken back, so
    /// the layout is the drawing's own size.
    @ViewBuilder
    func logoTapTarget(enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            self
                .padding(HUDStyle.logoHitMargin)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .padding(-HUDStyle.logoHitMargin)
                .help("点击图标打开对应会话")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "打开对应会话", action)
        } else {
            self
        }
    }

    func hudRowChrome(state: AIState) -> some View {
        self
            .padding(.horizontal, HUDStyle.rowHorizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: HUDStyle.rowHeight)
            .background(RoundedRectangle(cornerRadius: HUDStyle.rowCornerRadius, style: .continuous).fill(HUDStyle.rowFill(for: state)))
    }
}

/// The "+N" row for conversations that did not fit in an assistant's rows. Its
/// light takes the colour of the worst state it hides, so a conversation that
/// needs the user is never buried, and it opens a list of what it holds.
private struct OverflowChipView: View {
    @ObservedObject var appState: AppState
    let item: AIObserverItem
    @State private var showList = false

    private var providerID: String { String(item.id.dropFirst(AppState.overflowPrefix.count)) }

    var body: some View {
        HStack(spacing: HUDStyle.rowContentSpacing) {
            HUDDotView(state: item.state, icon: appState.hudShowsIcons ? providerID : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HUDStyle.nameColor)
                    .lineLimit(1)
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundColor(HUDStyle.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("查看") { showList.toggle() }
                .buttonStyle(HUDPillButtonStyle(primary: false))
                .popover(isPresented: $showList, arrowEdge: .bottom) {
                    OverflowSessionListView(appState: appState, providerID: providerID)
                }
        }
        .hudRowChrome(state: item.state)
        .help("\(item.description)，点击查看")
    }
}

private struct OverflowSessionListView: View {
    @ObservedObject var appState: AppState
    let providerID: String

    var body: some View {
        let rows = appState.hiddenSessionRows(for: providerID)
        VStack(alignment: .leading, spacing: 8) {
            Text("其余会话").font(.system(size: 12, weight: .bold))
            Divider()
            if rows.isEmpty {
                Text("没有其他需要注意的会话").font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.state.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text("\(row.state.title) · \(row.description)")
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if row.state == .completed {
                        Button("已查看") { appState.acknowledgeSessionRow(row) }
                            .controlSize(.mini).buttonStyle(.bordered)
                    } else if row.state == .awaitingInput {
                        // Answering needs the conversation's own panel, which a
                        // folded row does not have, so go to the original window.
                        Button("打开处理") { appState.focusSession(row) }
                            .controlSize(.mini).buttonStyle(.borderedProminent).tint(.red)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}

public struct AISegmentView: View {
    @ObservedObject var appState: AppState
    let item: AIObserverItem
    var onApprove: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onAcknowledge: (() -> Void)? = nil
    @State private var showDetail = false
    @State private var presentedSessionID: String?
    @State private var presentedIdentity: AntigravityPendingIdentity?
    @State private var presentedDetail: String?
    @State private var presentedQuestion: AntigravityQuestion?

    private var isAntigravity: Bool { item.icon == "antigravity" || item.id == "antigravity" }
    private var isClaudeSession: Bool { item.id.hasPrefix(AppState.claudeSessionPrefix) }
    /// Codex's own row, or one conversation's row of it. Both are answered the
    /// same way; a conversation's row lists only that conversation's requests.
    private var isCodex: Bool { item.id == "codex" || item.id.hasPrefix(AppState.codexSessionPrefix) }
    private var codexRowSessionID: String? {
        item.id.hasPrefix(AppState.codexSessionPrefix) ? String(item.id.dropFirst(AppState.codexSessionPrefix.count)) : nil
    }
    /// Any Claude row, per conversation or folded into one. Outside the demo
    /// the island can only open Claude for these, never answer on its behalf.
    private var isClaude: Bool { isClaudeSession || item.id == "claude" || item.icon == "claude" }
    private var opensHostToHandle: Bool { isClaude && !appState.testModeActive }
    private var rowSessionID: String? {
        guard item.id.hasPrefix(AppState.antigravitySessionPrefix) else { return nil }
        return String(item.id.dropFirst(AppState.antigravitySessionPrefix.count))
    }
    private var rowFeedback: String? {
        guard item.state == .awaitingInput else { return nil }
        return rowSessionID.flatMap { appState.antigravitySessionFeedback[$0] }
    }

    private func toggleDetail() {
        if !showDetail {
            presentedSessionID = nil; presentedIdentity = nil; presentedDetail = nil; presentedQuestion = nil
            if item.id.hasPrefix(AppState.antigravitySessionPrefix) {
                let id = String(item.id.dropFirst(AppState.antigravitySessionPrefix.count))
                presentedSessionID = id
                if let session = appState.antigravityObserver.sessions.first(where: { $0.id == id }),
                   let identity = session.pendingIdentity, let detail = session.actionDetail,
                   detail == item.actionDetail {
                    presentedSessionID = id; presentedIdentity = identity; presentedDetail = detail
                    appState.prepareAntigravityQuestion(forSession: id, expectedIdentity: identity, expectedDetail: detail)
                    // The background validation may already be complete before
                    // the popover exists. Bind it now instead of relying on a
                    // later SwiftUI change notification to enable the buttons.
                    presentedQuestion = appState.antigravityPreparedQuestions[id]?.question(matching: identity, detail: detail)
                }
            }
        }
        showDetail.toggle()
    }

    @ViewBuilder
    private func detailPopover(_ detail: String) -> some View {
        if isCodex {
            CodexRequestView(appState: appState, sessionID: codexRowSessionID, onDismiss: { showDetail = false })
        } else if item.id.hasPrefix(AppState.antigravitySessionPrefix) {
            let shown = presentedDetail ?? detail
            VStack(alignment: .leading, spacing: 5) {
                if let id = presentedSessionID, let identity = presentedIdentity,
                   let question = presentedQuestion, let frozenDetail = presentedDetail {
                    ActionDetailPopover(detail: shown, itemName: item.name, supportsFreeText: true,
                        onChoose: { index in
                            showDetail = false
                            appState.sendAntigravityOption(index, forSession: id, expectedIdentity: identity,
                                                          expectedDetail: frozenDetail, expectedQuestion: question)
                        }, onSend: { text, _ in
                            showDetail = false
                            appState.sendAntigravityText(text, forSession: id, expectedIdentity: identity,
                                                        expectedDetail: frozenDetail, expectedQuestion: question)
                        })
                } else {
                    ActionDetailPopover(detail: shown, itemName: item.name, supportsFreeText: false, showsDisabledActions: true, onChoose: nil, onSend: nil)
                    Text(presentedIdentity == nil ? "无法确认此会话的问题身份，请在 Antigravity 中处理。" : (rowFeedback ?? "正在验证此会话的问题…"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .onChange(of: presentedSessionID.flatMap { appState.antigravityPreparedQuestions[$0]?.question }, initial: true) { _, question in
                guard showDetail, presentedQuestion == nil, let id = presentedSessionID,
                      let identity = presentedIdentity, let detail = presentedDetail,
                      let prepared = appState.antigravityPreparedQuestions[id],
                      prepared.identity == identity, prepared.detail == detail, let question else { return }
                // Keep the first verified question for this panel open; a later
                // response can only pass if the controller revalidates it.
                presentedQuestion = question
            }
        } else if opensHostToHandle, let request = claudeAnswerRequest {
            ClaudeAnswerPopover(request: request, itemName: item.name) { index in
                showDetail = false
                appState.answerClaude(request, optionIndex: index)
            }
        } else if opensHostToHandle {
            VStack(alignment: .leading, spacing: 5) {
                ActionDetailPopover(detail: detail, itemName: item.name, supportsFreeText: false,
                                    showsDisabledActions: true, onChoose: nil, onSend: nil)
                Text("灵动岛没法替 Claude 点选项：按键选不了具体选项，还可能送到别的窗口。请点「打开处理」回到 Claude，在对应会话里回答。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text("要在灵动岛里直接选，需要安装 Claude Hook（设置 → 可选 Hook），且只支持单选的单个问题。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        } else {
            ActionDetailPopover(detail: detail, itemName: item.name, supportsFreeText: true,
                onChoose: item.id == "antigravity" ? { appState.sendAntigravityOption($0) } : nil,
                onSend: { text, prefix in
                    showDetail = false
                    appState.sendTextInput(for: item.id, text: text, prefixKey: prefix)
                })
        }
    }

    /// The one line under the name. Full mode keeps the assistant's own wording
    /// (the first line of the question while it waits); concise mode shows only
    /// the state, or the reply feedback that replaces it.
    private var secondaryText: String {
        if let feedback = rowFeedback { return feedback }
        if isCodex, item.state == .awaitingInput, let feedback = appState.codexActionFeedback, !feedback.isEmpty {
            return feedback
        }
        if appState.hudDetailMode == .full {
            if let detail = item.actionDetail, item.state == .awaitingInput {
                return detail.components(separatedBy: "\n").first ?? detail
            }
            return item.description
        }
        if item.state == .idle || item.state == .unknown { return item.description }
        return isCodex ? (appState.codexActionFeedback ?? item.state.title) : item.state.title
    }

    private var secondaryHelp: String {
        if let detail = item.actionDetail, item.state == .awaitingInput { return detail }
        if isCodex { return appState.codexActionFeedback ?? item.description }
        return item.description
    }

    /// Claude's multiple-choice question, when the hook helper handed it to the
    /// island and it can be answered here. Anything else is answered in Claude.
    private var claudeAnswerRequest: ClaudeAnswerRequest? {
        opensHostToHandle ? appState.claudeAnswerRequest(forRow: item) : nil
    }

    private var approveTitle: String {
        if isCodex { return "处理请求" }
        if claudeAnswerRequest != nil { return "回答" }
        return (isAntigravity || opensHostToHandle || ["cursor", "windsurf", "trae"].contains(item.id)) ? "打开处理" : "帮我批准"
    }

    public var body: some View {
        HStack(spacing: HUDStyle.rowContentSpacing) {
            // The row's light follows the closed capsule: an icon when the
            // capsule shows icons, a dot when it shows dots.
            //
            // The light is also the way into the conversation, and only it:
            // every other part of the island takes a click as "open or close".
            // Making the name and state open the conversation as well took the
            // click away from the capsule, and left no place to click to close.
            HUDDotView(state: item.state, icon: appState.hudShowsIcons ? item.icon : nil)
                .logoTapTarget(enabled: onFocus != nil) { onFocus?() }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HUDStyle.nameColor)
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 12))
                    .foregroundColor(HUDStyle.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(secondaryHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .hudRowChrome(state: item.state)
        .accessibilityElement(children: .contain)
        .onChange(of: showDetail) { _, visible in
            if !visible, let id = presentedSessionID {
                appState.discardAntigravityQuestion(forSession: id)
                presentedSessionID = nil; presentedIdentity = nil; presentedDetail = nil; presentedQuestion = nil
            }
        }
        .onDisappear {
            if let id = presentedSessionID { appState.discardAntigravityQuestion(forSession: id) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if item.state == .awaitingInput {
            HStack(spacing: 6) {
                if item.actionDetail != nil {
                    Button(action: { toggleDetail() }) {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(HUDPillButtonStyle(primary: false))
                    .help("查看详情")
                    .accessibilityLabel("查看详情")
                    .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                        detailPopover(item.actionDetail ?? "")
                    }
                }

                if (!isAntigravity && !opensHostToHandle) || appState.testModeActive {
                    Button("拒绝") { onReject?() }
                        .buttonStyle(HUDPillButtonStyle(primary: false))
                }

                Button(approveTitle) { if isCodex || claudeAnswerRequest != nil { toggleDetail() } else { onApprove?() } }
                    .buttonStyle(HUDPillButtonStyle(primary: true))
            }
            .disabled(isCodex && appState.codexActionInFlight)
        } else if item.state == .completed, onAcknowledge != nil {
            HStack(spacing: 6) {
                Button(isAntigravity ? "已查看" : "待命") { onAcknowledge?() }
                    .buttonStyle(HUDPillButtonStyle(primary: false))
                if onFocus != nil {
                    Button("打开") { onFocus?() }
                        .buttonStyle(HUDPillButtonStyle(primary: true))
                }
            }
        }
    }
}

private struct ActionDetailContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A popover view showing the detailed action context for an AI awaiting input
/// Claude's multiple-choice question with one button per option. Choosing one
/// hands it to the hook helper, which gives it to Claude as the user's answer.
struct ClaudeAnswerPopover: View {
    let request: ClaudeAnswerRequest
    let itemName: String
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").foregroundColor(.orange).font(.system(size: 14))
                Text("\(itemName) 在等你回答").font(.system(size: 12, weight: .bold))
            }
            Divider()
            if let header = request.header, !header.isEmpty {
                Text(header).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            }
            Text(request.question)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                        Button(action: { onChoose(index) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.system(size: 12, weight: .medium))
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(.system(size: 10)).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("选择：\(option.label)")
                    }
                }
            }
            .frame(maxHeight: 280)
            Text("约 20 秒内不选，Claude 会回到原窗口自己提问。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 320)
    }
}

struct ActionDetailPopover: View {
    let detail: String
    let itemName: String
    var supportsFreeText: Bool = true
    var showsDisabledActions: Bool = false
    var onChoose: ((Int) -> Void)?
    var onSend: ((String, String?) -> Void)?
    
    @State private var customInput: String = ""
    @State private var measuredContentHeight: CGFloat = 0

    // Expand for normal questions and only scroll once the available screen
    // height would be exceeded. Long wrapped lines get extra room.
    private var detailHeight: CGFloat {
        let available = max(160, min(680, (NSScreen.main?.visibleFrame.height ?? 700) - 230))
        return min(max(48, measuredContentHeight > 0 ? measuredContentHeight : 120), available)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                Text("\(itemName) 等待操作")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(detail.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("   [") {
                            // Extract the number
                            let components = line.components(separatedBy: "] ")
                            if components.count >= 2 {
                                let numStr = components[0].replacingOccurrences(of: "   [", with: "")
                                HStack {
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if onSend != nil || onChoose != nil || showsDisabledActions {
                                    Button(action: {
                                        if let onChoose, let number = Int(numStr) { onChoose(number) }
                                        else { onSend?(numStr, nil) }
                                    }) {
                                        Text("选择")
                                            .font(.system(size: 9))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                    .tint(.blue)
                                    .disabled(onChoose == nil && onSend == nil)
                                    }
                                }
                            } else {
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                        } else {
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ActionDetailContentHeightKey.self, value: geometry.size.height)
                })
            }
            .frame(height: detailHeight)
            .onPreferenceChange(ActionDetailContentHeightKey.self) { height in
                guard height.isFinite, height > 0, abs(height - measuredContentHeight) >= 1 else { return }
                measuredContentHeight = height
            }
            .onChange(of: detail) { _, _ in measuredContentHeight = 0 }
            
            Divider()
            if onSend != nil && !supportsFreeText {
                Text("文字回复请在 Antigravity 中输入。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if onSend != nil && supportsFreeText {
            HStack {
                TextField("输入其他指令...", text: $customInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 11))
                    .onSubmit {
                        if !customInput.isEmpty {
                            let optionLines = detail.components(separatedBy: "\n").filter { $0.hasPrefix("   [") }
                            if optionLines.isEmpty {
                                onSend?(customInput, nil)
                            } else {
                                let otherOptionNumber = optionLines.count + 1
                                onSend?(customInput, "\(otherOptionNumber)")
                            }
                        }
                    }
                Button(action: {
                    if !customInput.isEmpty {
                        let optionLines = detail.components(separatedBy: "\n").filter { $0.hasPrefix("   [") }
                        if optionLines.isEmpty {
                            onSend?(customInput, nil)
                        } else {
                            let otherOptionNumber = optionLines.count + 1
                            onSend?(customInput, "\(otherOptionNumber)")
                        }
                    }
                }) {
                    Text("发送")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(customInput.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
            }
            .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}


/// The rim light around the capsule (setting "发光效果"). Red breathes, driven by
/// the clock like the status lights; the other states are steady.
struct HUDGlowView: View {
    let state: AIState
    let shape: RoundedRectangle
    let reduceMotion: Bool

    var body: some View {
        let hex = HUDStyle.glowHex(for: state)
        let animated = state == .awaitingInput && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let phase = animated ? HUDStyle.pulsePhase(at: context.date.timeIntervalSinceReferenceDate) : 0
            shape
                .strokeBorder(hex.map { HUDStyle.color(hex: $0, opacity: HUDStyle.glowOpacity(for: state, phase: phase)) }
                              ?? Color.white.opacity(HUDStyle.glowIdleOpacity),
                              lineWidth: hex == nil ? 1 : 1.5)
                .shadow(color: HUDStyle.color(hex: HUDStyle.redHex, opacity: HUDStyle.glowShadowOpacity(for: state, phase: phase)), radius: 10)
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state)
    }
}
