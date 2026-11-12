// Exercises the kernel through the Swift wrapper: opening with host custody, creating a mesh with a test issuer, reopening, refusal of wrong custody, header signing and the change stream.
// Every test runs on loopback with relays disabled so it never needs a network.
import XCTest

@testable import AstralKernel

final class KernelServiceTests: XCTestCase {
    private func headerJSON(feed: String) -> String {
        let body = "sha256:" + String(repeating: "0", count: 64)
        return
            "{\"v\":1,\"feed\":\"\(feed)\",\"seq\":1,\"prev\":null,\"after\":[],\"clock\":{\"ms\":1,\"n\":0},\"scope\":\"mesh\",\"type\":\"settings.set\",\"labels\":{\"integrity\":\"owner\",\"confidentiality\":\"private\"},\"key\":\"ck:AAAAAAAAAAAAAAAAAAAAAA\",\"body\":\"\(body)\"}"
    }

    func testVersionAndFreshStatus() async throws {
        XCTAssertFalse(AstralKernelInfo.version.isEmpty)
        let device = try TestDevice(label: "mac", in: self, marker: 1)
        let service = try device.open()
        XCTAssertEqual(service.version, AstralKernelInfo.version)
        let status = await service.kernel.meshStatus()
        XCTAssertEqual(status.state, .notEnrolled)
        XCTAssertNil(status.meshId)
        XCTAssertEqual(status.marker, .fresh)
        XCTAssertEqual(status.members, 0)
        XCTAssertTrue(try service.kernel.storeInfo().path.hasSuffix("kernel.sqlite3"))
    }

    func testCreatingAMeshPersistsChatsAcrossReopenAndRefusesWrongCustody() async throws {
        let device = try TestDevice(label: "mac", in: self, marker: 2)
        let service = try device.open()
        var iterator = service.changes().makeAsyncIterator()
        let request = try service.kernel.beginMeshCreation()
        XCTAssertEqual(request.nonce.count, 64)
        XCTAssertEqual(request.issuer, TestIssuer.issuer)
        let first = await iterator.next()
        XCTAssertEqual(first, .enrollment(state: .creating))
        let kit = try service.kernel.completeMeshCreation(
            idToken: TestIssuer.token(nonce: request.nonce, subject: "user-1"))
        XCTAssertEqual(kit.words.split(separator: " ").count, 24)
        XCTAssertEqual(kit.restoreMarker, device.marker)
        let chat = try service.kernel.createChat(title: "plan")
        let message = try service.kernel.sendMessage(chatId: chat, text: "hello", continues: nil)
        let detail = try service.kernel.chat(chatId: chat)
        XCTAssertEqual(detail.view.title, "plan")
        XCTAssertEqual(detail.view.messages.map(\.id), [message])
        XCTAssertEqual(detail.view.messages.first?.text, "hello")
        XCTAssertThrowsError(try service.kernel.sendMessage(chatId: chat, text: "  ", continues: nil))

        let again = try device.open()
        let status = await again.kernel.meshStatus()
        XCTAssertEqual(status.state, .enrolled)
        XCTAssertEqual(status.marker, .matches)
        XCTAssertEqual(try again.kernel.listChats().count, 1)
        XCTAssertThrowsError(try again.kernel.beginMeshCreation()) { error in
            guard case KernelError.State = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testReopenWithADifferentOperationsKeyOrMissingMarkerIsRefused() async throws {
        let device = try TestDevice(label: "mac", in: self, marker: 3)
        let service = try device.open()
        let request = try service.kernel.beginMeshCreation()
        _ = try service.kernel.completeMeshCreation(
            idToken: TestIssuer.token(nonce: request.nonce, subject: "user-1"))

        var wrongKey = device.config
        wrongKey.operationsSecret = try newOperationsSecret()
        XCTAssertThrowsError(try KernelService(config: wrongKey, signer: device.signer)) { error in
            guard case KernelError.Custody(let code, _) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(code, "custody.key_mismatch")
        }
        var noMarker = device.config
        noMarker.restoreMarker = nil
        XCTAssertThrowsError(try KernelService(config: noMarker, signer: device.signer)) { error in
            guard case KernelError.Custody(let code, _) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(code, "custody.restore_needs_new_keys")
        }
    }

    func testCreationRefusesATokenBoundToAnotherNonce() throws {
        let device = try TestDevice(label: "mac", in: self, marker: 4)
        let service = try device.open()
        XCTAssertThrowsError(try service.kernel.completeMeshCreation(idToken: "x.y.z"))
        _ = try service.kernel.beginMeshCreation()
        XCTAssertThrowsError(
            try service.kernel.completeMeshCreation(
                idToken: TestIssuer.token(nonce: String(repeating: "0", count: 64), subject: "user-1")))
    }

    func testSignVerifyRoundTripAndTamperRefusal() throws {
        let secret = try newOperationsSecret()
        let feed = try operationsPublicKey(secret: secret)
        let signed = try signEventHeader(headerJson: headerJSON(feed: feed), secret: secret)
        let verified = try verifyEventHeader(signedJson: signed)
        XCTAssertEqual(verified.feed, feed)
        XCTAssertEqual(verified.seq, 1)
        XCTAssertTrue(verified.eventId.hasPrefix("sha256:"))
        let tampered = signed.replacingOccurrences(of: "\"owner\"", with: "\"untrusted\"")
        XCTAssertThrowsError(try verifyEventHeader(signedJson: tampered)) { error in
            guard case KernelError.Verification = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertThrowsError(try signEventHeader(headerJson: "{", secret: secret)) { error in
            guard case KernelError.InvalidInput = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testEndpointStartsAndReportsStateChanges() async throws {
        let device = try TestDevice(label: "mac", in: self, marker: 5)
        let service = try device.open()
        let request = try service.kernel.beginMeshCreation()
        _ = try service.kernel.completeMeshCreation(
            idToken: TestIssuer.token(nonce: request.nonce, subject: "user-1"))
        var iterator = service.changes().makeAsyncIterator()
        let nodeId = try await service.kernel.startNetwork()
        XCTAssertFalse(nodeId.isEmpty)
        var states: [EndpointState] = []
        while states.last != .online(nodeId: nodeId) {
            guard let change = await iterator.next() else { return XCTFail("stream ended") }
            if case .endpoint(let state) = change { states.append(state) }
        }
        XCTAssertEqual(states.first, .starting)
        await service.kernel.stopNetwork()
        XCTAssertEqual(service.kernel.endpointState(), .stopped)
    }
}
