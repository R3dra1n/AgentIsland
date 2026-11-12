import Foundation
import ServiceManagement

/// "Open at login", through the system's own login items (System Settings →
/// General → Login Items), where the user can also see and remove it. Nothing
/// is registered unless the user turns the switch on.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The system wants the user to approve it in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns nil when it worked, otherwise what to tell the user.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "系统没有接受这个设置（\(error.localizedDescription)）。可以在「系统设置 → 通用 → 登录项」里手动添加或移除 AgentIsland。"
        }
        if enabled, needsApproval {
            return "已登记，但需要你在「系统设置 → 通用 → 登录项」里允许 AgentIsland 后才会生效。"
        }
        return nil
    }
}
