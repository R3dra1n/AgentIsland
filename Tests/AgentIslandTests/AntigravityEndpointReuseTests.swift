import Foundation
import XCTest
@testable import AgentIsland

final class AntigravityEndpointReuseTests: XCTestCase {
    private actor Calls {
        var discoveries = 0
        var validations = 0
        func discovered() { discoveries += 1 }
        func validated() { validations += 1 }
    }

    private enum FixtureError: Error { case rejected }
    private let endpoint = AntigravityLocalTransport.Endpoint(pid: 123, port: 1234, certificate: Data([1, 2, 3]))

    func testPreparedEndpointIsRevalidatedWithoutRediscovery() async throws {
        let calls = Calls(), endpoint = endpoint
        let result = try await AntigravityLocalTransport.endpointForReply(prepared: endpoint,
            discover: { await calls.discovered(); return endpoint },
            revalidate: { value in XCTAssertEqual(value, endpoint); await calls.validated() })
        XCTAssertEqual(result, endpoint)
        let discoveries = await calls.discoveries, validations = await calls.validations
        XCTAssertEqual(discoveries, 0)
        XCTAssertEqual(validations, 1)
    }

    func testFailedValidationNeverFallsBackToAnotherEndpoint() async throws {
        let calls = Calls(), endpoint = endpoint
        do {
            _ = try await AntigravityLocalTransport.endpointForReply(prepared: endpoint,
                discover: { await calls.discovered(); return endpoint },
                revalidate: { _ in await calls.validated(); throw FixtureError.rejected })
            XCTFail("A failed validation must stop the reply")
        } catch FixtureError.rejected { }
        let discoveries = await calls.discoveries, validations = await calls.validations
        XCTAssertEqual(discoveries, 0)
        XCTAssertEqual(validations, 1)
    }

    func testWithoutPreparedEndpointDiscoversOne() async throws {
        let calls = Calls(), endpoint = endpoint
        let result = try await AntigravityLocalTransport.endpointForReply(prepared: nil,
            discover: { await calls.discovered(); return endpoint },
            revalidate: { _ in await calls.validated() })
        XCTAssertEqual(result, endpoint)
        let discoveries = await calls.discoveries, validations = await calls.validations
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(validations, 0)
    }
}
