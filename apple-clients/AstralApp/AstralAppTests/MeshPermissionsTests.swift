// Verifies the tool permissions state in MeshRuntime over an in-memory kernel: the listed tools, granting through the consent gate, revoking at once, and the grants remembered for this mesh.
// The real consent sheet content is covered in KernelMappingTests and RealMeshKernelTests.

@testable import AstralDeep
import XCTest

@MainActor
final class MeshPermissionsTests: XCTestCase {
    private let peer = "sha256:" + String(repeating: "c", count: 64)

    private func ready() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        h.defaults.removeObject(forKey: "astral.mesh.granted-tools.")
        await h.runtime.open()
        h.kernel.setTools([
            MeshToolEntry(name: "current_datetime", summary: "Time.", effect: .meshRead, deviceId: nil),
            MeshToolEntry(name: "mail.send", summary: "Sends mail.", effect: .outsideEffect, deviceId: nil),
            MeshToolEntry(name: "calendar.read", summary: "Reads it.", effect: .outwardRead, deviceId: peer),
        ])
        await h.runtime.refreshTools()
        return h
    }

    func testToolsAreListedForThisDeviceAndOthers() async {
        let h = await ready()
        defer { h.cleanUp() }
        XCTAssertEqual(h.runtime.toolEntries.map(\.name), ["current_datetime", "mail.send", "calendar.read"])
        XCTAssertEqual(h.runtime.toolEntries.map(\.scope), ["mesh_read", "outside_effect", "outward_read"])
        XCTAssertEqual(Set(h.runtime.toolEntries.map(\.id)).count, 3)
        XCTAssertTrue(h.runtime.grantedTools.isEmpty)
    }

    func testGrantAsksTheKernelAndIsRememberedForThisMesh() async throws {
        let h = await ready()
        defer { h.cleanUp() }
        let mail = try XCTUnwrap(h.runtime.toolEntries.first { $0.name == "mail.send" })
        await h.runtime.grant(mail)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "grantTool", detail: "mail.send|outside_effect")))
        XCTAssertTrue(h.runtime.isGranted(mail))
        XCTAssertEqual(h.kernel.grants, ["mail.send/outside_effect"])
        XCTAssertNil(h.runtime.notice)
        h.runtime.closeChat()
        await h.runtime.refreshTools()
        XCTAssertTrue(h.runtime.isGranted(mail))
        let other = try XCTUnwrap(h.runtime.toolEntries.first { $0.name == "current_datetime" })
        XCTAssertFalse(h.runtime.isGranted(other))
    }

    func testADeniedApprovalGrantsNothingAndSaysSo() async throws {
        let h = await ready()
        defer { h.cleanUp() }
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        let mail = try XCTUnwrap(h.runtime.toolEntries.first { $0.name == "mail.send" })
        await h.runtime.grant(mail)
        XCTAssertFalse(h.runtime.isGranted(mail))
        XCTAssertTrue(h.kernel.grants.isEmpty)
        XCTAssertEqual(h.runtime.notice, "The approval was denied.")
    }

    func testRevokeIsImmediateAndNeedsNoApproval() async throws {
        let h = await ready()
        defer { h.cleanUp() }
        let mail = try XCTUnwrap(h.runtime.toolEntries.first { $0.name == "mail.send" })
        await h.runtime.grant(mail)
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        await h.runtime.revoke(mail)
        XCTAssertFalse(h.runtime.isGranted(mail))
        XCTAssertTrue(h.kernel.grants.isEmpty)
        XCTAssertNil(h.runtime.notice)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "revokeTool", detail: "mail.send|outside_effect")))
    }

    func testAKernelRefusalLeavesTheLocalRecordAlone() async throws {
        let h = await ready()
        defer { h.cleanUp() }
        let bad = MeshToolEntry(name: "", summary: "", effect: .meshRead, deviceId: nil)
        await h.runtime.grant(bad)
        XCTAssertEqual(h.runtime.notice, "That tool name or permission could not be used.")
        XCTAssertTrue(h.runtime.grantedTools.isEmpty)
        h.runtime.notice = nil
        await h.runtime.revoke(bad)
        XCTAssertEqual(h.runtime.notice, "That tool name or permission could not be used.")
    }

    func testRevokeWorksForAGrantMadeElsewhere() async throws {
        let h = await ready()
        defer { h.cleanUp() }
        let calendar = try XCTUnwrap(h.runtime.toolEntries.first { $0.deviceId == peer })
        XCTAssertFalse(h.runtime.isGranted(calendar))
        await h.runtime.revoke(calendar)
        XCTAssertNil(h.runtime.notice)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "revokeTool", detail: "calendar.read|outward_read")))
    }
}
