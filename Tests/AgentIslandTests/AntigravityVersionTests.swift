import XCTest
@testable import AgentIsland

final class AntigravityVersionTests: XCTestCase {
    func testOnlyExplicitlyAllowedVersionsAreEligibleForConnection() {
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.27.0"))
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.28.0"))
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.28.2"))
        XCTAssertTrue(AntigravityLocalTransport.supportsVersion("2.29.0"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.28.1"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.28.3"))
        // Near versions stay refused: an allowed version is one that was
        // actually checked, never one that is merely close to a checked one.
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.29.1"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion("2.30.0"))
        XCTAssertFalse(AntigravityLocalTransport.supportsVersion(""))
        XCTAssertNoThrow(try AntigravityLocalTransport.requireSupportedVersion("2.28.2"))
        XCTAssertThrowsError(try AntigravityLocalTransport.requireSupportedVersion("2.28.3")) { error in
            guard case AntigravityLocalTransport.Failure.unsupported = error else { return XCTFail("Expected unsupported version") }
        }
    }
}
