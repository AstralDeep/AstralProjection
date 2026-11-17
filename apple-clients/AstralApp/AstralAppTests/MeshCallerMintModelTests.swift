// Covers the caller ticket mint and revoke models: holder line checking, lifetimes, tool rules, refusal text and the revoke confirmation.
// They run over MeshRuntime with the in-memory kernel, so the Kernel's own refusals are exercised through the same path the screens use.

import CryptoKit
import XCTest

@testable import AstralDeep

@MainActor
final class MeshCallerMintModelTests: XCTestCase {
    private let nodeId = "sha256:" + String(repeating: "c", count: 64)

    private static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func holderLine() -> String {
        MeshCallerTicketLimits.holderPrefix
            + Self.encoded(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }

    private func ready(nodeKind: MeshDeviceKind = .node, published: Bool = true) async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        let local = h.kernel.localMember
        h.kernel.setMembers([
            local,
            MeshMember(
                memberId: nodeId, label: "Study node", kind: nodeKind, isThisDevice: false, lastSeen: nil, path: .none),
        ])
        if published {
            h.kernel.setNodeCatalog(nodeId, tools: ["current_datetime", "read_notes"])
            h.kernel.setTools(
                ["current_datetime", "read_notes"].map {
                    MeshToolEntry(name: $0, summary: "", effect: .meshRead, deviceId: nodeId, published: true)
                })
        }
        await h.runtime.refreshRoster()
        await h.runtime.refreshTools()
        return h
    }

    private func filled(_ h: MeshRuntimeHarness) -> MeshCallerTicketModel {
        let model = MeshCallerTicketModel(runtime: h.runtime)
        model.label = "Lab script"
        model.updateHolder(holderLine())
        model.setTool("current_datetime", chosen: true)
        return model
    }

    func testHolderLineIsAcceptedOnlyInThePublicForm() {
        let line = holderLine()
        XCTAssertEqual(MeshCallerHolderInput.judge(" \(line)\n"), .holder(line))
        XCTAssertEqual(MeshCallerHolderInput.judge(""), .empty)
        XCTAssertEqual(MeshCallerHolderInput.judge("astral-caller-holder:v2:" + line.suffix(43)), .invalid)
        XCTAssertEqual(MeshCallerHolderInput.judge(MeshCallerTicketLimits.holderPrefix + "short"), .invalid)
        XCTAssertEqual(MeshCallerHolderInput.judge(MeshCallerTicketLimits.holderPrefix + line.suffix(43) + "="), .invalid)
        XCTAssertEqual(MeshCallerHolderInput.judge("just words"), .invalid)
    }

