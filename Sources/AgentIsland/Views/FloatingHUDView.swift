import SwiftUI

private struct HUDContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

public struct FloatingHUDView: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false
    private let onContentSizeChange: (CGSize) -> Void

    public init(appState: AppState, onContentSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.appState = appState
        self.onContentSizeChange = onContentSizeChange
    }

    private var itemsToShow: [AIObserverItem] {
        return appState.displayedObservers
    }

    private var hasAwaitingInput: Bool {
        itemsToShow.contains(where: { $0.state == .awaitingInput })
    }

    private var dominantState: AIState {
        itemsToShow.map(\.state).max() ?? .idle
    }

    private struct HUDGroup: Identifiable {
        let id: String
        var items: [AIObserverItem]
    }

    private var groups: [HUDGroup] {
        var result: [HUDGroup] = []
        for item in itemsToShow {
            if item.icon == "antigravity", let index = result.firstIndex(where: { $0.id == "antigravity" }) {
                result[index].items.append(item)
            } else {
                result.append(HUDGroup(id: item.icon == "antigravity" ? "antigravity" : item.id, items: [item]))
            }
        }
        return result
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
        let provider = item.icon == "antigravity" ? "antigravity" : (claudeSessionRow ? "claude" : item.id)
        let sessionRow = item.id.hasPrefix(AppState.antigravitySessionPrefix)
        AISegmentView(appState: appState, item: item, isPulsing: isPulsing,
            // With several Claude Code conversations a blind keystroke cannot
            // be aimed at the right one, so a conversation's row only brings
            // the original window forward instead of approving by key press.
            onApprove: { claudeSessionRow ? appState.focusApp(for: "claude") : appState.approve(for: provider) },
            onReject: { claudeSessionRow ? appState.focusApp(for: "claude") : appState.reject(for: provider) },
            onFocus: { appState.focusApp(for: provider) },
            onAcknowledge: {
                if provider == "claude", claudeSessionRow {
                    appState.acknowledgeClaudeSession(String(item.id.dropFirst(AppState.claudeSessionPrefix.count)))
                }
                else if provider == "codex" { appState.acknowledgeCodex() }
                else if provider == "antigravity", sessionRow {
                    appState.acknowledgeAntigravitySession(String(item.id.dropFirst(AppState.antigravitySessionPrefix.count)))
                }
                else if provider == "antigravity" { appState.acknowledgeAntigravity() }
                else if provider == "claude" { appState.acknowledgeClaude() }
            })
    }

    public var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Group {
                if appState.hudLayoutMode == .vertical {
                    VStack(spacing: 8) {
                        ForEach(Array(itemsToShow.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle().fill(Color.white.opacity(0.18))
                                    .frame(width: appState.hudDetailMode == .full ? 150 : 60, height: 1)
                            }
                            segment(item)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 22) }
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(group.items) { item in segment(item) }
                            }
                        }
                    }
                }
            }
            .fixedSize()
            .padding(.horizontal, 32)
            .padding(.vertical, 11)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.88 * appState.hudOpacity))
                    if appState.showHUDGlow {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(hasAwaitingInput ? Color.red.opacity(isPulsing ? 0.9 : 0.4) :
                                (dominantState == .running ? Color.yellow.opacity(0.6) :
                                (dominantState == .completed ? Color.green.opacity(0.7) : Color.white.opacity(0.12))),
                                lineWidth: dominantState != .idle ? 2.0 : 1.2)
                            .shadow(color: hasAwaitingInput ? Color.red.opacity(isPulsing ? 0.6 : 0.2) : Color.clear,
                                    radius: 12, x: 0, y: 2)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            #if AGENTISLAND_ISOLATED_PREVIEW
            .overlay(alignment: .bottom) {
                Text("隔离测试版").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow).offset(y: 13)
            }
            #endif
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 4)
            // Measure the unconstrained content, not the ScrollView viewport.
            // Session names, feedback and action buttons can exceed any fixed
            // per-provider width estimate.
            .background(GeometryReader { geometry in
                Color.clear.preference(key: HUDContentSizeKey.self, value: geometry.size)
            })
        }
        .onPreferenceChange(HUDContentSizeKey.self, perform: onContentSizeChange)
        .contextMenu { contextMenuItems() }
        .animation(.easeInOut(duration: 0.25), value: itemsToShow)
        .onAppear { isPulsing = true }
        .onChange(of: hasAwaitingInput) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { isPulsing = true }
            }
        }
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

/// The "+N" mark for conversations that did not fit in an assistant's rows. It
/// takes the colour of the worst state it hides, so a conversation that needs
/// the user is never buried, and opens a list of what it holds.
private struct OverflowChipView: View {
    @ObservedObject var appState: AppState
    let item: AIObserverItem
    @State private var showList = false

    private var providerID: String { String(item.id.dropFirst(AppState.overflowPrefix.count)) }

