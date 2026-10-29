import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Engine to execute AI approvals, rejections, and actions directly on the local AI application.
@MainActor
public final class DirectActionEngine: Sendable {
    public static let shared = DirectActionEngine()

    public init() {}

    /// Validate the intended target without vetoing the original delivery path.
    public func canSendAntigravityAction(appState: AppState) -> Bool {
        if appState.testModeActive { return true }
        if !AXIsProcessTrusted() && !CGPreflightPostEventAccess() {
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            AXIsProcessTrustedWithOptions(options)
            DispatchQueue.main.async {
                appState.antigravityState = .interrupted
                appState.antigravityDescription = "由于更名 AgentIsland，权限丢失。请在「隐私与安全性->辅助功能」中先减号删除旧应用，再加号添加此版本并重启应用！"
                appState.recalculateAggregatedState()
            }
            return false
        }
        guard findRunningApp(matching: ["Antigravity"]) != nil else {
            DispatchQueue.main.async {
                appState.antigravityState = .failed
                appState.antigravityDescription = "发送失败：Antigravity 未运行"
                appState.recalculateAggregatedState()
            }
            return false
        }
        return true
    }

    /// Executes approval and dispatches action to target application
    public func approveInBackground(observerId: String, appState: AppState) {
        if observerId == "antigravity", !canSendAntigravityAction(appState: appState) { return }
        if observerId == "codex", !appState.testModeActive {
            CodexActionController.perform(approve: true, state: appState)
            return
        }
        if appState.testModeActive {
            if appState.codexEnabled { appState.codexState = .running; appState.codexDescription = "模拟执行中..." }
            if appState.antigravityEnabled { appState.antigravityState = .running; appState.antigravityDescription = "模拟执行中..." }
            if appState.claudeEnabled { appState.claudeState = .running; appState.claudeDescription = "模拟执行中..." }
            if appState.cursorEnabled { appState.cursorState = .running; appState.cursorDescription = "模拟执行中..." }
            if appState.windsurfEnabled { appState.windsurfState = .running; appState.windsurfDescription = "模拟执行中..." }
            if appState.traeEnabled { appState.traeState = .running; appState.traeDescription = "模拟执行中..." }
            appState.recalculateAggregatedState()
        } else {
            // Immediate local state update for instant UI responsiveness
            if observerId == "codex" {
                appState.codexState = .running
                appState.codexDescription = "已批准，正在执行指令..."
            } else if observerId == "antigravity" {
                appState.antigravityState = .running
                appState.antigravityDescription = "正在发送批准，等待 Antigravity 状态更新..."
            } else if observerId == "claude" {
                appState.claudeState = .running
                appState.claudeDescription = "已批准，正在执行指令..."
            }
            appState.recalculateAggregatedState()
        }

        // Play feedback sound
        NSSound(named: "Tink")?.play()

        // Handle simulation demo mode: simulate execution -> completion -> reset to idle
        if appState.testModeActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak appState] in
                guard let appState = appState, appState.testModeActive else { return }
                appState.codexState = .completed
                appState.antigravityState = .completed
                appState.claudeState = .completed
                appState.cursorState = .completed
                appState.windsurfState = .completed
                appState.traeState = .completed
                
                appState.codexDescription = "测试指令已执行完成"
                appState.antigravityDescription = "测试指令已执行完成"
                appState.claudeDescription = "测试指令已执行完成"
                appState.cursorDescription = "测试指令已执行完成"
                appState.windsurfDescription = "测试指令已执行完成"
                appState.traeDescription = "测试指令已执行完成"
                
                appState.recalculateAggregatedState()
                NSSound(named: "Glass")?.play()

