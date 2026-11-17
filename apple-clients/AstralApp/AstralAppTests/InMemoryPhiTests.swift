// Verifies the in-memory kernel's PHI book follows the real kernel's states, refusals and attended flag.
// Each test names the kernel code it expects, so a drift from the real kernel's codes shows up here.

import XCTest

@testable import AstralDeep

final class InMemoryPhiTests: XCTestCase {
    private static let phone = "sha256:" + String(repeating: "d", count: 64)
    private static let old = "sha256:" + String(repeating: "e", count: 64)

    private func make(hasMesh: Bool = true) -> InMemoryMeshKernel {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: hasMesh)
        if hasMesh {
            kernel.setMembers([
                kernel.localMember,
                MeshMember(
                    memberId: Self.phone, label: "Phone", kind: .pocket, isThisDevice: false, lastSeen: nil,
                    path: .none),
                MeshMember(
                    memberId: Self.old, label: "Old phone", kind: .pocket, isThisDevice: false, lastSeen: nil,
                    path: .none),
            ])
            kernel.phiBook.markNotUpgraded(Self.old)
        }
        return kernel
    }

    private func expect(_ code: String, line: UInt = #line, _ work: () throws -> Void) {
        do {
            try work()
            XCTFail("expected \(code)", line: line)
        } catch {
            XCTAssertEqual((error as? MeshKernelError)?.code, code, line: line)
        }
    }

    private func provider(_ url: String, name: String = "Notes") -> String {
        #"{"base_url":"\#(url)","name":"\#(name)","source":"provider"}"#
    }

    func testAdoptionIncludesUpgradedDevicesAndLeavesTheOldOneOut() throws {
        let kernel = make()
        XCTAssertFalse(try kernel.phiGroup().isAdopted)
        XCTAssertEqual(try kernel.phiGroup().pending.count, 2)
        let group = try kernel.adoptPhiGroup()
        XCTAssertTrue(group.isAdopted)
        let states = Dictionary(uniqueKeysWithValues: group.members.map { ($0.deviceId, $0.state) })
        XCTAssertEqual(states[Self.phone], .included)
        XCTAssertEqual(states[Self.old], .notUpgraded)
        XCTAssertEqual(group.pending, [])
    }

    func testExclusionAndReinclusionMoveOneDevice() throws {
        let kernel = make()
        _ = try kernel.adoptPhiGroup()
        let excluded = try kernel.excludePhiDevice(deviceId: Self.phone)
        XCTAssertEqual(excluded.members.first { $0.deviceId == Self.phone }?.state, .excluded)
        let back = try kernel.includePhiDevice(deviceId: Self.phone)
        XCTAssertEqual(back.members.first { $0.deviceId == Self.phone }?.state, .included)
        expect("phi_group.unknown_device") { _ = try kernel.excludePhiDevice(deviceId: "nobody") }
        XCTAssertEqual(
            try kernel.includePhiDevice(deviceId: Self.old).members.first { $0.deviceId == Self.old }?.state,
            .notUpgraded)
    }

    func testEverythingNeedsAMesh() {
        let kernel = make(hasMesh: false)
        expect("mesh.not_enrolled") { _ = try kernel.phiGroup() }
        expect("mesh.not_enrolled") { _ = try kernel.adoptPhiGroup() }
        expect("mesh.not_enrolled") { _ = try kernel.proposePhiDestination(source: provider("https://a.example")) }
    }

    func testAnOutsideProviderNeedsApprovalAndCarriesThreeFacts() throws {
        let kernel = make()
        let proposal = try kernel.proposePhiDestination(source: provider("HTTPS://API.Example/v1/"))
        XCTAssertEqual(proposal.kind, .model)
        XCTAssertEqual(proposal.target, "https://api.example/v1")
        XCTAssertEqual(proposal.subject, "https://api.example/v1")
        XCTAssertTrue(proposal.needsApproval)
        XCTAssertEqual(proposal.facts, [.notOwnerRun, .leavesDevices, .unseenHandling])
        XCTAssertFalse(kernel.phiDestinationAllowed(kind: .model, target: proposal.target))
        try kernel.approvePhiDestination(proposal)
        XCTAssertTrue(kernel.phiDestinationAllowed(kind: .model, target: proposal.target))
        let rows = try kernel.phiDestinations().destinations
        XCTAssertEqual(rows.map(\.status), [.approved])
        XCTAssertEqual(rows.first?.approvedBy, kernel.localMember.memberId)
        try kernel.revokePhiDestination(subject: proposal.subject ?? "")
        XCTAssertFalse(kernel.phiDestinationAllowed(kind: .model, target: proposal.target))
        XCTAssertEqual(try kernel.phiDestinations().destinations.map(\.status), [.revoked])
    }

    func testALoopbackModelNeedsNoApprovalAndCannotBeApproved() throws {
        let kernel = make()
        let proposal = try kernel.proposePhiDestination(source: provider("http://127.0.0.1:8080/v1"))
        XCTAssertFalse(proposal.needsApproval)
        XCTAssertNil(proposal.subject)
        XCTAssertEqual(proposal.facts, [])
        expect("phi_destination.on_device") { try kernel.approvePhiDestination(proposal) }
    }

    func testALoopbackServiceIsBoundToItsDeviceAndAContactCannotBeApproved() throws {
        let kernel = make()
        let source = #"{"endpoint":"http://localhost:9000","name":"Local","source":"legacy_server"}"#
        let service = try kernel.proposePhiDestination(source: source)
        XCTAssertEqual(service.kind, .service)
        XCTAssertTrue(service.target.hasPrefix("local:" + kernel.localMember.memberId + ":"))
        XCTAssertTrue(service.needsApproval)
        let contact = try kernel.proposePhiDestination(source: #"{"mesh_id":"m1","name":"Ana","source":"contact"}"#)
        XCTAssertEqual(contact.subject, "contact:m1")
        expect("phi_destination.contact_unavailable") { try kernel.approvePhiDestination(contact) }
    }

    func testBadSourcesAreRefusedWithTheKernelCodes() throws {
        let kernel = make()
        expect("phi_destination.malformed") { _ = try kernel.proposePhiDestination(source: "nope") }
        expect("phi_destination.malformed") {
            _ = try kernel.proposePhiDestination(source: #"{"name":"x","source":"other"}"#)
        }
        expect("phi_destination.invalid_endpoint") {
            _ = try kernel.proposePhiDestination(source: provider("https://a.example/v1?key=1"))
        }
        let connection =
            #"{"confined":true,"endpoint":"https://a.example","name":"C","source":"connection","use":"service"}"#
        expect("phi_destination.malformed") { _ = try kernel.proposePhiDestination(source: connection) }
        let open = #"{"confined":false,"name":"C","source":"connection","use":"service"}"#
        expect("phi_destination.no_target") { _ = try kernel.proposePhiDestination(source: open) }
        expect("phi_destination.not_approved") { try kernel.revokePhiDestination(subject: "https://a.example") }
    }

    func testProposalsFromRecordsNeedTheRecord() throws {
        let kernel = make()
        expect("provider.not_found") { _ = try kernel.proposeProviderPhiDestination(name: "nope") }
        expect("mcp.server_missing") { _ = try kernel.proposeLegacyPhiDestination(name: "nope") }
        expect("connection.not_found") { _ = try kernel.proposeConnectionPhiDestination(id: "nope", usage: "model") }
    }

    func testSendsRecordWhetherTheOwnerWasPresent() throws {
        let kernel = make()
        let chat = try kernel.createChat(title: "t")
        _ = try kernel.sendMessage(chatId: chat, text: "a", continues: nil, attachments: [])
        _ = try kernel.sendMessage(chatId: chat, text: "b", continues: nil, attachments: [], attended: true)
        _ = try kernel.addAttachment(chatId: chat, bytes: Data([1]), mime: "text/plain", name: "n.txt")
        _ = try kernel.addAttachment(
            chatId: chat, bytes: Data([1]), mime: "text/plain", name: "m.txt", attended: true)
        XCTAssertEqual(kernel.attendedFlags, [false, true, false, true])
    }

    func testStatusReportsWhatTheScreenCounted() throws {
        let kernel = make()
        let counted = MeshPhiStatus(modelPresent: true, screened: 3, overBudget: 1, failed: 0)
        kernel.phiBook.setStatus(counted)
        XCTAssertEqual(try kernel.phiStatus(), counted)
        XCTAssertFalse(try kernel.rotateStalePhiEpoch())
    }
}
