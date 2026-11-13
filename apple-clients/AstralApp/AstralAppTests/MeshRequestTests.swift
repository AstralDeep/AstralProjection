// Verifies requests in MeshRuntime over an in-memory kernel: the chat's request list, sending to another member, answering by claiming then running a turn, and refusing with a reason.
// It also checks the mapping of the generated request records and the plain-language request texts.

@testable import AstralDeep
import AstralKernel
import XCTest

@MainActor
final class MeshRequestTests: XCTestCase {
    private let me = "sha256:" + String(repeating: "b", count: 64)
    private let phone = "sha256:" + String(repeating: "c", count: 64)

    private func ready() async -> (MeshRuntimeHarness, chat: String) {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        h.kernel.setMembers([
            MeshMember(
                memberId: me, label: "Mac", kind: .desktop, isThisDevice: true, attested: true, lastSeen: nil,
                path: .none),
            MeshMember(
                memberId: phone, label: "Phone", kind: .pocket, isThisDevice: false, attested: true, lastSeen: nil,
                path: .direct),
        ])
        let chat = h.kernel.seedChat(
            title: "Shared", messages: [MeshRuntimeHarness.message("a", parent: nil, text: "hello", at: 10)])
        await h.runtime.refreshAll()
        await h.runtime.openChat(chat)
        return (h, chat)
    }

    private func request(
        _ id: String, chat: String, from: String?, to: String, state: MeshRequestState, text: String = "do it",
        code: String? = nil
    ) -> MeshRequest {
        MeshRequest(
            requestId: id, chatId: chat, fromMember: from, toMember: to, state: state, text: text, refusalCode: code,
            tool: nil, createdAt: Date(timeIntervalSince1970: 100))
    }