    func testPastedPrivateKeyIsRefusedClearedAndNeverKept() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = MeshCallerTicketModel(runtime: h.runtime)
        let secret = MeshCallerHolderInput.keyPrefix + Self.encoded(Data(repeating: 7, count: 32))
        model.updateHolder(secret)
        XCTAssertEqual(model.holderLine, "")
        XCTAssertEqual(model.holderNotice, MeshCallerHolderInput.privateKeyMessage)
        XCTAssertFalse(model.holderNotice?.contains(secret.suffix(43)) ?? true)
        XCTAssertFalse(model.canMint)
        model.updateHolder("note\n" + secret)
        XCTAssertEqual(model.holderLine, "")
        XCTAssertEqual(MeshCallerHolderInput.judge(secret.uppercased()), .privateKey)
        model.updateHolder(holderLine())
        XCTAssertNil(model.holderNotice)
    }

    func testLifetimesAreTheFourChoicesWithSevenDaysPreselected() async {
        let h = await ready()
        defer { h.cleanUp() }
        XCTAssertEqual(MeshCallerLifetime.allCases.map(\.title), ["1 hour", "1 day", "7 days", "30 days"])
        XCTAssertEqual(
            MeshCallerLifetime.allCases.map(\.seconds), [3600, 86400, 604_800, MeshCallerTicketLimits.maxLifetimeSeconds])
        XCTAssertEqual(MeshCallerTicketModel(runtime: h.runtime).lifetime, .week)
    }

    func testMintNeedsAToolFromTheNodeCatalog() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = filled(h)
        XCTAssertEqual(model.catalog, ["current_datetime", "read_notes"])
        XCTAssertTrue(model.canMint)
        model.setTool("current_datetime", chosen: false)
        XCTAssertFalse(model.canMint)
        model.setTool("typed_by_hand", chosen: true)
        XCTAssertTrue(model.chosenTools.isEmpty)
        model.a2a = true
        XCTAssertTrue(model.canMint)
    }

    func testMintNeedsALabelAndAUsableHolder() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = filled(h)
        model.label = "   "
        XCTAssertFalse(model.canMint)
        model.label = String(repeating: "a", count: 65)
        XCTAssertFalse(model.canMint)
        model.label = "ok"
        model.updateHolder("astral-caller-holder:v1:nope")
        XCTAssertFalse(model.canMint)
        XCTAssertEqual(model.holderNotice, MeshCallerHolderInput.invalidMessage)
    }

    func testMintSendsTheChosenLifetimeAndShowsTheTicket() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = filled(h)
        model.lifetime = .day
        await model.mint()
        guard case .minted(let ticket) = model.phase else { return XCTFail("not minted: \(model.phase)") }
        XCTAssertEqual(ticket.tools, ["current_datetime"])
        XCTAssertEqual(ticket.expiresAt.timeIntervalSince(ticket.issuedAt), 86400)
        XCTAssertEqual(h.runtime.callerTickets.map(\.id), [ticket.id])
    }

    func testKernelRefusalsBecomePlainText() async {
        let h = await ready(published: false)
        defer { h.cleanUp() }
        let model = MeshCallerTicketModel(runtime: h.runtime)
        model.label = "Lab script"
        model.updateHolder(holderLine())
        model.a2a = true
        await model.mint()
        XCTAssertEqual(model.phase, .failed(KernelMapping.failureText(code: "caller.no_catalog")))
        XCTAssertEqual(model.phase, .failed("That node has not published its tools yet."))
        model.editAgain()
        XCTAssertEqual(model.phase, .editing)
    }

    func testMintingForAnUnknownNodeIsRefusedWithPlainText() async {
        let h = await ready()
        defer { h.cleanUp() }
        let result = await h.runtime.mintCallerTicket(
            nodeId: "sha256:" + String(repeating: "d", count: 64), holderKey: holderLine(), label: "x",
            toolNames: ["current_datetime"], a2a: false, lifetimeSeconds: 3600)
        guard case .failure(let error) = result else { return XCTFail("minted") }
        XCTAssertEqual(error.code, "caller.wrong_node")
        XCTAssertEqual(MeshCallerText.failure(error), "Choose a node that belongs to your mesh.")
    }

    func testRevokeAsksFirstAndThenRevokes() async {
        let h = await ready()
        defer { h.cleanUp() }
        let minting = filled(h)
        await minting.mint()
        let list = MeshCallersModel(runtime: h.runtime)
        let ticket = try! XCTUnwrap(list.tickets.first)
        list.askRevoke(ticket)
        XCTAssertEqual(list.pendingRevoke, ticket)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "revokeCallerTicket" })
        list.cancelRevoke()
        XCTAssertNil(list.pendingRevoke)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "revokeCallerTicket" })
        list.askRevoke(ticket)
        await list.confirmRevoke(ticket)
        XCTAssertNil(list.pendingRevoke)
        XCTAssertNil(list.failure)
        XCTAssertEqual(list.tickets.first?.revoked, true)
        list.askRevoke(try! XCTUnwrap(list.tickets.first))
        XCTAssertNil(list.pendingRevoke)
    }

    func testRevokeFailureIsShownAndDismissible() async {
        let h = await ready()
        defer { h.cleanUp() }
        let list = MeshCallersModel(runtime: h.runtime)
        let bogus = MeshCallerTicket(
            id: "bad", text: "t", label: "x", nodeId: nodeId, tools: [], issuedAt: Date(), expiresAt: Date(),
            revoked: false, expired: false)
        list.askRevoke(bogus)
        await list.confirmRevoke(bogus)
        XCTAssertEqual(list.failure, "Check the label, tool list, holder key and lifetime.")
        list.dismissFailure()
        XCTAssertNil(list.failure)
    }

    func testRevokeStillRunsWhenTheDialogDismissedFirst() async {
        let h = await ready()
        defer { h.cleanUp() }
        let minting = filled(h)
        await minting.mint()
        let list = MeshCallersModel(runtime: h.runtime)
        let ticket = try! XCTUnwrap(list.tickets.first)
        list.askRevoke(ticket)
        list.cancelRevoke()
        await list.confirmRevoke(ticket)
        XCTAssertEqual(list.tickets.first?.revoked, true)
    }

    func testRefusedPrivateKeyBumpsTheFieldResetEachTime() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = MeshCallerTicketModel(runtime: h.runtime)
        let secret = MeshCallerHolderInput.keyPrefix + Self.encoded(Data(repeating: 9, count: 32))
        model.updateHolder(secret)
        model.updateHolder(secret)
        XCTAssertEqual(model.holderResetCount, 2)
        XCTAssertEqual(model.holderLine, "")
    }

    func testBareSeedIsRefusedLikeThePrivateKey() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = MeshCallerTicketModel(runtime: h.runtime)
        let seed = Self.encoded(Data(repeating: 5, count: 32))
        XCTAssertEqual(seed.count, 43)
        model.updateHolder(seed)
        XCTAssertEqual(model.holderLine, "")
        XCTAssertEqual(model.holderNotice, MeshCallerHolderInput.privateKeyMessage)
        XCTAssertEqual(model.holderResetCount, 1)
        model.updateHolder("here " + seed + "\n")
        XCTAssertEqual(model.holderLine, "")
        model.updateHolder(holderLine())
        XCTAssertNotEqual(model.holderLine, "")
    }

    func testChoicesRefreshAndTheFirstNodeIsSelected() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = MeshCallerTicketModel(runtime: h.runtime)
        await model.refreshChoices()
        XCTAssertEqual(model.nodeId, nodeId)
        XCTAssertEqual(model.catalog, ["current_datetime", "read_notes"])
    }

    func testOnlyThePublishedCatalogIsOffered() async {
        let h = await ready()
        defer { h.cleanUp() }
        h.kernel.setTools([
            MeshToolEntry(name: "published_tool", summary: "", effect: .meshRead, deviceId: nodeId, published: true),
            MeshToolEntry(name: "static_peer_tool", summary: "", effect: .meshRead, deviceId: nodeId),
        ])
        await h.runtime.refreshTools()
        XCTAssertEqual(MeshCallerTicketModel(runtime: h.runtime).catalog, ["published_tool"])
    }

    func testMoreThanThirtyTwoToolsIsRefusedWithAMessage() async {
        let h = await ready()
        defer { h.cleanUp() }
        let names = (0..<33).map { "tool_\($0)" }
        h.kernel.setTools(
            names.map { MeshToolEntry(name: $0, summary: "", effect: .meshRead, deviceId: nodeId, published: true) })
        await h.runtime.refreshTools()
        let model = filled(h)
        names.forEach { model.setTool($0, chosen: true) }
        XCTAssertEqual(model.toolProblem, MeshCallerText.tooManyTools)
        XCTAssertFalse(model.canMint)
    }

    func testLabelWithInvisibleCharactersIsRefusedBeforeMint() async {
        let h = await ready()
        defer { h.cleanUp() }
        let model = filled(h)
        model.label = "bad\u{200D}label"
        XCTAssertEqual(model.labelProblem, MeshCallerText.labelRefused)
        XCTAssertFalse(model.canMint)
        model.label = String(repeating: "a", count: 65)
        XCTAssertEqual(model.labelProblem, MeshCallerText.labelTooLong)
        model.label = "fine label"
        XCTAssertNil(model.labelProblem)
        XCTAssertTrue(model.canMint)
    }

    func testEveryCallerRefusalCodeHasPlainTextAndNoRawCodeLeaks() {
        let codes = [
            "caller.malformed", "caller.proof_malformed", "caller.mesh_mismatch", "caller.wrong_node",
            "caller.device_removed", "caller.wrong_minter", "caller.bad_signature", "caller.stopped",
            "caller.expired", "caller.not_yet_valid", "caller.revoked", "caller.proof_mismatch", "caller.proof_stale",
            "caller.proof_bad_signature", "caller.replayed", "caller.tool_not_covered", "caller.tool_changed",
            "caller.tool_unavailable", "caller.no_catalog", "caller.unknown_tool", "caller.future_code",
        ]
        for code in codes {
            let text = MeshCallerText.failure(KernelMapping.refusal(code))
            XCTAssertFalse(text.isEmpty, code)
            XCTAssertFalse(text.contains("caller."), code)
        }
        XCTAssertEqual(
            MeshCallerText.failure(.refused(code: "weird.code", message: "weird.code")), MeshCallerText.generic)
    }
}
