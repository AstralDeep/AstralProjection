// Verifies the mapping between the generated contact and share records and the host's types, the two new consent prompts and the new change events.
// The prompts are checked against the exact canonical record and signing input the kernel signs.

import AstralKernel
import CryptoKit
import XCTest

@testable import AstralDeep

final class KernelContactMappingTests: XCTestCase {
    private let device = contactMeshId("c")
    private let mesh = contactMeshId("1")
    private let head = contactMeshId("2")
    private let chat = contactMeshId("3")
    private let grant = String(repeating: "ab", count: 16)

    private func hash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func contactRecord(name: String = "Ada", state: String = "verified") -> Data {
        let text: String =
            #"{"count":3,"heads":["\#(head)"],"mesh":"\#(mesh)","ms":9,"name":"\#(name)","state":"\#(state)","v":1}"#
        return Data(text.utf8)
    }

    private func shareRecord(phi: Bool = false, kind: String = "view") -> Data {
        let text: String =
            #"{"contact":"\#(mesh)","id":"\#(grant)","item":{"chat":"\#(chat)","kind":"chat"},"kind":"\#(kind)","#
            + #""ms":9,"phi":\#(phi),"supersedes":null,"v":1}"#
        return Data(text.utf8)
    }

    private func signingInput(_ record: Data, kind: String, digest: String? = nil) -> Data {
        let consent: String =
            #"{"clock":{"ms":5,"n":0},"device":"\#(device)","digest":"\#(digest ?? hash(record))","#
            + #""kind":"\#(kind)","v":1}"#
        return Data("astral.consent/v1\n".utf8) + Data(consent.utf8)
    }

    private func prompt(_ record: Data, _ input: Data, kind: ConsentKind, target: String = "Ada")
        -> AstralKernel.ConsentPrompt
    {
        AstralKernel.ConsentPrompt(
            kind: kind, title: "ignored", target: target, canonicalAction: record, canonicalArguments: Data(),
            signingInput: input, digest: hash(record), untrustedSources: [], labels: [], requiresBiometry: true,
            batch: 1)
    }

    func testContactPromptShowsTheSignedRecordAndBindsToTheSigningInput() throws {
        let body = contactRecord(name: "Ada <b>Lovelace</b>")
        let input = signingInput(body, kind: "contact")
        let shown = try KernelHostSigner.display(for: prompt(body, input, kind: .contactVerify), message: input)
        XCTAssertEqual(shown.actionTitle, "Verify contact")
        XCTAssertEqual(shown.effect, "contact.verify")
        XCTAssertEqual(shown.target, "Ada <b>Lovelace</b>, mesh 1111 1111 1111 1111")
        XCTAssertTrue(shown.requiresBiometry)
        XCTAssertTrue(shown.isBound(to: input))
        XCTAssertFalse(shown.isBound(to: input + Data([0])))
        XCTAssertEqual(shown.digest, hash(body))
    }

    func testSharePromptTakesPhiWordingAndFingerprintFromTheRecord() throws {
        for phi in [false, true] {
            let body = shareRecord(phi: phi)
            let input = signingInput(body, kind: "share")
            let shown = try KernelHostSigner.display(
                for: prompt(body, input, kind: .shareGrant, target: "Notes with Ada"), message: input)
            XCTAssertEqual(shown.actionTitle, phi ? "Share chat with PHI" : "Share chat")
            XCTAssertEqual(shown.effect, "share.grant")
            XCTAssertTrue(shown.target.hasSuffix("with mesh 1111 1111 1111 1111"))
            XCTAssertTrue(shown.arguments.contains("Chat: Notes with Ada"))
            XCTAssertTrue(shown.arguments.contains(phi ? "PHI is included" : "PHI is not included"))
            XCTAssertTrue(shown.isBound(to: input))
        }
    }