    func testTheChatListsItsRequestsAndTheDeviceListsThoseAddressedToIt() async {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        h.kernel.setRequests([
            request("r1", chat: chat, from: phone, to: me, state: .pending),
            request("r2", chat: chat, from: me, to: phone, state: .refused, code: "request.busy"),
            request("r3", chat: "other", from: phone, to: me, state: .answered),
        ])
        let arrived = await eventually { h.runtime.chatRequests.count == 2 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(h.runtime.chatRequests.map(\.requestId), ["r1", "r2"])
        XCTAssertEqual(h.runtime.requestsForMe.map(\.requestId), ["r1"])
        XCTAssertEqual(h.runtime.memberLabel(phone), "Phone")
        XCTAssertEqual(h.runtime.memberLabel(nil), "A device")
        XCTAssertEqual(h.runtime.memberLabel("sha256:gone"), "Another device")
        h.runtime.closeChat()
        XCTAssertTrue(h.runtime.chatRequests.isEmpty)
    }

    func testSendingARequestAddsItToTheChatAsWaiting() async throws {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        let other = try XCTUnwrap(h.runtime.members.first { !$0.isThisDevice })
        let sent = await h.runtime.sendRequest("  Print the plan  ", to: other)
        XCTAssertTrue(sent)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "sendRequest", detail: "\(chat)|\(phone)|Print the plan")))
        XCTAssertEqual(h.runtime.chatRequests.map(\.state), [.pending])
        XCTAssertEqual(h.runtime.chatRequests.first?.toMember, phone)
        XCTAssertEqual(h.runtime.chatRequests.first?.fromMember, me)
        XCTAssertTrue(h.runtime.requestsForMe.isEmpty)
    }

    func testSendingWithoutAChatCreatesOneTitledFromTheRequest() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.setMembers([
            MeshMember(memberId: me, label: "Mac", kind: .desktop, isThisDevice: true, attested: true, lastSeen: nil, path: .none),
            MeshMember(memberId: phone, label: "Phone", kind: .pocket, isThisDevice: false, attested: true, lastSeen: nil, path: .direct),
        ])
        await h.runtime.refreshAll()
        let other = try XCTUnwrap(h.runtime.members.first { !$0.isThisDevice })
        let sent = await h.runtime.sendRequest("Find the invoice", to: other)
        XCTAssertTrue(sent)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "createChat", detail: "Find the invoice")))
        XCTAssertEqual(h.runtime.chats.map(\.title), ["Find the invoice"])
    }

    func testSendingIsRefusedForEmptyTextThisDeviceAndAStoppedMesh() async throws {
        let (h, _) = await ready()
        defer { h.cleanUp() }
        let other = try XCTUnwrap(h.runtime.members.first { !$0.isThisDevice })
        let this = try XCTUnwrap(h.runtime.members.first(where: \.isThisDevice))
        let empty = await h.runtime.sendRequest("   ", to: other)
        XCTAssertFalse(empty)
        let toSelf = await h.runtime.sendRequest("hi", to: this)
        XCTAssertFalse(toSelf)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "sendRequest" })
        await h.runtime.raiseStop()
        let stopped = await h.runtime.sendRequest("hi", to: other)
        XCTAssertFalse(stopped)
        XCTAssertEqual(h.runtime.notice, MeshKernelError.stopped.message)
    }

    func testAKernelRefusalReachesTheNotice() async {
        let (h, _) = await ready()
        defer { h.cleanUp() }
        let gone = MeshMember(
            memberId: "sha256:" + String(repeating: "9", count: 64), label: "Gone", kind: .node, isThisDevice: false,
            attested: false, lastSeen: nil, path: .none)
        let sent = await h.runtime.sendRequest("hello", to: gone)
        XCTAssertFalse(sent)
        XCTAssertEqual(h.runtime.notice, "That device is not in your mesh.")
    }

    func testAnsweringClaimsTheRequestThenRunsATurn() async throws {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        h.kernel.setRequests([request("r1", chat: chat, from: phone, to: me, state: .pending)])
        let arrived = await eventually { h.runtime.requestsForMe.count == 1 }
        XCTAssertTrue(arrived)
        let open = try XCTUnwrap(h.runtime.requestsForMe.first)
        await h.runtime.answer(open)
        await h.runtime.settle()
        let names = h.kernel.calls.map(\.name)
        let answer = try XCTUnwrap(names.lastIndex(of: "answerRequest"))
        let run = try XCTUnwrap(names.lastIndex(of: "runTurn"))
        XCTAssertLessThan(answer, run)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "runTurn", detail: chat)))
        XCTAssertEqual(h.runtime.chatRequests.first?.state, .claimed)
    }

    func testAnsweringARefusedRequestReportsAndRunsNoTurn() async throws {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        let closed = request("r1", chat: chat, from: phone, to: me, state: .refused, code: "request.busy")
        h.kernel.setRequests([closed])
        await h.runtime.answer(closed)
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.notice, "That request can no longer change.")
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "runTurn" })
    }

    func testRefusingSendsTheChosenReasonCode() async throws {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        let waiting = request("r1", chat: chat, from: phone, to: me, state: .pending)
        let claimed = request("r2", chat: chat, from: phone, to: me, state: .claimed)
        h.kernel.setRequests([waiting, claimed])
        let arrived = await eventually { h.runtime.chatRequests.count == 2 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(h.runtime.requestsForMe.map(\.requestId), ["r1"])
        await h.runtime.refuse(waiting, because: .busy)
        await h.runtime.refuse(claimed, because: .declined)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "refuseRequest", detail: "r1|request.busy")))
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "refuseRequest", detail: "r2|request.declined")))
        XCTAssertEqual(h.runtime.chatRequests.map(\.state), [.refused, .refused])
        XCTAssertEqual(h.runtime.chatRequests.compactMap(\.refusalCode), ["request.busy", "request.declined"])
        XCTAssertTrue(h.runtime.requestsForMe.isEmpty)
    }

    func testRefusingARequestForAnotherDeviceIsDenied() async {
        let (h, chat) = await ready()
        defer { h.cleanUp() }
        let foreign = request("r1", chat: chat, from: me, to: phone, state: .pending)
        h.kernel.setRequests([foreign])
        await h.runtime.refuse(foreign, because: .notNow)
        XCTAssertEqual(h.runtime.notice, "That request is addressed to another device.")
        XCTAssertEqual(h.runtime.chatRequests.first?.state, .pending)
    }

    func testRefusalCodesHaveTextAndEveryRefusalCodeIsADottedKernelCode() {
        for reason in MeshRequestRefusal.allCases {
            XCTAssertTrue(reason.rawValue.range(of: #"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$"#, options: .regularExpression) != nil)
            XCTAssertEqual(MeshPresentation.requestRefusal(reason.rawValue), "Refused: " + reason.reason)
            XCTAssertFalse(reason.title.isEmpty)
        }
        XCTAssertEqual(MeshPresentation.requestRefusal("gate.permission_denied"), "Refused (gate.permission_denied)")
        XCTAssertEqual(MeshPresentation.requestRefusal(nil), "Refused")
        XCTAssertEqual(MeshPresentation.requestState(.pending), "Waiting for the device")
        XCTAssertEqual(MeshPresentation.requestState(.claimed), "Being answered")
        XCTAssertEqual(MeshPresentation.requestState(.answered), "Answered")
        XCTAssertEqual(MeshPresentation.requestState(.cancelled), "Cancelled")
    }

    func testGeneratedRequestRecordsMapToTheHostType() {
        let labels = PeerLabels(confidentiality: .private, integrity: .owner)
        let call = PeerCall(callId: "c", tool: "files.read", argumentsJson: "{}", actionJson: "{}", ticketJson: "{}")
        func view(_ state: RequestState, code: String? = nil, call: PeerCall? = nil) -> RequestView {
            RequestView(
                id: "r", chatId: "chat", fromDevice: "a", toDevice: "b", state: state, claim: nil, turn: nil,
                code: code, text: "text", continues: nil, call: call, labels: labels,
                clock: ClockStamp(ms: 5_000, n: 0))
        }
        let pairs: [(RequestState, MeshRequestState)] = [
            (.pending, .pending), (.claimed, .claimed), (.answered, .answered), (.refused, .refused),
            (.cancelled, .cancelled),
        ]
        for (generated, mapped) in pairs { XCTAssertEqual(KernelMapping.request(view(generated)).state, mapped) }
        let refused = KernelMapping.request(view(.refused, code: "request.busy", call: call))
        XCTAssertEqual(refused.refusalCode, "request.busy")
        XCTAssertEqual(refused.tool, "files.read")
        XCTAssertEqual(refused.createdAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(refused.fromMember, "a")
        XCTAssertEqual(refused.toMember, "b")
        XCTAssertNil(KernelMapping.request(view(.pending)).tool)
    }

    func testRequestErrorCodesReadInPlainWords() {
        let cases: [(String, String)] = [
            ("request.empty", "Write the request first."),
            ("request.too_large", "That request is too long."),
            ("request.self_addressed", "Choose another device. This one cannot ask itself."),
            ("request.already_claimed", "That request is already claimed."),
            ("request.unknown", "That request is no longer in this chat."),
            ("request.answered", "That request can no longer change."),
        ]
        for (code, text) in cases { XCTAssertEqual(KernelMapping.failureText(code: code), text) }
    }
}
