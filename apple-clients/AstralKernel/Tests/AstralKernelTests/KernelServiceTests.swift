// Exercises the kernel through the Swift wrapper: store open, header sign and verify, tamper refusal and the local endpoint with its state stream.
// The tests use local-only networking so they never need a network.
import XCTest

@testable import AstralKernel

final class KernelServiceTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astral-kernel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func headerJSON(feed: String) -> String {
        let body = "sha256:" + String(repeating: "0", count: 64)
        return
            "{\"feed\":\"\(feed)\",\"seq\":0,\"prev\":null,\"after\":[],\"clock\":{\"ms\":1,\"n\":0},\"scope\":\"mesh\",\"type\":\"chat.message\",\"labels\":[],\"key\":\"mesh/1\",\"body\":\"\(body)\"}"
    }

    func testVersionAndStore() throws {
        XCTAssertFalse(AstralKernelInfo.version.isEmpty)
        let service = try KernelService(dataDirectory: makeDirectory(), localOnly: true)
        XCTAssertEqual(service.version, AstralKernelInfo.version)
        let info = try service.openStore()
        XCTAssertEqual(info.schemaVersion, 1)
        XCTAssertTrue(info.path.hasSuffix("kernel.sqlite3"))
    }

    func testSignVerifyRoundTripAndTamperRefusal() throws {
        let service = try KernelService(dataDirectory: makeDirectory(), localOnly: true)
        let secret = try service.newOperationsSecret()
        let feed = try service.operationsPublicKey(secret: secret)
        let signed = try service.signEventHeader(json: headerJSON(feed: feed), secret: secret)
        let verified = try service.verifyEventHeader(json: signed)
        XCTAssertEqual(verified.feed, feed)
        XCTAssertEqual(verified.seq, 0)
        XCTAssertTrue(verified.eventId.hasPrefix("sha256:"))
        let tampered = signed.replacingOccurrences(of: "\"mesh\"", with: "\"chat\"")
        XCTAssertThrowsError(try service.verifyEventHeader(json: tampered)) { error in
            guard case KernelError.Verification = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try service.signEventHeader(json: "{", secret: secret)) { error in
            guard case KernelError.InvalidInput = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testEndpointStartsAndReportsStateChanges() async throws {
        let service = try KernelService(dataDirectory: makeDirectory(), localOnly: true)
        var iterator = service.endpointStates().makeAsyncIterator()
        let nodeId = try await service.startEndpoint()
        XCTAssertFalse(nodeId.isEmpty)
        let starting = await iterator.next()
        XCTAssertEqual(starting, .starting)
        let online = await iterator.next()
        XCTAssertEqual(online, .online(nodeId: nodeId))
        let again = try await service.startEndpoint()
        XCTAssertEqual(again, nodeId)
        let address = try await service.endpointAddress()
        XCTAssertTrue(address.contains(nodeId))
        await service.stopEndpoint()
        let stopped = await iterator.next()
        XCTAssertEqual(stopped, .stopped)
    }

    func testEndpointIdentityIsStableAcrossRestarts() async throws {
        let directory = try makeDirectory()
        let first = try KernelService(dataDirectory: directory, localOnly: true)
        let id = try await first.startEndpoint()
        await first.stopEndpoint()
        let second = try KernelService(dataDirectory: directory, localOnly: true)
        let again = try await second.startEndpoint()
        XCTAssertEqual(id, again)
        await second.stopEndpoint()
    }
}