    func testNewKindsRefuseAnythingTheRecordDoesNotBack() {
        let contact = contactRecord()
        let share = shareRecord()
        let refusals: [(Data, Data, ConsentKind)] = [
            (contact, signingInput(contact, kind: "share"), .contactVerify),
            (contact, signingInput(contact, kind: "contact", digest: head), .contactVerify),
            (contactRecord(state: "unverified"), signingInput(contactRecord(state: "unverified"), kind: "contact"),
                .contactVerify),
            (share, signingInput(share, kind: "contact"), .shareGrant),
            (shareRecord(kind: "edit"), signingInput(shareRecord(kind: "edit"), kind: "share"), .shareGrant),
            (Data(#"{"v":1}"#.utf8), signingInput(Data(#"{"v":1}"#.utf8), kind: "share"), .shareGrant),
            (share, signingInput(contact, kind: "share"), .shareGrant),
        ]
        for (index, entry) in refusals.enumerated() {
            let shown = prompt(entry.0, entry.1, kind: entry.2)
            XCTAssertThrowsError(try KernelHostSigner.display(for: shown, message: entry.1), "case \(index)")
        }
        let input = signingInput(contact, kind: "contact")
        XCTAssertThrowsError(
            try KernelHostSigner.display(
                for: prompt(contact, input, kind: .contactVerify), message: Data("other".utf8)))
    }

    func testContactRecordsRoundTrip() {
        let notice = ContactNotice(notice: "device_added", device: "d1")
        let info = ContactInfo(
            mesh: mesh, name: "Ada", state: "unverified", fingerprint: "1111 1111 1111 1111", devices: 2,
            notices: [notice, ContactNotice(notice: "device_removed", device: nil)], reason: "contact.roster_rejected")
        let mapped = KernelMapping.contact(info)
        XCTAssertEqual(mapped.mesh, mesh)
        XCTAssertEqual(mapped.state, .unverified)
        XCTAssertFalse(mapped.isVerified)
        XCTAssertEqual(mapped.devices, 2)
        XCTAssertEqual(mapped.notices.map(\.kind), [.deviceAdded, .deviceRemoved])
        XCTAssertEqual(mapped.notices.first?.device, "d1")
        XCTAssertEqual(mapped.reason, "contact.roster_rejected")
        XCTAssertEqual(
            KernelMapping.contact(
                ContactInfo(
                    mesh: mesh, name: "Ada", state: "verified", fingerprint: "", devices: 1, notices: [], reason: nil)
            ).state, .verified)
        let invitation = KernelMapping.contactInvitation(ContactInvitation(text: "t", link: "l", expiresS: 600))
        XCTAssertEqual(invitation, MeshContactInvitation(text: "t", link: "l", expiresInSeconds: 600))
        let exchange = KernelMapping.contactExchange(
            ContactExchange(id: "e", mesh: mesh, name: "Ada", code: "2313 0637 9371", codeQr: "qr", devices: 3))
        XCTAssertEqual(exchange.code, "2313 0637 9371")
        XCTAssertEqual(exchange.codeQR, "qr")
        XCTAssertEqual(exchange.devices, 3)
    }

    func testShareRecordsRoundTrip() {
        let proposal = MeshShareProposal(
            id: grant, chat: chat, title: "Notes", contact: mesh, contactName: "Ada", verified: true, labels: ["phi"],
            phiNeeded: true, phiDestination: false, supersedes: "old", refusal: "share.phi_not_destination")
        XCTAssertEqual(KernelMapping.shareProposal(KernelMapping.shareProposal(proposal)), proposal)
        let info = KernelMapping.share(
            ShareInfo(
                id: grant, chat: chat, title: "Notes", contact: mesh, contactName: "Ada", phi: true,
                phiWithheld: false, state: "in_effect"))
        XCTAssertEqual(info.state, .inEffect)
        XCTAssertEqual(info.revoked().state, .revoked)
        XCTAssertEqual(
            KernelMapping.share(
                ShareInfo(
                    id: grant, chat: chat, title: "", contact: mesh, contactName: "", phi: false, phiWithheld: true,
                    state: "waiting")
            ).state, .waiting)
        let item = KernelMapping.sharedItem(
            SharedItemInfo(
                grant: grant, contact: mesh, contactName: "Ada", chat: chat, title: "Notes", phi: false,
                withheldPhi: 2, withheldFields: 1, withheldKeys: 0, state: "needs_verification", events: 4,
                updatedMs: 5_000))
        XCTAssertEqual(item.state, .needsVerification)
        XCTAssertTrue(item.withheldAny)
        XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 5))
        let report = KernelMapping.refreshReport(RefreshReport(received: 3, refused: 1, stopped: [grant]))
        XCTAssertEqual(report, MeshRefreshReport(received: 3, refused: 1, stopped: [grant]))
    }

    func testChangesAndErrorTexts() {
        XCTAssertEqual(KernelMapping.changes(.contactsChanged), [.contactsChanged])
        XCTAssertEqual(KernelMapping.changes(.sharesChanged), [.sharesChanged])
        XCTAssertFalse(KernelMapping.isEnrollmentComplete(.sharesChanged))
        XCTAssertEqual(
            KernelMapping.failureText(code: "contact.invite_expired"), "That invitation ran out of time. Ask for a new one.")
        XCTAssertEqual(
            KernelMapping.failureText(code: "share.contact_unverified"), "Verify this contact before sharing.")
        XCTAssertEqual(
            KernelMapping.failureText(code: "phi_destination.contact_unavailable"),
            "Verify this contact before they can receive PHI.")
        XCTAssertEqual(KernelMapping.failureText(code: "share.surprise"), "The share could not be changed.")
        XCTAssertEqual(KernelMapping.failureText(code: "contact.surprise"), "The contact could not be changed.")
    }
}
