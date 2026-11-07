import XCTest
@testable import AgentIsland

final class PreferenceMigrationTests: XCTestCase {
    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testCopiesOrdinarySettingsButNotAuthorizations() {
        let legacyName = "test.legacy.\(UUID().uuidString)", newName = "test.new.\(UUID().uuidString)"
        let legacy = suite(legacyName), target = suite(newName)
        legacy.set("深色模式", forKey: "appTheme")
        legacy.set(true, forKey: "claudeEnabled")
        legacy.set(true, forKey: "antigravityLocalReplyConsent")
        legacy.set(true, forKey: "antigravityPrevalidationEnabled")
        let copied = PreferenceMigration.run(from: legacy, into: target, legacyName: legacyName)
        XCTAssertEqual(copied, ["appTheme", "claudeEnabled"])
        XCTAssertEqual(target.string(forKey: "appTheme"), "深色模式")
        XCTAssertFalse(target.bool(forKey: "antigravityLocalReplyConsent"))
        XCTAssertFalse(target.bool(forKey: "antigravityPrevalidationEnabled"))
    }

    func testRunsOnlyOnceAndNeverOverwrites() {
        let legacyName = "test.legacy.\(UUID().uuidString)", newName = "test.new.\(UUID().uuidString)"
        let legacy = suite(legacyName), target = suite(newName)
        legacy.set("a", forKey: "appTheme")
        target.set("b", forKey: "appTheme")
        XCTAssertEqual(PreferenceMigration.run(from: legacy, into: target, legacyName: legacyName), [])
        XCTAssertEqual(target.string(forKey: "appTheme"), "b")
        legacy.set("c", forKey: "hudOpacity")
        XCTAssertEqual(PreferenceMigration.run(from: legacy, into: target, legacyName: legacyName), [])
        XCTAssertNil(target.object(forKey: "hudOpacity"))
    }

    func testViewedMarksArePersistedAndPrunedToTheNewest() {
        let key = "test.marks.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var marks: [String: Date] = [:]
        for i in 0..<10 { marks["s\(i)"] = Date(timeIntervalSince1970: Double(i)) }
        AppState.persistMarks(marks, key: key, limit: 4)
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Date]
        XCTAssertEqual(Set(saved?.keys.map { $0 } ?? []), ["s6", "s7", "s8", "s9"])
        AppState.persistMarks(["a": Date(timeIntervalSince1970: 1)], key: key)
        XCTAssertEqual((UserDefaults.standard.dictionary(forKey: key) as? [String: Date])?["a"], Date(timeIntervalSince1970: 1))
    }
}
