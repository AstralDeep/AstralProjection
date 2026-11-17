// Verifies the PHI warning card, the adoption card, device exclusion and the offers a PHI refusal raises, through the models the views read.
// A fake service over the in-memory kernel stands in for MeshRuntime, so each test checks what one Kernel call received.

import XCTest

@testable import AstralDeep

@MainActor
private final class KernelPhiService: MeshPhiService {
    let kernel: InMemoryMeshKernel
    private(set) var approvals: [MeshPhiProposal] = []

    init(_ kernel: InMemoryMeshKernel) { self.kernel = kernel }

    func phiDestinations() async throws -> MeshPhiDestinations { try kernel.phiDestinations() }
    func adoptPhiGroup() async throws -> MeshPhiGroup { try kernel.adoptPhiGroup() }
    func includePhiDevice(deviceId: String) async throws -> MeshPhiGroup {
        try kernel.includePhiDevice(deviceId: deviceId)
    }
    func excludePhiDevice(deviceId: String) async throws -> MeshPhiGroup {
        try kernel.excludePhiDevice(deviceId: deviceId)
    }
    func phiProposal(for request: MeshPhiDestinationRequest) async throws -> MeshPhiProposal {
        switch request {
        case .source(let source): return try kernel.proposePhiDestination(source: source)
        case .provider(let name): return try kernel.proposeProviderPhiDestination(name: name)
        case .legacyServer(let name): return try kernel.proposeLegacyPhiDestination(name: name)
        case .connection(let id, let usage): return try kernel.proposeConnectionPhiDestination(id: id, usage: usage)
        }
    }
    func approvePhiDestination(_ proposal: MeshPhiProposal) async throws {
        approvals.append(proposal)
        try kernel.approvePhiDestination(proposal)
    }
    func revokePhiDestination(subject: String) async throws { try kernel.revokePhiDestination(subject: subject) }
}

@MainActor
final class MeshPhiCardTests: XCTestCase {
    private static let phone = "sha256:" + String(repeating: "d", count: 64)
    private static let old = "sha256:" + String(repeating: "e", count: 64)
    private static let source = #"{"base_url":"https://API.Example/v1/","name":"Clinic AI","source":"provider"}"#

