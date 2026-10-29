import SwiftUI

@main
struct AgentIslandApp: App {
    @NSApplicationDelegateAdaptor(LifecycleDelegate.self) private var lifecycle
    @StateObject private var appState = AppState()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
