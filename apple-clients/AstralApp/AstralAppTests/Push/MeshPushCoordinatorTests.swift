// Exercises the actual phone registration coordinator through suspended native and publisher callbacks, without network or APNs activity.

import AstralCore
import XCTest

#if canImport(AstralDeep)
    @testable import AstralDeep
#else
    @testable import MeshPushHarness
#endif

@MainActor
final class MeshPushCoordinatorTests: XCTestCase {
    func testVerifiedPhoneRegistersOnlyItsExactNativeTarget() async {
        let fixture = MeshPushFixture()
        fixture.start()
        await fixture.settle { fixture.coordinator.status == "Background updates registered" }
        XCTAssertEqual(fixture.requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(fixture.published.compactMap { $0?.publisher }, ["astral"])
        XCTAssertEqual(fixture.tokenRequests, [false, true])
        fixture.coordinator.unbind()
        await fixture.settle { fixture.requests.contains { $0.httpMethod == "DELETE" } }
    }

    func testAbsentSignInOrNativeProofDoesNotRegisterForAPNsOrPublisher() async {
        for missing in ["signin", "proof", "unconfigured"] {
            let fixture = MeshPushFixture(configured: missing != "unconfigured")
            fixture.signedIn = missing != "signin"
            fixture.current = missing != "proof"
            fixture.start()
            await fixture.settle { !fixture.coordinator.status.hasPrefix("Registering") }
            XCTAssertTrue(fixture.requests.isEmpty, missing)
            XCTAssertFalse(fixture.tokenRequests.contains(true), missing)
            fixture.coordinator.unbind()
        }
    }

    func testSessionReplacementDuringNativeAwaitCannotPublishOrRequestAPNs() async {
        let fixture = MeshPushFixture()
        fixture.suspendCurrent = true
        fixture.start()
        await fixture.settle { fixture.currentContinuation != nil }
        fixture.coordinator.unbind()
        fixture.currentContinuation?.resume(returning: true)
        fixture.currentContinuation = nil
        await fixture.drain()
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertFalse(fixture.tokenRequests.contains(true))
    }

    func testStaleRegistrationSuccessIsRevokedAndNeverPublished() async {
        let fixture = MeshPushFixture()
        fixture.suspendRegistration = true
        fixture.start()
        await fixture.settle { fixture.registerContinuation != nil }
        fixture.coordinator.unbind()
        fixture.registerContinuation?.resume()
        fixture.registerContinuation = nil
        await fixture.settle { fixture.requests.contains { $0.httpMethod == "DELETE" } }
        XCTAssertTrue(fixture.published.compactMap { $0 }.isEmpty)
    }

    func testFailureAfterNativePublishTriggersWithdrawalAndRemoteRevocation() async {
        let fixture = MeshPushFixture()
        fixture.rejectAfterPublish = true
        fixture.start()
        await fixture.settle { fixture.requests.contains { $0.httpMethod == "DELETE" } }
        await fixture.drain()
        XCTAssertTrue(fixture.published.contains { $0 == nil })
        XCTAssertFalse(fixture.coordinator.status == "Background updates registered")
    }

    func testRetiredCleanupCannotWithdrawAReplacementRoute() async {
        let fixture = MeshPushFixture()
        fixture.start()
        await fixture.settle { fixture.coordinator.status == "Background updates registered" }
        fixture.suspendRevoke = true
        fixture.coordinator.authenticationChanged()
        await fixture.settle { fixture.revokeContinuation != nil }
        XCTAssertEqual(fixture.published.compactMap { $0 }.count, 1)
        fixture.revokeContinuation?.resume()
        fixture.revokeContinuation = nil
        await fixture.settle { fixture.published.compactMap { $0 }.count == 2 }
        await fixture.drain()
        XCTAssertNotNil(fixture.published.last!)
        fixture.coordinator.unbind()
    }

    func testCredentialRefreshUpdatesTheConditionalRevocationCredential() async {
        let fixture = MeshPushFixture()
        fixture.start()
        await fixture.settle { fixture.coordinator.status == "Background updates registered" }
        fixture.access = "fresh-normal-access"
        fixture.coordinator.retry()
        await fixture.drain()
        fixture.coordinator.unbind()
        await fixture.settle { fixture.requests.contains { $0.httpMethod == "DELETE" } }
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-normal-access")
    }

    func testLostNativeOwnerProofRetiresThePreviouslyRegisteredCapability() async {
        let fixture = MeshPushFixture()
        fixture.start()
        await fixture.settle { fixture.coordinator.status == "Background updates registered" }
        fixture.current = false
        fixture.coordinator.retry()
        await fixture.settle { fixture.requests.contains { $0.httpMethod == "DELETE" } }
        XCTAssertFalse(fixture.coordinator.status == "Background updates registered")
        fixture.coordinator.unbind()
    }

    func testRegistrationRecoveryRevisitsSavedGenerationBeforeIssuingAnother() async {
        let fixture = MeshPushFixture()
        fixture.start()
        await fixture.settle { fixture.coordinator.status == "Background updates registered" }
        let replacement = fixture.makeCoordinator()
        fixture.install(replacement)
        await fixture.settle { fixture.requests.filter { $0.httpMethod == "POST" }.count == 2 }
        XCTAssertTrue(fixture.requests.dropFirst(2).contains { $0.httpMethod == "DELETE" })
        replacement.unbind()
        fixture.coordinator.unbind()
    }
}

@MainActor
private final class MeshPushFixture {
    let owner = ConversationAccount(issuer: "https://issuer.example/realms/owners", subject: "owner")!
    let mesh = "sha256:" + String(repeating: "a", count: 64)
    let device = "sha256:" + String(repeating: "b", count: 64)
    let session = UUID()
    let now: Int64 = 1_800_000_000_000
    let storage = InMemoryMeshKeyStorage()
    let configured: Bool
    var signedIn = true
    var access = "normal-access"
    var current = true
    var tokenRequests: [Bool] = []
    var requests: [URLRequest] = []
    var published: [MeshWakeRoute?] = []
    var revision = 0
    var suspendCurrent = false
    var suspendRegistration = false
    var suspendRevoke = false
    var rejectAfterPublish = false
    var currentContinuation: CheckedContinuation<Bool, Never>?
    var registerContinuation: CheckedContinuation<Void, Never>?
    var revokeContinuation: CheckedContinuation<Void, Never>?
    lazy var coordinator = makeCoordinator()

