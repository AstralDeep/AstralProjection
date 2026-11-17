// Verifies the contact model: invitation text and link classification, the 12 digit code, the invite, accept and compare flows, and the row facts.
// Upstream vectors: AstralKernel tests/fixtures/qualified/deep/vectors/contacts-v1.json at 9dcaa995a5452a0b060a288e0a0d9e8d96654612, trimmed to the invitation and code cases in ContactsInvitationVectors.json.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshContactModelTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Invitation: Decodable {
            struct Result: Decodable {
                struct Ok: Decodable {
                    let name: String
                    let expiresS: Int

                    enum CodingKeys: String, CodingKey {
                        case name
                        case expiresS = "expires_s"
                    }
                }
                let error: String?
                let ok: Ok?
            }
            let name: String
            let text: String
            let result: Result
        }
        struct Code: Decodable {
            let name: String
            let display: String
            let qr: String
        }
        let invitations: [Invitation]
        let codes: [Code]
    }

    private static let modelRefuses: Set<String> = [
        "invite_wrong_prefix", "invite_link_wrong_host", "invite_not_text", "invite_empty_payload",
        "invite_padded_base64", "invite_not_base64", "invite_payload_not_an_object", "invite_payload_not_utf8",
    ]

    private func vectors() throws -> Vectors {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "ContactsInvitationVectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testTheModelClassifiesEveryUpstreamInvitationCaseTheWayTheVectorsRequire() throws {
        let all = try vectors().invitations
        XCTAssertGreaterThan(all.count, 40)
        for item in all {
            let result = MeshContactLink.classify(item.text)
            if Self.modelRefuses.contains(item.name) {
                XCTAssertThrowsError(try result.get(), item.name)
            } else {
                let invite = try? result.get()
                XCTAssertNotNil(invite, item.name)
                if let ok = item.result.ok {
                    XCTAssertEqual(invite?.name, ok.name, item.name)
                    XCTAssertEqual(invite?.expiresAt, Date(timeIntervalSince1970: Double(ok.expiresS)), item.name)
                    XCTAssertEqual(invite?.text, item.text, item.name)
                }
            }
        }
    }

    func testBothInvitationFormsAreAcceptedAndOtherFormsRefusedWithAReason() throws {
        let all = try vectors().invitations
        let text = try XCTUnwrap(all.first { $0.name == "invite_valid_text" }).text
        let link = try XCTUnwrap(all.first { $0.name == "invite_valid_link" }).text
        XCTAssertTrue(text.hasPrefix("astral-contact:v1:"))
        XCTAssertTrue(link.hasPrefix("https://astraldeep.github.io/contact/#"))
        XCTAssertNotNil(try? MeshContactLink.classify("  " + text + "\n").get())
        XCTAssertEqual(MeshContactLink.classify(""), .failure(.empty))
        XCTAssertEqual(MeshContactLink.classify("hello"), .failure(.notAnInvitation))
        XCTAssertEqual(MeshContactLink.classify("https://example.invalid/contact/#AAAA"), .failure(.wrongHost))
        XCTAssertEqual(MeshContactLink.classify("https://astraldeep.github.io/contact/"), .failure(.damaged))
        XCTAssertEqual(MeshContactLink.classify("https://astraldeep.github.io/other/#AAAA"), .failure(.wrongHost))
        XCTAssertEqual(MeshContactLink.classify("astral-contact:v1:"), .failure(.damaged))
    }

    func testOnlyTheContactPathOfTheSiteOpensTheAcceptScreen() throws {
        let link = try XCTUnwrap(try vectors().invitations.first { $0.name == "invite_valid_link" }).text
        XCTAssertEqual(MeshContactLink.text(from: try XCTUnwrap(URL(string: link))), link)
        for bad in [
            "http://astraldeep.github.io/contact/#AAAA", "https://astraldeep.github.io/pair/#AAAA",
            "https://example.invalid/contact/#AAAA", "astral-contact:v1:AAAA",
            "https://astraldeep.github.io/contact/#!!",
        ] {
            XCTAssertNil(MeshContactLink.text(from: try XCTUnwrap(URL(string: bad))), bad)
        }
    }

    func testTheCodeDisplayMatchesTheVectorStrings() throws {
        let codes = try vectors().codes
        XCTAssertFalse(codes.isEmpty)
        for entry in codes {
            let digits = entry.display.replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(MeshContactCode.isTwelveDigits(entry.display), entry.name)
            XCTAssertEqual(MeshContactCode.format(digits), entry.display, entry.name)
            XCTAssertEqual(MeshContactCode.format(entry.display), entry.display, entry.name)
            XCTAssertEqual(MeshPresentation.codeGroups(entry.display).joined(separator: " "), entry.display)
            XCTAssertEqual(MeshPresentation.codeGroups(entry.display).count, 3)
        }
        XCTAssertFalse(MeshContactCode.isTwelveDigits("1234 5678"))
        XCTAssertFalse(MeshContactCode.isTwelveDigits("abcd efgh ijkl"))
    }

    func testBothSidesOfAnExchangeShowOneString() async throws {
        let pair = ContactPair.make()
        let alice = KernelContactService(pair.alice)
        let bob = KernelContactService(pair.bob)
        let invite = MeshContactInviteModel(service: alice, now: { pair.clock.now })
        invite.name = "Alice"
        await invite.create()
        guard case .shown(let invitation, let expiresAt) = invite.phase else { return XCTFail("not shown") }
        XCTAssertEqual(expiresAt, pair.clock.now.addingTimeInterval(900))
        let accept = MeshContactAcceptModel(service: bob, initial: invitation.link)
        accept.name = "Bob"
        await accept.submit()
        guard case .comparing(let bobSide) = accept.phase else { return XCTFail("not comparing") }
        await invite.checkPending()
        guard case .comparing(let aliceSide) = invite.phase else { return XCTFail("not comparing") }
        let bobShows = MeshContactCompareModel(service: bob, exchange: bobSide).displayCode
        let aliceShows = MeshContactCompareModel(service: alice, exchange: aliceSide).displayCode
        XCTAssertEqual(bobShows, aliceShows)
        XCTAssertTrue(MeshContactCode.isTwelveDigits(bobSide.code))
    }

    private func comparing() async throws -> (ContactPair, MeshContactCompareModel, KernelContactService) {
        let pair = ContactPair.make()
        let alice = KernelContactService(pair.alice)
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        let exchange = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        return (pair, MeshContactCompareModel(service: KernelContactService(pair.bob), exchange: exchange), alice)
    }

    func testCodesMatchAsksForPresenceAndDeniedLeavesTheContactUnverified() async throws {
        let (pair, model, _) = try await comparing()
        pair.bob.consentGate = { throw MeshKernelError.consentDenied }
        await model.codesMatch()
        guard case .failed = model.phase else { return XCTFail("expected failure") }
        XCTAssertEqual(try pair.bob.contacts().first?.state, .unverified)
        pair.bob.consentGate = {}
        await model.codesMatch()
        guard case .verified(let contact) = model.phase else { return XCTFail("expected verified") }
        XCTAssertTrue(contact.isVerified)
        XCTAssertEqual(try pair.bob.contacts().first?.state, .verified)
    }

    func testCodesDifferWritesNothing() async throws {
        let (pair, model, _) = try await comparing()
        await model.codesDiffer()
        XCTAssertEqual(model.phase, .differed)
        XCTAssertFalse(pair.bob.calls.contains { $0.name == "verifyContact" })
        XCTAssertEqual(try pair.bob.contacts().first?.state, .unverified)
    }

    func testAScannedCodeIsComparedButNeverVerifiesOnItsOwn() async throws {
        let (pair, model, _) = try await comparing()
        model.scanned(" " + model.exchange.codeQR + "\n")
        XCTAssertEqual(model.scan, .matches)
        model.scanned("other")
        XCTAssertEqual(model.scan, .differs)
        XCTAssertFalse(pair.bob.calls.contains { $0.name == "verifyContact" })
        XCTAssertEqual(model.phase, .comparing)
    }

    func testAcceptRefusesBadInputBeforeAnyKernelCall() async throws {
        let pair = ContactPair.make()
        let model = MeshContactAcceptModel(service: KernelContactService(pair.bob), initial: "hello")
        XCTAssertFalse(model.canSubmit)
        model.name = "Bob"
        await model.submit()
        XCTAssertEqual(model.phase, .failed(MeshContactLinkError.notAnInvitation.message))
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        model.input = invitation.text
        model.classify()
        model.name = "  "
        await model.submit()
        XCTAssertEqual(model.phase, .failed(MeshContactNameError.empty.message))
        XCTAssertFalse(pair.bob.calls.contains { $0.name == "acceptContactInvitation" })
        model.name = String(repeating: "x", count: 65)
        await model.submit()
        XCTAssertEqual(model.phase, .failed(MeshContactNameError.tooLong.message))
    }

    func testAKernelRefusalReachesTheScreenAsPlainText() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 60)
        pair.clock.advance(61)
        let model = MeshContactAcceptModel(service: KernelContactService(pair.bob), initial: invitation.text)
        model.name = "Bob"
        await model.submit()
        XCTAssertEqual(model.phase, .failed("That invitation ran out of time. Ask for a new one."))
    }

    func testInviteNeedsANameAndCancelReachesTheKernel() async throws {
        let pair = ContactPair.make()
        let model = MeshContactInviteModel(service: KernelContactService(pair.alice))
        await model.create()
        XCTAssertEqual(model.phase, .failed(MeshContactNameError.empty.message))
        model.name = "Alice"
        await model.create()
        await model.cancel()
        XCTAssertEqual(model.phase, .form)
        XCTAssertTrue(pair.alice.calls.contains { $0.name == "cancelContactInvitation" })
    }

    func testANameWithMarkupStaysPlainText() {
        let contact = MeshContact(
            mesh: contactMeshId("b"), name: "<b>Ada</b> [x](https://evil.example)", state: .verified,
            fingerprint: "bbbb bbbb bbbb bbbb", devices: 1, notices: [], reason: nil)
        let facts = MeshContactRowFacts(contact)
        XCTAssertEqual(facts.name, "<b>Ada</b> [x](https://evil.example)")
        XCTAssertEqual(facts.stateLine, "Verified")
        XCTAssertNil(facts.warning)
    }

    func testNoticesForANewDeviceARemovedDeviceAndADowngradeRender() {
        let contact = MeshContact(
            mesh: contactMeshId("b"), name: "Ada", state: .unverified, fingerprint: "bbbb bbbb bbbb bbbb", devices: 2,
            notices: [
                MeshContactNotice(notice: "device_added", device: "d"),
                MeshContactNotice(notice: "device_removed", device: "e"),
                MeshContactNotice(notice: "recovery_used", device: nil),
                MeshContactNotice(notice: "new_kind", device: nil),
            ], reason: "contact.roster_rejected")
        let facts = MeshContactRowFacts(contact)
        XCTAssertEqual(
            facts.notices,
            [
                "A new device joined their mesh.", "A device was removed from their mesh.",
                "They restored their mesh from recovery words.", "Their devices changed.",
            ])
        XCTAssertEqual(facts.stateLine, "Not verified")
        XCTAssertTrue(try XCTUnwrap(facts.warning).hasPrefix("Verification was withdrawn. Compare codes again."))
    }

    func testAutomationIdentifiersAreStable() {
        XCTAssertEqual(MeshContactID.list, "mesh.contacts.list")
        XCTAssertEqual(MeshContactID.codesMatch, "mesh.contacts.code.match")
        XCTAssertEqual(MeshContactID.codesDiffer, "mesh.contacts.code.differ")
        XCTAssertEqual(MeshContactID.acceptPaste, "mesh.contacts.accept.paste")
        XCTAssertEqual(MeshContactID.inviteQR, "mesh.contacts.invite.qr")
        XCTAssertEqual(MeshContactID.row("m"), "mesh.contacts.row.m")
    }
}