                // Auto-restore after 3s of showing completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak appState] in
                    guard let appState = appState, appState.testModeActive else { return }
                    appState.stopTest()
                }
            }
            return
        }

        // 2. Dispatch the approval trigger asynchronously (NO JUMPING)
        DispatchQueue.global(qos: .userInitiated).async {
            if observerId == "antigravity" {
                self.approveAntigravity()
            } else if observerId == "claude" {
                self.approveClaude()
            }
        }
    }

    /// Executes rejection and dispatches action to target application
    public func rejectInBackground(observerId: String, appState: AppState) {
        if observerId == "antigravity", !canSendAntigravityAction(appState: appState) { return }
        if observerId == "codex", !appState.testModeActive {
            CodexActionController.perform(approve: false, state: appState)
            return
        }
        if observerId == "codex" {
            appState.codexState = .interrupted
            appState.codexDescription = "用户已拒绝操作"
            appState.recalculateAggregatedState()
        } else if observerId == "antigravity" {
            appState.antigravityState = .interrupted
            appState.antigravityDescription = "正在发送拒绝，等待 Antigravity 状态更新..."
            appState.recalculateAggregatedState()
        } else if observerId == "claude" {
            appState.claudeState = .interrupted
            appState.claudeDescription = "用户已拒绝操作"
            appState.recalculateAggregatedState()
        }

        NSSound(named: "Basso")?.play()

        if appState.testModeActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak appState] in
                guard let appState = appState, appState.testModeActive else { return }
                appState.stopTest()
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if observerId == "claude" {
                if let claudeApp = self.findRunningApp(matching: ["Claude"]) {
                    self.sendKey(virtualKey: 53, targetPid: claudeApp.processIdentifier) // Esc
                } else {
                    let terminalNames = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "Kitty"]
                    if let termApp = self.findRunningApp(matching: terminalNames) {
                        self.sendKey(virtualKey: 45, targetPid: termApp.processIdentifier) // 'n'
                        Thread.sleep(forTimeInterval: 0.05)
                        self.sendKey(virtualKey: 36, targetPid: termApp.processIdentifier) // Return
                    }
                }
            } else {
                let rejectKeywords = ["拒绝", "Cancel", "Deny", "取消", "No", "放弃"]
                if observerId == "antigravity" {
                    if let app = self.findRunningApp(matching: ["Antigravity"]) {
                        self.pressActionMatching(rejectKeywords, targetApp: app)
                        self.sendKey(virtualKey: 53, targetPid: app.processIdentifier)
                    }
                } else if observerId == "codex" {
                    if let app = self.findRunningApp(matching: ["ChatGPT", "Codex"]) {
                        self.pressActionMatching(rejectKeywords, targetApp: app)
                        self.sendKey(virtualKey: 53, targetPid: app.processIdentifier)
                    }
                }
            }
        }
    }

    private nonisolated func findRunningApp(matching names: [String]) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        for name in names {
            if let app = running.first(where: {
                let appName = $0.localizedName ?? ""
                let bid = $0.bundleIdentifier ?? ""
                return appName.localizedCaseInsensitiveContains(name) || bid.localizedCaseInsensitiveContains(name)
            }) {
                return app
            }
        }
        return nil
    }

    private nonisolated func approveAntigravity() {
        guard let app = findRunningApp(matching: ["Antigravity"]) else { return }
        sendKey(virtualKey: 36, targetPid: app.processIdentifier)
    }

    private nonisolated func approveClaude() {
        let approvalKeywords = [
            "Proceed", "Approve", "Allow", "Run", "Yes", "Confirm",
            "批准", "允许", "确定", "继续"
        ]

        // 1. Check if Claude Desktop app is running
        if let claudeApp = findRunningApp(matching: ["Claude"]) {
            if pressActionMatching(approvalKeywords, targetApp: claudeApp) {
                return
            }
            
            // Fallback: Send global Enter directly to process without jumping
            sendKey(virtualKey: 36, targetPid: claudeApp.processIdentifier)
        } else {
            // 2. Check active terminal running Claude Code CLI
            let terminalNames = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "Kitty", "Cursor", "Code"]
            if let termApp = findRunningApp(matching: terminalNames) {
                // Send 'y' and Return to active terminal prompt
                sendKey(virtualKey: 16, targetPid: termApp.processIdentifier) // 'y'
                Thread.sleep(forTimeInterval: 0.05)
                sendKey(virtualKey: 36, targetPid: termApp.processIdentifier) // Return
            }
        }
    }

    @discardableResult
    private nonisolated func pressActionMatching(_ keywords: [String], targetApp: NSRunningApplication? = nil) -> Bool {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        guard let app = app else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Wake up Chromium / Electron accessibility trees
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for win in windows {
            if recursivePress(in: win, matching: keywords, depth: 0, targetPid: app.processIdentifier) {
                return true
            }
        }
        return false
    }

    private nonisolated func recursivePress(in element: AXUIElement, matching keywords: [String], depth: Int, targetPid: pid_t) -> Bool {
        // Deep Electron / Chromium DOM tree traversal (up to depth 45)
        if depth > 45 { return false }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String ?? ""

        var valRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
        let val = valRef as? String ?? ""

        let label = !title.isEmpty ? title : (!desc.isEmpty ? desc : val)

        if role.contains("Button") || role == "AXPopUpButton" || role == "AXLink" || !label.isEmpty {
            for kw in keywords {
                if label.localizedCaseInsensitiveContains(kw) {
                    // Check element dimensions to ensure it is visible and clickable
                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
                    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
                    if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }

                    // Skip invisible or tiny tracker nodes
                    if size.width >= 16 && size.height >= 14 {
                        // 1. Try native AXPress action
                        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                        if err == .success {
                            return true
                        }

                        // 2. Dual-mode fallback: Dispatch genuine hardware-level mouse click at center coordinates to specific PID
                        let center = CGPoint(x: pos.x + size.width / 2.0, y: pos.y + size.height / 2.0)
                        clickAt(point: center, targetPid: targetPid)
                        return true
                    }
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if recursivePress(in: child, matching: keywords, depth: depth + 1, targetPid: targetPid) {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated func clickAt(point: CGPoint, targetPid: pid_t? = nil) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        
        if let pid = targetPid {
            down?.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.04)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
            up?.post(tap: .cghidEventTap)
        }
    }

    public nonisolated func sendKey(virtualKey: CGKeyCode, targetPid: pid_t? = nil) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        
        if let pid = targetPid {
            down?.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.03)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            up?.post(tap: .cghidEventTap)
        }
    }

    public nonisolated func sendKeyWithModifiers(virtualKey: CGKeyCode, flags: CGEventFlags, targetPid: pid_t? = nil) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        
        if let pid = targetPid {
            down?.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.03)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            up?.post(tap: .cghidEventTap)
        }
    }
    
    private nonisolated func bounceFocusAndSendReturn(targetApp: NSRunningApplication) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        
        let switchBack: @Sendable () -> Void = {
            if let prev = previousApp, prev.processIdentifier != targetApp.processIdentifier {
                Thread.sleep(forTimeInterval: 0.05)
                if #available(macOS 14.0, *), let url = prev.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
                } else {
                    prev.activate(options: .activateIgnoringOtherApps)
                }
            }
        }
        
        let injectAction: @Sendable () -> Void = {
            // Poll up to 10 times (0.5 seconds) to wait for the app to actually become active
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            // Add a tiny extra delay to let the app's event loop settle
            Thread.sleep(forTimeInterval: 0.05)
            self.sendKey(virtualKey: 36, targetPid: targetApp.processIdentifier) // Direct injection to PID
            switchBack()
        }

        if #available(macOS 14.0, *), let url = targetApp.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                DispatchQueue.main.async {
                    injectAction()
                }
            }
        } else {
            targetApp.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.main.async {
                injectAction()
            }
        }
    }

    nonisolated func sendTextInBackground(observerId: String, text: String, prefixKey: String? = nil, appState: AppState, expectedAntigravityDetail: String? = nil, expectedAntigravityIdentity: AntigravityPendingIdentity? = nil) {
        var canSend = true
        if observerId == "antigravity" {
            DispatchQueue.main.sync {
                // Recheck after the background task starts: another question or
                // session may have appeared while the action was queued.
                canSend = AntigravityReplyPolicy.permitsQueuedReply(text, prefixKey: prefixKey,
                    pendingSessions: appState.antigravityObserver.pendingSessionCount,
                    expectedDetail: expectedAntigravityDetail, currentDetail: appState.antigravityObserver.actionDetail,
                    expectedIdentity: expectedAntigravityIdentity, currentIdentity: appState.antigravityObserver.pendingIdentity)
                    && canSendAntigravityAction(appState: appState)
                if !canSend { appState.antigravityDescription = "未发送，请在 Antigravity 中确认并回答" }
            }
        }
        guard canSend else { return }
        
        let runningApps = NSWorkspace.shared.runningApplications
        var targetAppName = "iTerm2"
        if observerId == "codex" {
            targetAppName = "ChatGPT"
        } else if observerId == "antigravity" {
            targetAppName = "Antigravity"
        } else if observerId == "claude" {
            // First try to find Claude Desktop, otherwise fallback to terminal
            if runningApps.contains(where: { $0.localizedName?.localizedCaseInsensitiveContains("Claude") == true }) {
                targetAppName = "Claude"
            }
        }

        var foundApp: NSRunningApplication?
        if let app = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(targetAppName) == true }) {
            foundApp = app
        } else if observerId == "antigravity" {
            return // Never route an Antigravity reply to an unrelated terminal.
        } else {
            let terminalNames = ["iTerm2", "Terminal", "Code", "Cursor", "Windsurf", "Trae", "Antigravity", "Electron"]
            if let app = runningApps.first(where: { app in
                terminalNames.contains(where: { (app.localizedName ?? "").localizedCaseInsensitiveContains($0) })
            }) {
                foundApp = app
            } else if let prev = NSWorkspace.shared.frontmostApplication {
                foundApp = prev
            }
        }
        
        guard let targetApp = foundApp else { return }
        
        // Fast path for single digits or single y/n/c characters
        // We can send these directly in the background using CGEvent without activating the app!
        // NOTE: ChatGPT (Codex) drops background CGEvent keys, so we must force AppleScript bounce for it.
        if text.count == 1, prefixKey == nil, observerId != "codex" {
            let char = text.lowercased()
            var vk: CGKeyCode?
            if let num = Int(text) {
                let keyMap: [Int: CGKeyCode] = [
                    1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
                    6: 22, 7: 26, 8: 28, 9: 25, 0: 29
                ]
                vk = keyMap[num]
            } else if observerId == "cursor" && char == "y" {
                // For Cursor approval, simulate Cmd+Enter (Cmd = 55, Enter = 36)
                let pid = targetApp.processIdentifier
                sendKeyWithModifiers(virtualKey: 36, flags: [.maskCommand], targetPid: pid)
                return
            } else if char == "y" { vk = 16 }
            else if char == "n" { vk = 45 }
            else if char == "c" { vk = 8 }
            
            if let vk = vk {
                let pid = targetApp.processIdentifier
                sendKey(virtualKey: vk, targetPid: pid)
                Thread.sleep(forTimeInterval: 0.05)
                sendKey(virtualKey: 36, targetPid: pid) // Enter
                return
            }
        }
        
        // Antigravity text injection has no reliable target verification. Never
        // fall through to the generic clipboard/AppleScript submission path.
        if observerId == "antigravity" {
            return
        }
        
        // If we must fall back to AppleScript focus bouncing (e.g. for long text),
        // we wait 0.35s first to allow the HUD's disappearance animation to complete smoothly
        // without being interrupted by macOS space/window switching.
        Thread.sleep(forTimeInterval: 0.35)
        bounceFocusAndSendText(text: text, prefixKey: prefixKey, targetApp: targetApp)
    }

    private nonisolated func bounceFocusAndSendText(text: String, prefixKey: String?, targetApp: NSRunningApplication) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let targetPid = targetApp.processIdentifier
        
        let switchBack: @Sendable () -> Void = {
            if let prev = previousApp, prev.processIdentifier != targetPid {
                Thread.sleep(forTimeInterval: 0.05)
                if #available(macOS 14.0, *), let url = prev.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
                } else {
                    prev.activate(options: .activateIgnoringOtherApps)
                }
            }
        }
        
        let injectAction: @Sendable () -> Void = {
            // Wait up to 1 second for app to become active
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            // Give the Electron app extra time to restore its blinking cursor
            Thread.sleep(forTimeInterval: 0.3)
            
            var scriptSource = "tell application \"System Events\"\n"
            
            if let prefix = prefixKey {
                scriptSource += "    keystroke \"\(prefix)\"\n"
                scriptSource += "    delay 0.1\n"
                scriptSource += "    key code 36\n"
                scriptSource += "    delay 0.3\n"
            }
            
            if text.count <= 3 && text.allSatisfy({ $0.isASCII }) && !text.contains("\n") {
                scriptSource += """
                    keystroke "\(text)"
                    delay 0.1
                    key code 36
                end tell
                """
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                scriptSource += """
                    keystroke "v" using command down
                    delay 0.1
                    key code 36
                end tell
                """
            }
            
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&error)
                if let error = error {
                    print("AppleScript typing error: \(error)")
                }
            }
            
            switchBack()
        }

        if #available(macOS 14.0, *), let url = targetApp.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    injectAction()
                }
            }
        } else {
            targetApp.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.global(qos: .userInitiated).async {
                injectAction()
            }
        }
    }
}
