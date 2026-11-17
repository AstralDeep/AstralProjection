// Verifies the PHI records, the prompt bridge, the error texts and the signing prompts that map the generated kernel types onto the host's.
// Each presence prompt is checked against a canonical roster entry the way the kernel signs it, so a drifting body shows up here.

import AstralKernel
import XCTest

@testable import AstralDeep

final class KernelPhiMappingTests: XCTestCase {
    private static let mesh = "sha256:" + String(repeating: "a", count: 64)
    private static let device = "sha256:" + String(repeating: "b", count: 64)
    private static let other = "sha256:" + String(repeating: "c", count: 64)
    private static let key = Data([4] + [UInt8](repeating: 7, count: 64))

    private func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func entry(type: String, body: String) -> Data {
        let text: String =
            #"{"author":"\#(Self.device)","body":\#(body),"clock":{"ms":5,"n":0},"#
            + #""follows":["\#(Self.other)"],"mesh":"\#(Self.mesh)","type":"\#(type)","v":2}"#
        return Data("astral.roster/v2\n".utf8) + Data(text.utf8)
    }

    private func grant(kind: String, subject: String) -> String {
        #"{"action":"grant","attestation":{"institution":"\#(b64(Self.key))","issued_s":1,"kind":"phi","#
            + #""not_after_s":2,"sig":"s","subject":"\#(subject)","subject_kind":"\#(kind)"}}"#
    }

    private func prompt(_ kind: ConsentKind, _ input: Data) -> AstralKernel.ConsentPrompt {
        AstralKernel.ConsentPrompt(
            kind: kind, title: "t", target: "shown by the kernel", canonicalAction: Data(), canonicalArguments: Data(),
            signingInput: input, digest: "d", untrustedSources: [], labels: [], requiresBiometry: true, batch: 3)
    }

    private func shown(_ kind: ConsentKind, type: String, body: String) throws -> AstralDeep.ConsentPrompt {
        let input = entry(type: type, body: body)
        return try KernelHostSigner.display(for: prompt(kind, input), message: input)
    }

    func testDeviceGrantShowsTheDeviceAndBindsToTheInput() throws {
        let input = entry(type: "phi_approval", body: grant(kind: "device", subject: Self.other))
        let built = try KernelHostSigner.display(for: prompt(.grantPhi, input), message: input)
        XCTAssertEqual(built.effect, "roster.phi_grant")
        XCTAssertEqual(built.target, Self.other)
        XCTAssertTrue(built.requiresBiometry)
        XCTAssertTrue(built.isBound(to: input))
        XCTAssertFalse(built.isBound(to: input + Data([0])))
    }

    func testDestinationApprovalShowsTheCanonicalEndpoint() throws {
        let built = try shown(
            .approvePhiDestination, type: "phi_approval", body: grant(kind: "endpoint", subject: "https://api.example"))
        XCTAssertEqual(built.effect, "roster.phi_approve_destination")
        XCTAssertEqual(built.target, "https://api.example")
    }

