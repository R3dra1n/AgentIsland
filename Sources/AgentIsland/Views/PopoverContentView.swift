import SwiftUI

public struct AppleNativeToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.label

            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    configuration.isOn.toggle()
                }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(configuration.isOn ? Color(red: 0.0, green: 0.478, blue: 1.0) : Color.white.opacity(0.2))
                        .frame(width: 36, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(configuration.isOn ? Color.clear : Color.white.opacity(0.12), lineWidth: 0.5)
                        )

                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 2)
                        .shadow(color: Color.black.opacity(0.25), radius: 1.5, x: 0, y: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

extension ToggleStyle where Self == AppleNativeToggleStyle {
    public static var appleNative: AppleNativeToggleStyle {
        AppleNativeToggleStyle()
    }
}

public struct PopoverContentView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    headerSection
                    providersSection
                    preferencesSection
                }
                .padding(14)
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
                
            footerSection
                .padding(14)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        }
        .frame(width: 330, height: 680)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                Text("AI 状态感知")
                    .font(.system(size: 15, weight: .bold))
            }

            Spacer()

            HStack(spacing: 6) {
                Text("灵动岛")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Toggle("", isOn: $appState.isHUDEnabled)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var providersSection: some View {
        VStack(spacing: 10) {
            ForEach(appState.allObservers, id: \.id) { observer in
                providerCard(for: observer)
                    .onDrag { NSItemProvider(object: observer.id as NSString) }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(item: observer.id, listData: $appState.observerOrder))
            }
        }
    }

    @ViewBuilder
    private func providerCard(for observer: AIObserverItem) -> some View {
        switch observer.id {
        case "codex":
            OpenUsageProviderCard(icon: "codex", name: "Codex", tier: "Plus", isEnabled: $appState.codexEnabled, state: appState.codexState, description: appState.codexActionFeedback ?? appState.codexDescription, onAcknowledge: { appState.acknowledgeCodex() }, onApprove: { appState.approve(for: "codex") }, onReject: { appState.reject(for: "codex") }, onFocus: { appState.focusApp(for: "codex") }, approveTitle: appState.codexPendingRequests.contains(where: \.isQuestion) ? "查看问题" : "批准", actionBusy: appState.codexActionInFlight)
        case "antigravity":
            OpenUsageProviderCard(icon: "antigravity", name: "Antigravity", tier: "Pro", isEnabled: $appState.antigravityEnabled, state: appState.antigravityState, description: appState.antigravityDescription, onAcknowledge: { appState.acknowledgeAntigravity() }, onApprove: { appState.approve(for: "antigravity") }, onReject: { appState.reject(for: "antigravity") }, onFocus: { appState.focusApp(for: "antigravity") })
        case "claude":
            OpenUsageProviderCard(icon: "claude", name: "Claude", tier: appState.claudeTier, isEnabled: $appState.claudeEnabled, state: appState.claudeState, description: appState.claudeDescription, onAcknowledge: { appState.acknowledgeClaude() }, onApprove: { appState.approve(for: "claude") }, onReject: { appState.reject(for: "claude") }, onFocus: { appState.openClaudeConversation() })
        case "cursor":
            OpenUsageProviderCard(icon: "cursor", name: "Cursor", tier: "Agent", isEnabled: $appState.cursorEnabled, state: appState.cursorState, description: appState.cursorDescription, onAcknowledge: { appState.acknowledgeCursor() }, onApprove: { appState.approve(for: "cursor") }, onReject: { appState.reject(for: "cursor") }, onFocus: { appState.focusApp(for: "cursor") })
        case "windsurf":
            OpenUsageProviderCard(icon: "windsurf", name: "Windsurf", tier: "Cascade", isEnabled: $appState.windsurfEnabled, state: appState.windsurfState, description: appState.windsurfDescription, onAcknowledge: { appState.acknowledgeWindsurf() }, onApprove: { appState.approve(for: "windsurf") }, onReject: { appState.reject(for: "windsurf") }, onFocus: { appState.focusApp(for: "windsurf") })
        case "trae":
            OpenUsageProviderCard(icon: "trae", name: "Trae", tier: "Pro", isEnabled: $appState.traeEnabled, state: appState.traeState, description: appState.traeDescription, onAcknowledge: { appState.acknowledgeTrae() }, onApprove: { appState.approve(for: "trae") }, onReject: { appState.reject(for: "trae") }, onFocus: { appState.focusApp(for: "trae") })
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("主题外观")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Picker("", selection: $appState.appTheme) {
                    ForEach(AppTheme.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }
            

            Divider().opacity(0.6)

            HStack {
                Text("灵动岛布局")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Picker("", selection: $appState.hudLayoutMode) {
                    ForEach(HUDLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }
            
            Divider().opacity(0.6)

            HStack {
                Text("灵动岛详情")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Picker("", selection: $appState.hudDetailMode) {
                    ForEach(HUDDetailMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("灵动岛展示模式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Picker("", selection: $appState.hudDisplayMode) {
                    ForEach(HUDDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("灵动岛透明度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Slider(value: $appState.hudOpacity, in: 0.0...1.0)
                    .frame(width: 100)
            }

            HStack {
                Text("收起时显示助手图标")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.hudShowsIcons)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            HStack {
                Text("灵动岛边缘光效")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.showHUDGlow)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }
            
            Divider().opacity(0.6)

            HStack {
                Text("状态栏显示图标")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.showMenuBarIcon)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("状态栏显示状态圆点")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.showMenuBarDot)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("状态栏显示详情文字")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.showMenuBarText)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("系统提示音")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $appState.soundAlertEnabled)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            Divider().opacity(0.6)

            HStack {
                Text("可选 Hook")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Menu("配置") {
                    Button("配置 Codex Hook…") { NativeHookSetup.begin(source: "codex") }
                    Button("配置 Antigravity Hook…") { NativeHookSetup.begin(source: "antigravity") }
                    Button("配置 Claude Code Hook…") { NativeHookSetup.begin(source: "claude") }
                    Divider()
                    Button("移除 Codex Hook…") { NativeHookSetup.begin(source: "codex", removing: true) }
                    Button("移除 Antigravity Hook…") { NativeHookSetup.begin(source: "antigravity", removing: true) }
                    Button("移除 Claude Code Hook…") { NativeHookSetup.begin(source: "claude", removing: true) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack {
                Text("Antigravity 提前验证问题")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.antigravityPrevalidationEnabled },
                    set: { AntigravityActionController.setPrevalidation($0, state: appState) }
                ))
                .toggleStyle(.appleNative)
                .labelsHidden()
                .help("开启后会在打开面板前查询等待的问题，不会自动回复。")
            }

            Button("撤销 Antigravity 后台回复授权") { AntigravityActionController.revokeConsent(state: appState) }
                .font(.system(size: 11))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.25), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                Text("AgentIsland v\(version)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(appState.testModeActive ? "处于模拟演示模式" : "实时状态感知运行中")
                    .font(.system(size: 10))
                    .foregroundColor(appState.testModeActive ? .orange : .secondary.opacity(0.8))
            }

            Spacer()

            Menu {
                Section("测试演示") {
                    Button("模拟: 需操作 (🔴)") {
                        appState.triggerMultiTest(state: .awaitingInput)
                    }
                    Button("模拟: 执行中 (🟡)") {
                        appState.triggerMultiTest(state: .running)
                    }
                    Button("模拟: 全部已完成 (🟢)") {
                        appState.triggerMultiTest(state: .completed)
                    }
                    if appState.testModeActive {
                        Button("恢复实时感知") {
                            appState.stopTest()
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出 AgentIsland", systemImage: "power")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                    Text("测试")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(NSColor.controlColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 0.5)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.plain)

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.red.opacity(0.85))
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 0.5)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A clean grouped provider card replicating the OpenUsage aesthetic
public struct OpenUsageProviderCard: View {
    let icon: String
    let name: String
    let tier: String
    @Binding var isEnabled: Bool
    let state: AIState
    let description: String
    var onAcknowledge: (() -> Void)? = nil
    var onApprove: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var approveTitle: String = "批准"
    var actionBusy: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: Logo + Name + Tier Badge + Switch
            HStack(spacing: 8) {
                if icon == "antigravity" {
                    AntigravityIconView(size: 16)
                        .frame(width: 20, height: 20)
                } else if ["claude", "codex", "cursor", "windsurf", "trae"].contains(icon) {
                    AIIconView(provider: icon, size: 16)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isEnabled ? .primary : .secondary)
                        .frame(width: 20, height: 20)
                }

                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isEnabled ? .primary : .secondary)

                Text(tier)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(4)

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.appleNative)
                    .labelsHidden()
            }

            if isEnabled {
                // Status row: Status Title + Details + optional Acknowledge Button
                HStack(alignment: .center) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.color)
                            .frame(width: 7, height: 7)
                        Text(state.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(state.color)

                        if state == .completed {
                            Button(action: { onAcknowledge?() }) {
                                HStack(spacing: 2) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("恢复待命")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // If awaitingInput, render direct background operation buttons!
                if state == .awaitingInput {
                    HStack(spacing: 6) {
                        Button(action: { if !actionBusy { onApprove?() } }) {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(icon == "antigravity" ? "打开处理" : "帮我批准")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        if icon != "antigravity" {
                        Button(action: { if !actionBusy { onReject?() } }) {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 10))
                                Text("拒绝")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.2))
                            .foregroundColor(.secondary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        }

                        Spacer()

                        Button(action: { onFocus?() }) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 10))
                                Text("激活窗口")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                // Sleek activity track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 4)

                        Capsule()
                            .fill(state.color)
                            .frame(
                                width: state == .idle ? 0 : (state == .completed ? geo.size.width : geo.size.width * 0.65),
                                height: 4
                            )
                    }
                }
                .frame(height: 4)
            } else {
                Text("已关闭状态感知")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    state == .awaitingInput ? Color.red.opacity(0.5) : Color(NSColor.separatorColor).opacity(0.25),
                    lineWidth: state == .awaitingInput ? 1.5 : 0.8
                )
        )
    }
}


struct ReorderDropDelegate: DropDelegate {
    let item: String
    @Binding var listData: [String]

    func performDrop(info: DropInfo) -> Bool { return true }

    func dropEntered(info: DropInfo) {
        guard let itemProvider = info.itemProviders(for: [.text]).first else { return }
        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { (data, error) in
            let str = (data as? Data).flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                if let draggedItem = str {
                    if draggedItem != self.item {
                        if let from = listData.firstIndex(of: draggedItem), let to = listData.firstIndex(of: self.item) {
                            withAnimation {
                                listData.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                            }
                        }
                    }
                }
            }
        }
    }
}
