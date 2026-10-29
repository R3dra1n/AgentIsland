import Foundation
import SwiftUI

public struct AIObserverItem: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var icon: String
    public var isEnabled: Bool
    public var state: AIState
    public var description: String
    /// Rich context about the pending action (e.g. command to approve, question being asked)
    public var actionDetail: String?

    public init(id: String, name: String, icon: String, isEnabled: Bool, state: AIState, description: String, actionDetail: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isEnabled = isEnabled
        self.state = state
        self.description = description
        self.actionDetail = actionDetail
    }
}

public enum HUDDetailMode: String, CaseIterable, Sendable { 
    case concise = "简洁模式"
    case full = "完整模式"
}

public enum HUDLayoutMode: String, CaseIterable, Sendable {
    case horizontal = "横向排列"
    case vertical = "直列模式"
}

public enum HUDDisplayMode: String, CaseIterable, Sendable {
    case whenActive = "whenActive"
    case onlyAwaitingInput = "onlyAlert"
    case always = "always"

    public var title: String {
        switch self {
        case .whenActive: return "活动时显示(推荐)"
        case .onlyAwaitingInput: return "仅需审批时弹出"
        case .always: return "始终常驻显示"
        }
    }
}

public enum AppTheme: String, CaseIterable, Equatable, Sendable {
    case auto = "跟随系统"
    case light = "浅色模式"
    case dark = "深色模式"
    
    public var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
