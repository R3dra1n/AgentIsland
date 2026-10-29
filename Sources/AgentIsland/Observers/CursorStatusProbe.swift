import AppKit
import ApplicationServices

enum CursorStatusProbe {
    @MainActor static func inspect() async -> ObserverSnapshot {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains("Cursor") }) else {
            return .init(state: .unknown, description: "Cursor 未运行", lastActiveDate: nil)
        }
        guard AXIsProcessTrusted() else { 
            return .init(state: .unknown, description: "Cursor 界面监控需要辅助功能权限", lastActiveDate: nil) 
        }
        
        let pid = app.processIdentifier
        return await Task.detached {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.2)
            var labels = Set<String>()
            var count = 0
            let deadline = Date().addingTimeInterval(0.8)
            
            func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
                return value
            }
            
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 35, count < 2500, Date() < deadline else { return }
                count += 1
                
                let role = attr(element, kAXRoleAttribute) as? String
                let enabled = attr(element, kAXEnabledAttribute) as? Bool ?? true
                if role == kAXButtonRole, enabled {
                    if let label = attr(element, kAXTitleAttribute) as? String { labels.insert(label.lowercased()) }
                    if let desc = attr(element, kAXDescriptionAttribute) as? String { labels.insert(desc.lowercased()) }
                }
                
                for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { 
                    visit(child, depth: depth + 1) 
                }
            }
            
            visit(root, depth: 0)
            
            let allowKeywords: Set<String> = [
                "accept", "accept all", "apply", "save all", "接受", "应用"
            ]
            let stopKeywords: Set<String> = [
                "stop generating", "停止生成"
            ]
            
            if !labels.isDisjoint(with: allowKeywords) {
                return ObserverSnapshot(state: .awaitingInput, description: "Cursor 界面检测到待确认操作", lastActiveDate: Date(), actionDetail: "⌘+Enter 接受")
            }
            
            if !labels.isDisjoint(with: stopKeywords) {
                return ObserverSnapshot(state: .running, description: "Cursor 正在生成代码...", lastActiveDate: Date())
            }
            
            return ObserverSnapshot(state: .idle, description: "待命", lastActiveDate: nil)
        }.value
    }
}
