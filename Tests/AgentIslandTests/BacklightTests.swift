import XCTest
@testable import AgentIsland

@MainActor
final class FakeBacklight: BacklightDevice {
    var isAvailable = true
    var level: Float = 0.4
    var auto = true
    var failWrites = false
    var writes: [Float] = []
    func getBrightness() -> Float? { level }
    func setBrightness(_ value: Float) -> Bool {
        guard !failWrites else { return false }
        level = value; writes.append(value); return true
    }
    func getAutoBrightness() -> Bool? { auto }
    func setAutoBrightness(_ enabled: Bool) -> Bool { auto = enabled; return true }
}

final class BacklightTests: XCTestCase {
    @MainActor func testDisableCancelsQueuedAnimationAndRestores() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = FakeBacklight()
        let engine = BacklightEngine(device: device, defaults: defaults)
        engine.setMode(.flashing)
        XCTAssertFalse(device.auto)
        engine.isEnabled = false
        XCTAssertEqual(device.level, 0.4)
        XCTAssertTrue(device.auto)
        let writes = device.writes.count
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(device.writes.count, writes)
        engine.shutdown()
    }

    @MainActor func testNewAcquisitionSnapshotsLatestUserBrightness() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = FakeBacklight()
        let engine = BacklightEngine(device: device, defaults: defaults)
        engine.setMode(.dimmed); engine.setMode(.idle)
        device.level = 0.7
        engine.setMode(.steadyBright); engine.setMode(.idle)
        XCTAssertEqual(device.level, 0.7)
        XCTAssertTrue(device.auto)
        engine.shutdown()
    }

    @MainActor func testManualAdjustmentIsPreservedAndReleasesControl() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = FakeBacklight()
        let engine = BacklightEngine(device: device, defaults: defaults)
        engine.setMode(.dimmed)
        device.level = 0.6
        XCTAssertTrue(engine.checkManualOverride())
        XCTAssertEqual(device.level, 0.6)
        XCTAssertTrue(device.auto)
        engine.setMode(.steadyBright)
        XCTAssertEqual(device.level, 0.6)
        engine.shutdown()
    }

    @MainActor func testCrashRecoveryAndSleep() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = BacklightSnapshot(brightness: 0.65, automatic: true)
        defaults.set(try JSONEncoder().encode(saved), forKey: "backlightRecoverySnapshot")
        let device = FakeBacklight()
        let engine = BacklightEngine(device: device, defaults: defaults)
        XCTAssertEqual(device.level, 0.65)
        XCTAssertNil(defaults.data(forKey: "backlightRecoverySnapshot"))
        engine.setMode(.dimmed); engine.suspend()
        XCTAssertEqual(device.level, 0.65)
        engine.resume()
        XCTAssertEqual(device.level, 0.1)
        engine.shutdown()
        XCTAssertEqual(device.level, 0.65)
    }

    @MainActor func testFailedRestoreRetainsRecoveryRecord() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = FakeBacklight()
        let engine = BacklightEngine(device: device, defaults: defaults)
        engine.setMode(.dimmed)
        device.failWrites = true
        engine.shutdown()
        XCTAssertNotNil(defaults.data(forKey: "backlightRecoverySnapshot"))
    }
}
