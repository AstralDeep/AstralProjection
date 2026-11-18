// Verifies the "no mesh yet" refusal never becomes a notice while the device is onboarding or joining.
// A refresh races a join over the in-memory kernel and the runtime must stay silent.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshNotEnrolledTests: XCTestCase {
    func testRefusalDuringOnboardingProducesNoNotice() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.refreshCallerTickets()
        await h.runtime.refreshContacts()
        await h.runtime.refreshShares()
        await h.runtime.refreshSharedItems()
        await h.runtime.refreshConnections()
        XCTAssertNil(h.runtime.notice)
    }

    func testRefreshRacingAJoinProducesNoNotice() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        async let join: Void = h.runtime.beginJoin()
        async let refresh: Void = h.runtime.refreshCallerTickets()
        _ = await (join, refresh)
        XCTAssertNil(h.runtime.notice)
    }

    func testTheRefusalIsRecognisedByCodeAndByText() {
        XCTAssertTrue(MeshRuntime.isNotEnrolled(MeshKernelError.refused(code: "mesh.not_enrolled", message: "x")))
        XCTAssertTrue(MeshRuntime.isNotEnrolled(MeshKernelError.refused("mesh.not_enrolled")))
        XCTAssertFalse(MeshRuntime.isNotEnrolled(MeshKernelError.refused("other")))
    }
}
