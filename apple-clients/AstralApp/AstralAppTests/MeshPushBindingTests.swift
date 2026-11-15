// Exercises publisher bindings against verified native identity and exact runtime sessions without opening a chat.
// The in-memory facade controls suspension, Stop and failures while the real route facade is covered separately.

import AstralCore
@testable import AstralDeep
import XCTest

@MainActor
final class MeshPushBindingTests: XCTestCase {
    private let owner = ConversationAccount(issuer: "https://issuer.example", subject: "owner")!

    private func prepare() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        h.kernel.setMeshPrincipal(
            MeshVerifiedPrincipal(
                meshId: h.runtime.status.meshId!,
                identities: [MeshVerifiedIdentity(issuer: owner.issuer, subject: owner.subject)]))
        return h
    }

    private var route: MeshWakeRoute {
        MeshWakeRoute(
            publisher: "astral", capability: "opaque_test_capability==",
            expiresAtMS: Int64(Date().timeIntervalSince1970 * 1000) + 60_000)
    }

    func testPreparationRequiresVerifiedOwnerAndCreatesNoChat() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        XCTAssertEqual(context.meshId, h.runtime.status.meshId)
        XCTAssertEqual(context.deviceId, h.runtime.status.deviceId)
        let value1 = await h.runtime.meshPushContextCurrent(context)
        XCTAssertTrue(value1)
        let wrong = ConversationAccount(issuer: owner.issuer, subject: "another-owner")!
        let value2 = await h.runtime.prepareMeshPush(owner: wrong)
        XCTAssertNil(value2)
        XCTAssertNil(h.runtime.currentChatId)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "createChat" || $0.name == "setWakeRoute" })
        await h.runtime.close()
    }

    func testStopRejectsUseAndPublicationButPermitsOwnCurrentWithdrawal() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        let value3 = await h.runtime.publishMeshWakeRoute(context, route: route)
        XCTAssertTrue(value3)
        let registered = try await h.kernel.wakeRoutes()
        XCTAssertEqual(registered.count, 1)
        await h.runtime.raiseStop()
        let value4 = await h.runtime.meshPushContextCurrent(context)
        XCTAssertFalse(value4)
        let value5 = await h.runtime.publishMeshWakeRoute(context, route: route)
        XCTAssertFalse(value5)
        let value6 = await h.runtime.publishMeshWakeRoute(context, route: nil)
        XCTAssertTrue(value6)
        await h.runtime.resumeStop()
        let value7 = try await h.kernel.wakeRoutes().isEmpty
        XCTAssertTrue(value7)
        await h.runtime.close()
    }

    func testRetiredContextCannotPublishOrClearReplacementKernel() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        await h.runtime.close()
        await h.runtime.open()
        h.kernel.setMeshPrincipal(
            MeshVerifiedPrincipal(
                meshId: h.runtime.status.meshId!,
                identities: [MeshVerifiedIdentity(issuer: owner.issuer, subject: owner.subject)]))
        let value8 = await h.runtime.meshPushContextCurrent(context)
        XCTAssertFalse(value8)
        let value9 = await h.runtime.publishMeshWakeRoute(context, route: route)
        XCTAssertFalse(value9)
        let value10 = await h.runtime.publishMeshWakeRoute(context, route: nil)
        XCTAssertFalse(value10)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "setWakeRoute" })
        await h.runtime.close()
    }

    func testSuspendedPreparationCannotReturnAnOldSession() async {
        let h = await prepare()
        defer { h.cleanUp() }
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.statusGate = { await gate.wait() }
        let pending = Task { await h.runtime.prepareMeshPush(owner: owner) }
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.close()
        gate.release()
        let value11 = await pending.value
        XCTAssertNil(value11)
    }

    func testPublicationFailureDoesNotReportSuccessOrRevealCapability() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        h.kernel.wakeRouteGate = { throw MeshKernelError.storage("Write failed") }
        let value12 = await h.runtime.publishMeshWakeRoute(context, route: route)
        XCTAssertFalse(value12)
        let value13 = try await h.kernel.wakeRoutes().isEmpty
        XCTAssertTrue(value13)
        XCTAssertNil(h.runtime.notice)
        XCTAssertFalse(String(describing: h.kernel.calls).contains(route.capability))
        await h.runtime.close()
    }

    func testRetirementDuringStatusLookupPreventsNativePublication() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        let old = h.kernel
        old.statusGate = { await gate.wait() }
        let pending = Task { await h.runtime.publishMeshWakeRoute(context, route: route) }
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.close()
        await h.runtime.open()
        gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        XCTAssertFalse(old.calls.contains { $0.name == "setWakeRoute" })
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "setWakeRoute" })
        await h.runtime.close()
    }

    func testSuspendedPublicationCannotReportSuccessForAReplacementSession() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.wakeRouteGate = { await gate.wait() }
        let pending = Task { await h.runtime.publishMeshWakeRoute(context, route: route) }
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.close()
        await h.runtime.open()
        gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "setWakeRoute" })
        await h.runtime.close()
    }

    func testRosterAuthorityChangeInvalidatesPublisherBindingEvenWhenPublicStatusIsUnchanged() async throws {
        let h = await prepare()
        defer { h.cleanUp() }
        let prepared = await h.runtime.prepareMeshPush(owner: owner)
        let context = try XCTUnwrap(prepared)
        let revision = h.runtime.meshAuthorityRevision
        let status = h.runtime.status
        h.kernel.setMeshPrincipal(nil)
        try h.kernel.renameDevice(memberId: context.deviceId, label: "Renamed device")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.status, status)
        XCTAssertNotEqual(h.runtime.meshAuthorityRevision, revision)
        let current = await h.runtime.meshPushContextCurrent(context)
        XCTAssertFalse(current)
        await h.runtime.close()
    }
}