    init(configured: Bool = true) { self.configured = configured }

    func makeCoordinator() -> MeshPushCoordinator {
        let rest =
            configured
            ? MeshPushRest(
                publisherURL: URL(string: "https://publisher.example")!, now: { self.now },
                transport: { request in
                    await self.response(request)
                }) : nil
        let value = MeshPushCoordinator(rest: rest, storage: storage, now: { self.now })
        value.configure(
            credential: { self.signedIn ? MeshPushCredential(owner: self.owner, access: self.access) : nil },
            requestToken: { self.tokenRequests.append($0) })
        value.receivedToken("phone-token")
        return value
    }

    func start() { install(coordinator) }
    func install(_ value: MeshPushCoordinator) {
        value.bind(
            prepare: { owner in
                guard owner == self.owner, self.current else { return nil }
                return MeshPushContext(
                    owner: owner, meshId: self.mesh, deviceId: self.device, meshSession: self.session)
            },
            isCurrent: { _ in
                if self.suspendCurrent {
                    self.suspendCurrent = false
                    return await withCheckedContinuation { self.currentContinuation = $0 }
                }
                return self.current
            },
            publish: { _, route in
                self.published.append(route)
                if route != nil && self.rejectAfterPublish { self.current = false }
                return true
            })
    }

    func response(_ request: URLRequest) async -> (Int, Data) {
        requests.append(request)
        if request.httpMethod == "GET" { return (404, Data()) }
        if request.httpMethod == "DELETE" {
            if suspendRevoke {
                suspendRevoke = false
                await withCheckedContinuation { revokeContinuation = $0 }
            }
            return (200, Data())
        }
        if suspendRegistration { await withCheckedContinuation { registerContinuation = $0 } }
        revision += 1
        let body: [String: Any] = [
            "mesh_id": mesh, "device_id": device, "revision": revision,
            "route": [
                "publisher": "astral", "capability": "opaque_capability_\(revision)", "expires_at_ms": now + 82_800_000,
            ],
        ]
        return (200, try! JSONSerialization.data(withJSONObject: body))
    }

    func drain() async { for _ in 0..<100 { await Task.yield() } }
    func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(
            "expected state was not reached; status=\(coordinator.status) requests=\(requests.map { $0.httpMethod ?? "" }) publications=\(published.count)",
            file: file, line: line)
    }
}
