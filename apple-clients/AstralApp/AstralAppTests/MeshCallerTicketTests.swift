// Covers the caller ticket calls on the Mesh kernel API: the mapping between generated records and host types, and the in-memory kernel's refusals.
// The real kernel's refusals are covered in RealMeshKernelTests against one enrolled loopback kernel.

@testable import AstralDeep
import AstralKernel
import XCTest

final class MeshCallerTicketTests: XCTestCase {
    private let holder = MeshCallerTicketLimits.holderPrefix + "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let nodeId = "sha256:" + String(repeating: "c", count: 64)
    private let ticketId = "AAECAwQFBgcICQoLDA0ODw"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private struct Silent: MeshKernelListening {
        func onChange(_ change: MeshKernelChange) {}
    }

    private func kernel(clock: Clock = Clock(), hasMesh: Bool = true, nodeKind: MeshDeviceKind = .node)
        -> InMemoryMeshKernel
    {
        let kernel = InMemoryMeshKernel(listener: Silent(), hasMesh: hasMesh, clock: { clock.now })
        guard hasMesh else { return kernel }
        let local = kernel.localMember
        kernel.setMembers([
            local,
            MeshMember(
                memberId: nodeId, label: "Study node", kind: nodeKind, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        kernel.setNodeCatalog(nodeId, tools: ["current_datetime", "read_notes"])
        return kernel
    }

    private func mint(
        _ kernel: InMemoryMeshKernel, node: String? = nil, holder: String? = nil, label: String = "Lab script",
        tools: [String] = ["current_datetime"], a2a: Bool = false, lifetime: UInt64 = 3600
    ) throws -> MeshCallerTicket {
        try kernel.mintCallerTicket(
            nodeId: node ?? nodeId, holderKey: holder ?? self.holder, label: label, toolNames: tools, a2a: a2a,
            lifetimeSeconds: lifetime)
    }

    private func assertRefused(
        _ code: String, _ work: () throws -> Any, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? MeshKernelError, .refused(KernelMapping.failureText(code: code)), file: file, line: line)
        }
    }

    func testTicketMappingKeepsEveryField() {
        let native = AstralKernel.CallerTicket(
            id: ticketId, text: "astral-caller-ticket:v1:abc", label: "Lab script", node: nodeId,
            tools: ["a2a.message", "current_datetime"], issuedMs: 1_800_000_000_000, expiresMs: 1_800_003_600_500,
            revoked: true, expired: false)
        let mapped = KernelMapping.callerTicket(native)
        XCTAssertEqual(mapped.id, ticketId)
        XCTAssertEqual(mapped.text, "astral-caller-ticket:v1:abc")
        XCTAssertEqual(mapped.label, "Lab script")
        XCTAssertEqual(mapped.nodeId, nodeId)
        XCTAssertEqual(mapped.tools, ["a2a.message", "current_datetime"])
        XCTAssertEqual(mapped.issuedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(mapped.expiresAt, Date(timeIntervalSince1970: 1_800_003_600.5))
        XCTAssertTrue(mapped.revoked)
        XCTAssertFalse(mapped.expired)
    }

    func testRequestAndVerifiedCallerMappingRoundTrip() {
        let request = MeshCallerRequest(
            authorization: "ticket", proof: "proof", method: "POST", target: "/a2a", bodySha256: "digest",
            tool: "current_datetime")
        let native = KernelMapping.callerRequest(request)
        XCTAssertEqual(native.authorization, "ticket")
        XCTAssertEqual(native.proof, "proof")
        XCTAssertEqual(native.method, "POST")
        XCTAssertEqual(native.target, "/a2a")
        XCTAssertEqual(native.bodySha256, "digest")
        XCTAssertEqual(native.tool, "current_datetime")
        let bare = KernelMapping.callerRequest(
            MeshCallerRequest(
                authorization: "t", proof: nil, method: "GET", target: "/", bodySha256: "d", tool: nil))
        XCTAssertNil(bare.proof)
        XCTAssertNil(bare.tool)
        let verified = KernelMapping.verifiedCaller(
            AstralKernel.VerifiedCaller(
                id: ticketId, mesh: "mesh", device: "device", label: "Lab script", tool: nil,
                tools: ["current_datetime"], expiresMs: 2_000))
        XCTAssertEqual(
            verified,
            MeshVerifiedCaller(
                id: ticketId, meshId: "mesh", deviceId: "device", label: "Lab script", tool: nil,
                tools: ["current_datetime"], expiresAt: Date(timeIntervalSince1970: 2)))
    }

    func testCallerRefusalsKeepTheirCodeThroughErrorMapping() {
        for code in ["caller.revoked", "caller.wrong_node", "caller.tool_not_covered", "caller.replayed"] {
            for error in [
                KernelError.Verification(code: code, message: ""), KernelError.State(code: code, message: ""),
                KernelError.InvalidInput(code: code, message: ""), KernelError.Denied(code: code, message: ""),
            ] {
                XCTAssertEqual(
                    KernelMapping.error(error) as? MeshKernelError, .refused(KernelMapping.failureText(code: code)))
            }
        }
        XCTAssertEqual(
            KernelMapping.error(KernelError.Denied(code: "gate.mesh_stopped", message: "")) as? MeshKernelError,
            .stopped)
        XCTAssertEqual(
            KernelMapping.error(KernelError.Denied(code: "signer.denied", message: "")) as? MeshKernelError,
            .consentDenied)
        XCTAssertNotEqual(KernelMapping.failureText(code: "caller.revoked"), KernelMapping.failureText(code: "caller."))
    }

    func testMintListAndRevokeRoundTrip() throws {
        let clock = Clock()
        let kernel = kernel(clock: clock)
        let ticket = try mint(kernel, tools: ["read_notes", "current_datetime"], a2a: true, lifetime: 600)
        XCTAssertEqual(ticket.tools, ["a2a.message", "current_datetime", "read_notes"])
        XCTAssertEqual(ticket.nodeId, nodeId)
        XCTAssertEqual(ticket.expiresAt, clock.now.addingTimeInterval(600))
        XCTAssertEqual(try kernel.callerTickets().map(\.id), [ticket.id])
        XCTAssertFalse(try kernel.callerTickets()[0].revoked)
        clock.advance(601)
        XCTAssertTrue(try kernel.callerTickets()[0].expired)
        try kernel.revokeCallerTicket(id: ticket.id)
        try kernel.revokeCallerTicket(id: ticket.id)
        XCTAssertTrue(try kernel.callerTickets()[0].revoked)
        XCTAssertEqual(
            kernel.calls.map(\.name).filter { $0.contains("allerTicket") },
            [
                "mintCallerTicket", "callerTickets", "callerTickets", "callerTickets", "revokeCallerTicket",
                "revokeCallerTicket", "callerTickets",
            ])
    }

    func testMintRefusesWhatTheKernelRefuses() throws {
        let kernel = kernel()
        assertRefused("caller.wrong_node") {
            try self.mint(kernel, node: "sha256:" + String(repeating: "d", count: 64))
        }
        assertRefused("caller.malformed") { try self.mint(kernel, holder: "not-a-holder") }
        assertRefused("caller.malformed") {
            try self.mint(kernel, holder: MeshCallerTicketLimits.holderPrefix + "AAAA")
        }
        assertRefused("caller.malformed") { try self.mint(kernel, label: "") }
        assertRefused("caller.malformed") { try self.mint(kernel, label: String(repeating: "x", count: 65)) }
        assertRefused("caller.malformed") { try self.mint(kernel, label: "bad\nlabel") }
        assertRefused("caller.malformed") { try self.mint(kernel, label: "zero\u{200B}width") }
        XCTAssertNoThrow(try self.mint(kernel, label: String(repeating: "\u{1F600}", count: 64)))
        assertRefused("caller.malformed") { try self.mint(kernel, lifetime: 0) }
        assertRefused("caller.malformed") { try self.mint(kernel, lifetime: 2_592_001) }
        assertRefused("caller.malformed") { try self.mint(kernel, tools: []) }
        assertRefused("caller.malformed") { try self.mint(kernel, tools: ["current_datetime", "current_datetime"]) }
        assertRefused("caller.malformed") { try self.mint(kernel, tools: ["a2a.message"]) }
        assertRefused("caller.malformed") {
            try self.mint(kernel, tools: (0..<33).map { "tool_\($0)" })
        }
        assertRefused("caller.unknown_tool") { try self.mint(kernel, tools: ["delete_everything"]) }
        XCTAssertEqual(try mint(kernel, tools: [], a2a: true).tools, ["a2a.message"])
        XCTAssertEqual(try mint(kernel, lifetime: 2_592_000).tools, ["current_datetime"])
        XCTAssertEqual(try kernel.callerTickets().count, 3)
    }

    func testMintNeedsACatalogAndAMinterDevice() throws {
        let bare = kernel()
        let other = "sha256:" + String(repeating: "e", count: 64)
        bare.setMembers([
            bare.localMember,
            MeshMember(
                memberId: other, label: "Quiet node", kind: .node, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        assertRefused("caller.no_catalog") { try self.mint(bare, node: other) }
        let notANode = kernel(nodeKind: .pocket)
        assertRefused("caller.wrong_node") { try self.mint(notANode) }
        let nodeLocal = InMemoryMeshKernel(listener: Silent(), hasMesh: true)
        nodeLocal.setMembers([
            MeshMember(
                memberId: nodeLocal.localMember.memberId, label: "Node", kind: .node, isThisDevice: true, lastSeen: nil,
                path: .none)
        ])
        assertRefused("caller.wrong_minter") { try self.mint(nodeLocal) }
    }

    func testStoppedMeshAndMissingMeshAreRefusedAndDenialLeavesNothing() throws {
        let kernel = kernel()
        kernel.consentGate = { throw MeshKernelError.consentDenied }
        XCTAssertThrowsError(try mint(kernel)) { XCTAssertEqual($0 as? MeshKernelError, .consentDenied) }
        kernel.consentGate = {}
        XCTAssertEqual(try kernel.callerTickets(), [])
        try kernel.raiseStop()
        XCTAssertThrowsError(try mint(kernel)) { XCTAssertEqual($0 as? MeshKernelError, .stopped) }
        let none = self.kernel(hasMesh: false)
        assertRefused("mesh.not_enrolled") { try none.callerTickets() }
        assertRefused("mesh.not_enrolled") { try self.mint(none) }
        assertRefused("mesh.not_enrolled") { try none.revokeCallerTicket(id: self.ticketId) }
    }

    func testRevokeRefusesAMalformedId() {
        let kernel = kernel()
        for id in ["", "short", ticketId + "A", "AAECAwQFBgcICQoLDA0ODx", "AAECAwQFBgcICQoLDA0OD+"] {
            XCTAssertThrowsError(try kernel.revokeCallerTicket(id: id), id) {
                XCTAssertEqual($0 as? MeshKernelError, .refused(KernelMapping.failureText(code: "caller.malformed")))
            }
        }
    }

    private func servingNode(clock: Clock, hasMesh: Bool = true) -> InMemoryMeshKernel {
        let serving = InMemoryMeshKernel(listener: Silent(), hasMesh: hasMesh, clock: { clock.now })
        let me = serving.localMember
        serving.setMembers([
            MeshMember(
                memberId: me.memberId, label: "Node", kind: .node, isThisDevice: true, lastSeen: nil, path: .none)
        ])
        return serving
    }

    private func request(_ text: String, tool: String?) -> MeshCallerRequest {
        MeshCallerRequest(authorization: text, proof: nil, method: "POST", target: "/a2a", bodySha256: "d", tool: tool)
    }

    func testVerifyAdmitsACoveredToolAndRefusesTheRest() throws {
        let clock = Clock()
        let minter = kernel(clock: clock)
        let serving = servingNode(clock: clock)
        let servingId = serving.localMember.memberId
        minter.setMembers([
            minter.localMember,
            MeshMember(
                memberId: servingId, label: "Node", kind: .node, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        minter.setNodeCatalog(servingId, tools: ["current_datetime", "read_notes"])
        let issued = try mint(minter, node: servingId, tools: ["current_datetime"], a2a: true, lifetime: 60)
        serving.acceptCaller(issued)

        let caller = try serving.verifyCallerRequest(request(issued.text, tool: "current_datetime"))
        XCTAssertEqual(caller.id, issued.id)
        XCTAssertEqual(caller.label, "Lab script")
        XCTAssertEqual(caller.tool, "current_datetime")
        XCTAssertEqual(caller.tools, ["a2a.message", "current_datetime"])
        XCTAssertEqual(caller.expiresAt, issued.expiresAt)
        XCTAssertNoThrow(try serving.verifyCallerRequest(request(issued.text, tool: "a2a.message")))
        XCTAssertNoThrow(try serving.verifyCallerRequest(request(issued.text, tool: nil)))

        assertRefused("caller.tool_not_covered") {
            try serving.verifyCallerRequest(self.request(issued.text, tool: "read_notes"))
        }
        assertRefused("caller.malformed") { try serving.verifyCallerRequest(self.request("forged", tool: nil)) }

        let elsewhere = MeshCallerTicket(
            id: ticketId, text: "in-memory-caller-ticket:" + ticketId, label: "Other", nodeId: nodeId,
            tools: ["current_datetime"], issuedAt: clock.now, expiresAt: clock.now.addingTimeInterval(60),
            revoked: false, expired: false)
        serving.acceptCaller(elsewhere)
        assertRefused("caller.wrong_node") { try serving.verifyCallerRequest(self.request(elsewhere.text, tool: nil)) }

        try serving.revokeCallerTicket(id: issued.id)
        assertRefused("caller.revoked") { try serving.verifyCallerRequest(self.request(issued.text, tool: nil)) }
    }

    func testVerifyRefusesExpiredStoppedAndNonNodeServers() throws {
        let clock = Clock()
        let minter = kernel(clock: clock)
        let serving = servingNode(clock: clock)
        let servingId = serving.localMember.memberId
        minter.setMembers([
            minter.localMember,
            MeshMember(
                memberId: servingId, label: "Node", kind: .node, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        minter.setNodeCatalog(servingId, tools: ["current_datetime"])
        let issued = try mint(minter, node: servingId, lifetime: 60)
        serving.acceptCaller(issued)
        assertRefused("caller.wrong_node") { try minter.verifyCallerRequest(self.request(issued.text, tool: nil)) }
        clock.advance(61)
        assertRefused("caller.expired") { try serving.verifyCallerRequest(self.request(issued.text, tool: nil)) }
        let fresh = try mint(minter, node: servingId, lifetime: 3600)
        serving.acceptCaller(fresh)
        XCTAssertNoThrow(try serving.verifyCallerRequest(request(fresh.text, tool: nil)))
        try serving.raiseStop()
        assertRefused("caller.stopped") { try serving.verifyCallerRequest(self.request(fresh.text, tool: nil)) }
        let none = servingNode(clock: clock, hasMesh: false)
        assertRefused("mesh.not_enrolled") { try none.verifyCallerRequest(self.request(issued.text, tool: nil)) }
    }
}
