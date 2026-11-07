import Foundation

/// One-time carry-over of ordinary settings from the old bundle id
/// (`com.antigravity.AgentIsland`) to the current one, so renaming the bundle
/// id does not reset the user's theme, layout, enabled assistants and viewed
/// marks. Anything that is an authorization is deliberately left behind: the
/// Antigravity reply consent and the pre-validation switch that depends on it
/// must be given again under the new identity, never copied silently.
enum PreferenceMigration {
    static let legacyDomain = "com.antigravity.AgentIsland"
    static let doneKey = "migratedFromLegacyBundleID"
    static let notCarriedOver: Set<String> = ["antigravityLocalReplyConsent", "antigravityPrevalidationEnabled"]

    /// Returns the keys that were copied.
    @discardableResult
    static func run(from legacy: UserDefaults?, into target: UserDefaults, legacyName: String = legacyDomain) -> [String] {
        guard !target.bool(forKey: doneKey) else { return [] }
        target.set(true, forKey: doneKey)
        guard let legacy, let old = legacy.persistentDomain(forName: legacyName) else { return [] }
        var copied: [String] = []
        for (key, value) in old where !notCarriedOver.contains(key) && target.object(forKey: key) == nil {
            target.set(value, forKey: key)
            copied.append(key)
        }
        return copied.sorted()
    }

    /// Only the real app (not a test host or the isolated preview) migrates.
    static func runForCurrentApp() {
        guard Bundle.main.bundleIdentifier == "io.github.r3dra1n.AgentIsland" else { return }
        run(from: .standard, into: .standard)
    }
}
