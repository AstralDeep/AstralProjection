// Verifies that issuer-authenticated push publishers cannot claim an accountless mesh principal.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class MeshPushBindingTests: XCTestCase {
    func testAccountlessMeshCannotPrepareOrPublishAnIssuerBoundPushRoute() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let owner = try XCTUnwrap(ConversationAccount(issuer: "https://issuer.example", subject: "owner"))
        h.kernel.setMeshPrincipal(MeshVerifiedPrincipal(meshId: h.runtime.status.meshId!))
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        XCTAssertNil(prepared)
        let forged = MeshPushContext(
            owner: owner, meshId: h.runtime.status.meshId!, deviceId: h.runtime.status.deviceId!, meshSession: UUID())
        let current = await h.runtime.meshPushContextCurrent(forged)
        XCTAssertFalse(current)
        let published = await h.runtime.publishMeshWakeRoute(
            forged, route: MeshWakeRoute(publisher: "astral", capability: "opaque", expiresAtMS: Int64.max))
        XCTAssertFalse(published)
        let cleared = await h.runtime.publishMeshWakeRoute(forged, route: nil)
        XCTAssertFalse(cleared)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "createChat" || $0.name == "setWakeRoute" })
    }
}