    func testRevokeAndApproverRegistrationShowTheirSubjects() throws {
        let revoke = try shown(
            .revokePhi, type: "phi_approval", body: #"{"action":"revoke","subject":"https://api.example"}"#)
        XCTAssertEqual(revoke.effect, "roster.phi_revoke")
        XCTAssertEqual(revoke.target, "https://api.example")
        let body =
            #"{"action":"add","institution":{"key":"\#(b64(Self.key))","name":"astral-device:\#(Self.device)"}}"#
        let register = try shown(.registerPhiApprover, type: "phi_authority", body: body)
        XCTAssertEqual(register.effect, "roster.phi_register_approver")
        XCTAssertEqual(register.target, Self.device)
    }

    func testAPhiPromptRefusesWhatItsKindDoesNotBack() {
        let device = entry(type: "phi_approval", body: grant(kind: "device", subject: Self.other))
        let endpoint = entry(type: "phi_approval", body: grant(kind: "endpoint", subject: "https://api.example"))
        for (kind, input) in [
            (ConsentKind.approvePhiDestination, device), (.grantPhi, endpoint), (.revokePhi, device),
            (.registerPhiApprover, device), (.grantPhi, Data("astral.roster/v2\n{}".utf8)),
        ] {
            XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(kind, input), message: input))
        }
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(.grantPhi, device), message: endpoint))
        let institution = entry(
            type: "phi_authority",
            body: #"{"action":"add","institution":{"key":"\#(b64(Self.key))","name":"Clinic"}}"#)
        XCTAssertThrowsError(
            try KernelHostSigner.display(for: prompt(.registerPhiApprover, institution), message: institution))
        let extra = entry(type: "phi_approval", body: #"{"action":"revoke","subject":"x","more":1}"#)
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(.revokePhi, extra), message: extra))
        let odd = entry(type: "phi_approval", body: grant(kind: "contact", subject: "x"))
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(.grantPhi, odd), message: odd))
    }

    func testGroupAndDestinationRecordsMapEveryField() {
        let member = PhiMember(
            deviceId: Self.device, label: "Mac", kind: "desktop", state: "included", approvedBy: Self.other,
            upgraded: true, isLocal: true)
        let late = PhiMember(
            deviceId: Self.other, label: "Old phone", kind: "pocket", state: "not_upgraded", approvedBy: nil,
            upgraded: false, isLocal: false)
        let group = PhiGroupInfo(
            members: [member, late], localCode: "phi.group_not_ready", rotateFirst: true, pending: [Self.other],
            keeper: true)
        let mapped = KernelMapping.phiGroup(group)
        XCTAssertEqual(mapped.members.map(\.state), [.included, .notUpgraded])
        XCTAssertEqual(mapped.members[0].kind, .desktop)
        XCTAssertTrue(mapped.members[0].isThisDevice)
        XCTAssertEqual(mapped.members[0].approvedBy, Self.other)
        XCTAssertFalse(mapped.members[1].upgraded)
        XCTAssertEqual(mapped.localCode, "phi.group_not_ready")
        XCTAssertTrue(mapped.rotateFirst)
        XCTAssertEqual(mapped.pending, [Self.other])
        XCTAssertTrue(mapped.keeper)
        XCTAssertTrue(mapped.isAdopted)
        let view = KernelMapping.phiDestinations(
            PhiDestinations(
                group: group,
                destinations: [
                    PhiDestination(
                        subject: "https://api.example", form: "endpoint", target: "https://api.example",
                        status: "legacy_authority", code: nil, approvedBy: nil),
                    PhiDestination(
                        subject: "x", form: "strange", target: nil, status: "strange", code: "c", approvedBy: nil),
                ]))
        XCTAssertEqual(view.destinations.map(\.status), [.legacyAuthority, .invalid])
        XCTAssertEqual(view.destinations.map(\.form), [.endpoint, .invalid])
        XCTAssertEqual(view.destinations[1].code, "c")
        XCTAssertFalse(view.destinations[0].status.canApprove)
    }

    func testAnUnknownMemberStateIsNeverShownAsIncluded() {
        let odd = PhiMember(
            deviceId: Self.device, label: "Mac", kind: "desktop", state: "future", approvedBy: nil, upgraded: true,
            isLocal: true)
        let group = KernelMapping.phiGroup(
            PhiGroupInfo(members: [odd], localCode: nil, rotateFirst: false, pending: [], keeper: false))
        XCTAssertEqual(group.members[0].state, .notApproved)
        XCTAssertFalse(group.isAdopted)
    }

    func testProposalMapsBothWays() {
        let native = PhiDestinationProposal(
            kind: "service", target: "https://api.example", subject: "https://api.example", name: "Notes",
            needsApproval: true, facts: ["not_owner_run", "leaves_devices", "unseen_handling", "later"], source: "{}")
        let mapped = KernelMapping.phiProposal(native)
        XCTAssertEqual(mapped.kind, .service)
        XCTAssertEqual(mapped.facts, [.notOwnerRun, .leavesDevices, .unseenHandling])
        XCTAssertEqual(mapped.name, "Notes")
        XCTAssertEqual(mapped.source, "{}")
        let back = KernelMapping.phiProposal(mapped)
        XCTAssertEqual(back.facts, ["not_owner_run", "leaves_devices", "unseen_handling"])
        XCTAssertEqual(back.kind, "service")
        XCTAssertEqual(back.subject, "https://api.example")
        XCTAssertTrue(back.needsApproval)
    }

    func testStatusMapsEveryCount() {
        let status = KernelMapping.phiStatus(PhiStatus(modelPresent: true, screened: 4, overBudget: 2, failed: 1))
        XCTAssertEqual(status, MeshPhiStatus(modelPresent: true, screened: 4, overBudget: 2, failed: 1))
    }

    func testTheDefaultPromptAnswersTreatAsPhiAndNeverPrintsTheExcerpt() throws {
        let question = PhiQuestion(items: [PhiQuestionItem(source: "message", kind: "name", excerpt: "Jane Roe")])
        let bridge = KernelPhiPrompt(MeshTreatAsPhiPrompt())
        XCTAssertEqual(try bridge.ask(question: question), .treatAsPhi)
        let mapped = KernelMapping.phiQuestion(question)
        XCTAssertEqual(mapped.items.first?.excerpt, "Jane Roe")
        XCTAssertFalse(String(describing: mapped.items).contains("Jane"))
        XCTAssertFalse(String(reflecting: mapped.items[0]).contains("Jane"))
        XCTAssertEqual(KernelMapping.phiAnswer(.send), .send)
    }

    func testPhiCodesHavePlainTextAndKeepTheirCode() {
        for code in [
            "phi.group_not_ready", "phi.device_excluded", "flow.phi_to_model", "flow.phi_to_service",
            "phi_destination.on_device", "phi_destination.malformed", "phi_group.node_device",
        ] {
            let mapped = KernelMapping.error(KernelError.InvalidInput(code: code, message: "m")) as? MeshKernelError
            XCTAssertEqual(mapped?.code, code)
            XCTAssertFalse(mapped?.message.contains(code) ?? true, code)
        }
        let state = KernelMapping.error(KernelError.State(code: "phi.group_not_ready", message: "m"))
        XCTAssertEqual((state as? MeshKernelError)?.code, "phi.group_not_ready")
    }
}