    private func make() -> (InMemoryMeshKernel, KernelPhiService) {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        kernel.setMembers([
            kernel.localMember,
            MeshMember(
                memberId: Self.phone, label: "Phone", kind: .pocket, isThisDevice: false, lastSeen: nil, path: .none),
            MeshMember(
                memberId: Self.old, label: "Old phone", kind: .pocket, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        kernel.phiBook.markNotUpgraded(Self.old)
        return (kernel, KernelPhiService(kernel))
    }

    func testTheWarningCardShowsTheNameTheEndpointAndTheThreePlainFacts() async {
        let (_, service) = make()
        let model = MeshPhiDestinationModel(service: service)
        await model.load(.source(Self.source))
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.facts?.name, "Clinic AI")
        XCTAssertEqual(model.facts?.endpoint, "https://api.example/v1")
        XCTAssertEqual(
            model.facts?.lines,
            ["You do not run this.", "PHI will leave your devices.", "Astral cannot see what it does with it."])
    }

    func testApproveCallsTheKernelOnceForOneDestinationAndRaisesPresence() async {
        let (kernel, service) = make()
        final class Presence: @unchecked Sendable {
            private let lock = NSLock()
            private var asked = 0
            var count: Int { lock.withLock { asked } }
            func ask() { lock.withLock { asked += 1 } }
        }
        let presence = Presence()
        kernel.consentGate = { presence.ask() }
        let model = MeshPhiDestinationModel(service: service)
        await model.load(.source(Self.source))
        await model.approve()
        await model.approve()
        XCTAssertEqual(model.phase, .approved)
        XCTAssertEqual(service.approvals.count, 1)
        XCTAssertEqual(kernel.calls.filter { $0.name == "approvePhiDestination" }.count, 1)
        XCTAssertEqual(presence.count, 1)
        XCTAssertEqual(try kernel.phiDestinations().destinations.map(\.subject), ["https://api.example/v1"])
    }

    func testAnApprovalThatNeedsNoApprovalOffersNoButton() async {
        let (_, service) = make()
        let model = MeshPhiDestinationModel(service: service)
        await model.load(.source(#"{"base_url":"http://127.0.0.1:8080","name":"Local","source":"provider"}"#))
        XCTAssertEqual(model.phase, .notNeeded)
        XCTAssertFalse(model.canApprove)
        XCTAssertEqual(model.facts?.lines, [])
    }

    func testAContactOpensTheCardForOneNamedDestinationAndCannotBeApproved() async {
        let (_, service) = make()
        let model = MeshPhiDestinationModel(service: service)
        await model.load(.source(#"{"mesh_id":"m1","name":"Ana","source":"contact"}"#))
        XCTAssertEqual(model.facts?.kindLine, "Contact")
        await model.approve()
        XCTAssertEqual(model.problemCode, "phi_destination.contact_unavailable")
        XCTAssertEqual(model.phase, .reviewing)
    }

    func testALoadFailureShowsTheKernelRefusal() async {
        let (_, service) = make()
        let model = MeshPhiDestinationModel(service: service)
        await model.load(.provider(name: "missing"))
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.problemCode, "provider.not_found")
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(model.offersAdoption)
    }

    func testTheAdoptionCardListsEveryDeviceAndItsApprovals() async throws {
        let (kernel, service) = make()
        let model = MeshPhiGroupModel(service: service)
        await model.load()
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertTrue(model.canAdopt)
        XCTAssertFalse(model.adopted)
        await model.adopt()
        XCTAssertTrue(model.adopted)
        XCTAssertFalse(model.canAdopt)
        let local = kernel.localMember.memberId
        let mine = try XCTUnwrap(model.rows.first { $0.id == local })
        XCTAssertEqual(mine.approvalsLine, "2 approvals")
        let phone = try XCTUnwrap(model.rows.first { $0.id == Self.phone })
        XCTAssertEqual(phone.stateLine, "In the PHI group")
        XCTAssertEqual(phone.approvalsLine, "No approvals")
        let old = try XCTUnwrap(model.rows.first { $0.id == Self.old })
        XCTAssertEqual(old.stateLine, "Joins after its next update.")
        XCTAssertFalse(old.canExclude)
        XCTAssertFalse(old.canInclude)
        XCTAssertEqual(kernel.calls.filter { $0.name == "adoptPhiGroup" }.count, 1)
    }

    func testExcludingSaysDataAlreadyThereStaysAndReincludingRestores() async throws {
        let (_, service) = make()
        let model = MeshPhiGroupModel(service: service)
        await model.load()
        await model.adopt()
        await model.exclude(Self.phone)
        let excluded = try XCTUnwrap(model.rows.first { $0.id == Self.phone })
        XCTAssertTrue(excluded.stateLine.contains("Data already on that device stays there."))
        XCTAssertTrue(excluded.canInclude)
        XCTAssertFalse(excluded.canExclude)
        await model.include(Self.phone)
        XCTAssertEqual(model.rows.first { $0.id == Self.phone }?.canExclude, true)
        await model.exclude("nobody")
        XCTAssertEqual(model.phase, .ready)
    }

    func testLegacyAndUnsupportedRowsAreShownAndCannotBeApprovedOrTakenBack() {
        for status in [MeshPhiDestinationStatus.legacyAuthority, .unsupported] {
            let row = MeshPhiDestinationRowFacts(
                MeshPhiDestination(
                    subject: "https://a.example", form: .endpoint, target: "https://a.example", status: status,
                    code: nil, approvedBy: nil))
            XCTAssertFalse(row.canApprove)
            XCTAssertFalse(row.canRevoke)
            XCTAssertFalse(row.statusLine.isEmpty)
            XCTAssertEqual(row.title, "https://a.example")
        }
        let approved = MeshPhiDestinationRowFacts(
            MeshPhiDestination(
                subject: "https://a.example", form: .endpoint, target: nil, status: .approved, code: nil,
                approvedBy: nil))
        XCTAssertTrue(approved.canRevoke)
    }

    func testTakingBackAnApprovalRevokesOneSubject() async throws {
        let (kernel, service) = make()
        let proposal = try kernel.proposePhiDestination(source: Self.source)
        try kernel.approvePhiDestination(proposal)
        let model = MeshPhiGroupModel(service: service)
        await model.load()
        XCTAssertEqual(model.destinationRows.map(\.canRevoke), [true])
        await model.revoke("https://api.example/v1")
        XCTAssertEqual(model.destinationRows.map(\.canRevoke), [false])
    }

    func testARefusalOffersTheCardForItsDestination() {
        XCTAssertEqual(MeshPhiOffer.offer(forCode: "phi.group_not_ready", defaultProvider: nil), .adoption)
        XCTAssertEqual(MeshPhiOffer.offer(forCode: "phi.device_excluded", defaultProvider: nil), .adoption)
        XCTAssertEqual(
            MeshPhiOffer.offer(forCode: "flow.phi_to_model", defaultProvider: "Clinic"),
            .destination(.provider(name: "Clinic")))
        XCTAssertEqual(MeshPhiOffer.offer(forCode: "flow.phi_to_model", defaultProvider: nil), .destinations)
        XCTAssertEqual(MeshPhiOffer.offer(forCode: "flow.phi_to_service", defaultProvider: "x"), .destinations)
        XCTAssertNil(MeshPhiOffer.offer(forCode: "gate.mesh_stopped", defaultProvider: nil))
        XCTAssertEqual(MeshPhiOffer.adoption.buttonTitle, "Set up PHI")
    }

    func testATurnThatFailsWithGroupNotReadyOffersAdoptionInsteadOfAGenericError() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let text = KernelMapping.failureText(code: "phi.group_not_ready")
        h.kernel.turnScript = [.started, .refused(code: "phi.group_not_ready", message: text)]
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.phiOffer, .adoption)
        XCTAssertEqual(h.runtime.currentTurn?.failure, KernelMapping.failureText(code: "phi.group_not_ready"))
        XCTAssertEqual(h.runtime.currentTurn?.running, false)
        XCTAssertFalse(h.runtime.currentTurn?.failure?.contains("phi.") ?? true)
    }

    func testASendRefusedForPhiOffersTheCardAndOtherRefusalsDoNot() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.failure = KernelMapping.refusal("gate.mesh_stopped")
        _ = await h.runtime.send("hello")
        XCTAssertNil(h.runtime.phiOffer)
        h.kernel.failure = KernelMapping.refusal("phi.group_not_ready")
        _ = await h.runtime.send("hello")
        XCTAssertEqual(h.runtime.phiOffer, .adoption)
        XCTAssertEqual(h.runtime.notice, KernelMapping.failureText(code: "phi.group_not_ready"))
        h.runtime.dismissPhiOffer()
        XCTAssertNil(h.runtime.phiOffer)
    }

    func testAdoptingThroughTheRuntimeClearsTheOffer() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.runtime.offerPhi(forCode: "phi.group_not_ready")
        XCTAssertEqual(h.runtime.phiOffer, .adoption)
        h.kernel.failure = nil
        _ = try await h.runtime.adoptPhiGroup()
        XCTAssertNil(h.runtime.phiOffer)
    }

    func testIdentifiersAreStable() {
        XCTAssertEqual(MeshPhiID.adoptionCard, "mesh.phi.adoption")
        XCTAssertEqual(MeshPhiID.destinationCard, "mesh.phi.destination")
        XCTAssertEqual(MeshPhiID.approve, "mesh.phi.approve")
        XCTAssertEqual(MeshPhiID.adopt, "mesh.phi.adopt")
        XCTAssertEqual(MeshPhiID.offer, "mesh.phi.offer")
        XCTAssertEqual(MeshPhiID.fact("endpoint"), "mesh.phi.fact.endpoint")
        XCTAssertEqual(MeshPhiID.line(1), "mesh.phi.line.1")
        XCTAssertEqual(MeshPhiID.exclude(Self.phone), "mesh.phi.exclude." + String(Self.phone.suffix(8)))
    }

    func testALocalServiceShowsItsEndpointWithoutTheDevicePrefix() {
        let target = "local:" + Self.phone + ":http://localhost:9000"
        XCTAssertEqual(MeshPhiCopy.endpoint(of: target), "http://localhost:9000")
        XCTAssertEqual(MeshPhiCopy.endpoint(of: "https://a.example"), "https://a.example")
    }
}
