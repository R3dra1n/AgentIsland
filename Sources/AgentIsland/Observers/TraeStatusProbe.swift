import AppKit
import ApplicationServices

/// Trae IDE currently exposes no verified lifecycle hook on this installation.
/// Only explicit visible controls are evidence; absence is unknown, never completion.
enum TraeStatusProbe {
    @MainActor static func inspect() async -> ObserverSnapshot {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.lastPathComponent == "Trae.app" }) else {
            return .init(state: .unknown, description: "Trae 未运行", lastActiveDate: nil)
        }
        guard AXIsProcessTrusted() else { return .init(state: .unknown, description: "Trae 界面监控需要辅助功能权限", lastActiveDate: nil) }
        let pid = app.processIdentifier
        return await Task.detached {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.2)
            var labels = Set<String>(), count = 0
            let deadline = Date().addingTimeInterval(0.8)
            func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
                return value
            }
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 35, count < 2500, Date() < deadline else { return }
                count += 1
                if attr(element, kAXRoleAttribute) as? String == kAXButtonRole,
                   attr(element, kAXEnabledAttribute) as? Bool == true {
                    for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                        if let label = attr(element, key) as? String { labels.insert(label.lowercased()) }
                    }
                }
                for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
            }
            visit(root, depth: 0)
            if !labels.isDisjoint(with: ["allow once", "允许一次", "仅允许本次"]) {
                return ObserverSnapshot(state: .awaitingInput, description: "Trae 界面检测到待确认操作，请在原应用处理", lastActiveDate: Date())
            }
            if !labels.isDisjoint(with: ["stop generating", "停止生成", "stop response", "停止回答"]) {
                return ObserverSnapshot(state: .running, description: "Trae 正在生成（界面监控）", lastActiveDate: Date())
            }
            return ObserverSnapshot(state: .unknown, description: "Trae 实验性界面监控：未发现明确任务状态", lastActiveDate: nil)
        }.value
    }
}
