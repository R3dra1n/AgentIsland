import XCTest
@testable import AgentIsland

final class AntigravityVersionTests: XCTestCase {
    func testOnlyExplicitlyAllowedVersionsAreEligibleForConnection() {
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.27.0"))
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.28.0"))
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.28.2"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.28.1"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.28.3"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.29.0"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion(""))
    }
}