    var body: some View {
        Button { showList.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(item.state.color.opacity(0.2)).frame(width: 26, height: 26)
                    AIIconView(provider: item.icon, size: 14, color: item.state.color)
                }
                Text(item.name)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(item.state.color.opacity(0.2))
                    .foregroundColor(item.state.color)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help("\(item.description)，点击查看")
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            OverflowSessionListView(appState: appState, providerID: providerID)
        }
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
                        Button("打开处理") { appState.focusApp(for: providerID) }
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
    let isPulsing: Bool
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
        if item.id == "codex" {
            CodexRequestView(appState: appState, onDismiss: { showDetail = false })
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
        } else if isClaudeSession {
            VStack(alignment: .leading, spacing: 5) {
                ActionDetailPopover(detail: detail, itemName: item.name, supportsFreeText: false,
                                    showsDisabledActions: true, onChoose: nil, onSend: nil)
                Text("同时有多个 Claude Code 会话时，无法确认回复会送到哪一个，请在对应的终端或窗口中回答。")
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

    public var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(item.state.color.opacity(0.2))
                    .frame(width: 26, height: 26)

                if item.state == .running {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(item.state.color, lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(isPulsing ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isPulsing)
                }

                if item.id == "antigravity" || item.icon == "antigravity" {
                    AntigravityIconView(size: 14, color: item.state == .idle ? .secondary : item.state.color)
                } else if ["claude", "codex", "cursor", "windsurf", "trae"].contains(item.id) || ["claude", "codex", "cursor", "windsurf", "trae"].contains(item.icon) {
                    let provider = ["claude", "codex", "cursor", "windsurf", "trae"].contains(item.id) ? item.id : item.icon
                    AIIconView(provider: provider, size: 14, color: item.state == .idle ? .secondary : item.state.color)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(item.state == .idle ? .secondary : item.state.color)
                }
            }

            if appState.hudDetailMode == .full {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Group {
                            if isAntigravity && item.state == .completed {
                                Button(item.state.title) { onAcknowledge?() }.buttonStyle(.plain)
                            } else { Text(item.state.title) }
                        }
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(item.state.color.opacity(0.2))
                            .foregroundColor(item.state.color)
                            .clipShape(Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if let detail = item.actionDetail, item.state == .awaitingInput {
                        HStack(spacing: 4) {
                            Text(rowFeedback ?? detail.components(separatedBy: "\n").first ?? detail)
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .leading)
                                .help(detail)

                            if item.state == .awaitingInput {
                                Button(action: { toggleDetail() }) {
                                    Image(systemName: "list.bullet.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                                    detailPopover(detail)
                                }
                            }
                        }
                        
                        if item.id == "codex", let feedback = appState.codexActionFeedback, !feedback.isEmpty {
                            Text(feedback).font(.system(size: 9)).foregroundColor(.red)
                                .lineLimit(1).frame(maxWidth: 200)
                        }
                    } else {
                        Text(item.description)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .leading)
                            .help(item.actionDetail != nil ? "详情：\n\(item.actionDetail!)" : item.description)
                    }
                }
            } else if appState.hudDetailMode == .concise && item.state != .idle {
                HStack(spacing: 4) {
                    if item.id.hasPrefix(AppState.antigravitySessionPrefix) || isClaudeSession {
                        Text(item.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                    Group {
                        if isAntigravity && item.state == .completed {
                            Button(item.state.title) { onAcknowledge?() }.buttonStyle(.plain)
                        } else {
                            Text(rowFeedback ?? (item.id == "codex" ? (appState.codexActionFeedback ?? item.state.title) : item.state.title))
                        }
                    }
                        .lineLimit(1)
                        .fixedSize(horizontal: item.id == "codex" && appState.codexActionFeedback == nil, vertical: false)
                        .frame(maxWidth: 180)
                        .help(item.id == "codex" ? (appState.codexActionFeedback ?? item.description) : item.description)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(item.state.color.opacity(0.2))
                        .foregroundColor(item.state.color)
                        .clipShape(Capsule())
                        
                    if let detail = item.actionDetail, item.state == .awaitingInput {
                        Button(action: { toggleDetail() }) {
                            Image(systemName: "list.bullet.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                            detailPopover(detail)
                        }
                    }
                }
            }

            if item.state == .awaitingInput {
                HStack(spacing: 5) {
                    Button(action: { if item.id == "codex" { showDetail.toggle() } else { onApprove?() } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(item.id == "codex" ? "处理请求" : ((isAntigravity || isClaudeSession || ["cursor", "windsurf", "trae"].contains(item.id)) ? "打开处理" : "帮我批准"))
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .shadow(color: .red.opacity(0.5), radius: isPulsing ? 5 : 2)
                    }
                    .buttonStyle(.plain)

                    if !isAntigravity || appState.testModeActive {
                    Button(action: { onReject?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(4)
                            .background(Color.secondary.opacity(0.25))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    }
                }
                .disabled(item.id == "codex" && appState.codexActionInFlight)
            } else if item.state == .completed, onAcknowledge != nil {
                if isAntigravity {
                    Button("打开") { onFocus?() }.buttonStyle(.plain).font(.system(size: 9))
                }
                Button(action: { onAcknowledge?() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(isAntigravity ? "已查看" : "待命")
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.green.opacity(0.18))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
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
}

private struct ActionDetailContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A popover view showing the detailed action context for an AI awaiting input
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
