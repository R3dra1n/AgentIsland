import SwiftUI

public struct FloatingHUDView: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false

    public init(appState: AppState) {
        self.appState = appState
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

    public var body: some View {
        Group {
            if appState.hudLayoutMode == .vertical {
                VStack(spacing: 8) {
                    ForEach(Array(itemsToShow.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: appState.hudDetailMode == .full ? 150 : 60, height: 1)
                        }

                        AISegmentView(
                            appState: appState,
                            item: item,
                            isPulsing: isPulsing,
                            onApprove: { appState.approve(for: item.id) },
                            onReject: { appState.reject(for: item.id) },
                            onFocus: { appState.focusApp(for: item.id) },
                            onAcknowledge: {
                                if item.id == "codex" { appState.acknowledgeCodex() }
                                else if item.id == "antigravity" { appState.acknowledgeAntigravity() }
                                else if item.id == "claude" { appState.acknowledgeClaude() }
                            }
                        )
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(itemsToShow.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 1, height: 22)
                        }

                        AISegmentView(
                            appState: appState,
                            item: item,
                            isPulsing: isPulsing,
                            onApprove: { appState.approve(for: item.id) },
                            onReject: { appState.reject(for: item.id) },
                            onFocus: { appState.focusApp(for: item.id) },
                            onAcknowledge: {
                                if item.id == "codex" { appState.acknowledgeCodex() }
                                else if item.id == "antigravity" { appState.acknowledgeAntigravity() }
                                else if item.id == "claude" { appState.acknowledgeClaude() }
                            }
                        )
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
                        .stroke(
                            hasAwaitingInput ? Color.red.opacity(isPulsing ? 0.9 : 0.4) :
                            (dominantState == .running ? Color.yellow.opacity(0.6) :
                            (dominantState == .completed ? Color.green.opacity(0.7) : Color.white.opacity(0.12))),
                            lineWidth: dominantState != .idle ? 2.0 : 1.2
                        )
                        .shadow(
                            color: hasAwaitingInput ? Color.red.opacity(isPulsing ? 0.6 : 0.2) : Color.clear,
                            radius: 12, x: 0, y: 2
                        )
                }
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #if AGENTISLAND_ISOLATED_PREVIEW
        .overlay(alignment: .bottom) {
            Text("隔离测试版")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.yellow)
                .offset(y: 13)
        }
        #endif
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .contextMenu {
            contextMenuItems()
        }
        .animation(.easeInOut(duration: 0.25), value: itemsToShow)
        .onAppear {
            isPulsing = true
        }
        .onChange(of: hasAwaitingInput) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
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

public struct AISegmentView: View {
    @ObservedObject var appState: AppState
    let item: AIObserverItem
    let isPulsing: Bool
    var onApprove: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onAcknowledge: (() -> Void)? = nil
    @State private var showDetail = false

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

                        Text(item.state.title)
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
                            Text(detail.components(separatedBy: "\n").first ?? detail)
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .leading)
                                .help(detail)

                            if item.state == .awaitingInput {
                                Button(action: { showDetail.toggle() }) {
                                    Image(systemName: "list.bullet.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                                    if item.id == "codex" {
                                        CodexRequestView(appState: appState, onDismiss: { showDetail = false })
                                    } else {
                                        ActionDetailPopover(detail: detail, itemName: item.name, supportsFreeText: true,
                                            onChoose: item.id == "antigravity" ? { appState.sendAntigravityOption($0) } : nil, onSend: { text, prefix in
                                            showDetail = false
                                            appState.sendTextInput(for: item.id, text: text, prefixKey: prefix)
                                        })
                                    }
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
                    Text(item.id == "codex" ? (appState.codexActionFeedback ?? item.state.title) : item.state.title)
                        .lineLimit(2).frame(maxWidth: 180)
                        .help(item.id == "codex" ? (appState.codexActionFeedback ?? item.description) : item.description)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(item.state.color.opacity(0.2))
                        .foregroundColor(item.state.color)
                        .clipShape(Capsule())
                        
                    if let detail = item.actionDetail, item.state == .awaitingInput {
                        Button(action: { showDetail.toggle() }) {
                            Image(systemName: "list.bullet.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                            if item.id == "codex" {
                                CodexRequestView(appState: appState, onDismiss: { showDetail = false })
                            } else {
                            ActionDetailPopover(detail: detail, itemName: item.name, supportsFreeText: true,
                                onChoose: item.id == "antigravity" ? { appState.sendAntigravityOption($0) } : nil, onSend: { text, prefix in
                                showDetail = false
                                appState.sendTextInput(for: item.id, text: text, prefixKey: prefix)
                            })
                            }
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
                            Text(item.id == "codex" ? "处理请求" : (["antigravity", "cursor", "windsurf", "trae"].contains(item.id) ? "打开处理" : "帮我批准"))
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

                    if item.id != "antigravity" || appState.testModeActive {
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
            } else if item.state == .completed {
                Button(action: { onAcknowledge?() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("待命")
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
    }
}

/// A popover view showing the detailed action context for an AI awaiting input
struct ActionDetailPopover: View {
    let detail: String
    let itemName: String
    var supportsFreeText: Bool = true
    var onChoose: ((Int) -> Void)?
    var onSend: ((String, String?) -> Void)?
    
    @State private var customInput: String = ""

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
                    ForEach(detail.components(separatedBy: "\n"), id: \.self) { line in
                        if line.hasPrefix("   [") {
                            // Extract the number
                            let components = line.components(separatedBy: "] ")
                            if components.count >= 2 {
                                let numStr = components[0].replacingOccurrences(of: "   [", with: "")
                                HStack {
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .lineLimit(3)
                                    Spacer()
                                    if onSend != nil {
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
            }
            .frame(maxHeight: 250)
            
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
