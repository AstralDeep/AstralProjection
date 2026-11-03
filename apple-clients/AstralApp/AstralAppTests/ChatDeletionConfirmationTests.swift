// Verifies that deleting a conversation waits for confirmation through AppModel's pending deletion request and, on
// Mac, the workbench dialog that names the chat and cancels on Return. A synthetic REST transport records whether the
// chat delete endpoint is reached and answers success or failure.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class ChatDeletionConfirmationTests: XCTestCase {
    private let chatId = "11111111-1111-4111-8111-111111111111"
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func fixture(status: Int = 200) throws -> (AppModel, ChatDeletionRecorder, ChatSummary) {
        let suite = "ChatDeletionConfirmationTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
            defaults: defaults)
        let recorder = ChatDeletionRecorder(status: status)
        model.restTransportOverride = { await recorder.respond($0) }
        model.signedIn = true
        let chat = try XCTUnwrap(
            ChatSummary(json: .object(["id": .string(chatId), "title": .string("Quarterly notes")])))
        model.history = [chat]
        return (model, recorder, chat)
    }

    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    func testRequestingOrCancellingADeletionReachesNoEndpoint() async throws {
        let (model, recorder, chat) = try fixture()
        model.requestChatDeletion(chat)
        XCTAssertEqual(model.chatPendingDeletion?.chat, chat)
        await drain()
        var requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
        model.cancelChatDeletion()
        XCTAssertNil(model.chatPendingDeletion)
        await drain()
        requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.history, [chat])
        XCTAssertNil(model.errorBanner)
    }

    func testConfirmedDeletionRemovesTheChat() async throws {
        let (model, recorder, chat) = try fixture()
        model.requestChatDeletion(chat)
        model.confirmChatDeletion(try XCTUnwrap(model.chatPendingDeletion))
        XCTAssertNil(model.chatPendingDeletion)
        for _ in 0..<2000 where !model.history.isEmpty { await Task.yield() }
        let requests = await recorder.requests
        XCTAssertEqual(requests, ["DELETE /api/chats/\(chatId)"])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.errorBanner)
    }

    func testServerFailureKeepsTheChatAndShowsAnError() async throws {
        for status in [403, 500] {
            let (model, recorder, chat) = try fixture(status: status)
            model.requestChatDeletion(chat)
            model.confirmChatDeletion(try XCTUnwrap(model.chatPendingDeletion))
            for _ in 0..<2000 where model.errorBanner == nil { await Task.yield() }
            let requests = await recorder.requests
            XCTAssertEqual(requests, ["DELETE /api/chats/\(chatId)"])
            XCTAssertEqual(model.history, [chat])
            XCTAssertTrue(model.bannerIsError)
            XCTAssertEqual(model.errorBanner, "Couldn't delete this conversation. It is still in your chats.")
        }
    }

    func testARequestFromAnotherSessionOrServerDeletesNothing() async throws {
        let (signedOut, signedOutRecorder, chat) = try fixture()
        signedOut.requestChatDeletion(chat)
        let stale = try XCTUnwrap(signedOut.chatPendingDeletion)
        signedOut.signedIn = false
        XCTAssertNil(signedOut.chatPendingDeletion)
        signedOut.signedIn = true
        signedOut.bindConversationAccount(
            try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "another-owner")))
        signedOut.confirmChatDeletion(stale)
        await drain()
        var requests = await signedOutRecorder.requests
        XCTAssertTrue(requests.isEmpty)

        let (moved, movedRecorder, movedChat) = try fixture()
        moved.requestChatDeletion(movedChat)
        let pending = try XCTUnwrap(moved.chatPendingDeletion)
        moved.serverBaseText = "https://changed.example.test"
        moved.confirmChatDeletion(pending)
        await drain()
        requests = await movedRecorder.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(moved.chatPendingDeletion)
    }

    func testMandatorySurfaceBlocksTheRequest() throws {
        let (model, _, chat) = try fixture()
        model.mandatorySurface = true
        model.requestChatDeletion(chat)
        XCTAssertNil(model.chatPendingDeletion)
    }

    #if os(macOS)
        func testWorkbenchDialogNamesTheChatCancelsOnReturnAndDeletesOnlyFromDelete() async throws {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let recorder = ChatDeletionRecorder(status: 200)
            model.restTransportOverride = { await recorder.respond($0) }
            let chat = try XCTUnwrap(
                ChatSummary(json: .object(["id": .string(chatId), "title": .string("Quarterly notes")])))
            model.history = [chat]
            let rows = try XCTUnwrap(SurfaceFixtures.json("mac-workbench")["cases"]?.arrayValue)
            let row = try XCTUnwrap(rows.first { $0["viewport"]?.arrayValue?.first?.numberValue == 1440 })
            model.handleFrame(
                InboundFrame(
                    name: "rote_config",
                    payload: .object([
                        "type": .string("rote_config"),
                        "device_profile": .object(["console": try XCTUnwrap(row["presentation"])]),
                    ])))
            let console = try XCTUnwrap(model.console)
            let presentation = try XCTUnwrap(model.consolePresentation)
            let mount = SurfaceMount(
                MacWorkbenchView(
                    console: console, presentation: presentation, workbench: try XCTUnwrap(presentation.workbench)),
                model: model, size: CGSize(width: 1440, height: 900))
            defer { mount.close() }
            try await mount.settle()
            func dialog() async throws -> NSWindow {
                for _ in 0..<40 where mount.window.attachedSheet == nil { try await mount.settle() }
                return try XCTUnwrap(mount.window.attachedSheet, "The delete confirmation did not open")
            }
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

            model.requestChatDeletion(chat)
            var sheet = try await dialog()
            let content = try XCTUnwrap(sheet.contentView)
            let labels = views(content).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(labels.contains { $0.contains("Quarterly notes") }, "\(labels)")
            sheet.sendEvent(try SurfaceKey.returnKey.event(windowNumber: sheet.windowNumber))
            for _ in 0..<40 where mount.window.attachedSheet != nil { try await mount.settle() }
            XCTAssertNil(mount.window.attachedSheet)
            XCTAssertNil(model.chatPendingDeletion)
            await drain()
            var requests = await recorder.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(model.history, [chat])

            model.requestChatDeletion(chat)
            sheet = try await dialog()
            let delete = try XCTUnwrap(
                views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "Delete" })
            delete.performClick(nil)
            for _ in 0..<2000 where !model.history.isEmpty { await Task.yield() }
            requests = await recorder.requests
            XCTAssertEqual(requests, ["DELETE /api/chats/\(chatId)"])
            XCTAssertTrue(model.history.isEmpty)
        }
    #endif
}

private actor ChatDeletionRecorder {
    let status: Int
    var requests: [String] = []

    init(status: Int) { self.status = status }

    func respond(_ request: URLRequest) -> (Int, Data) {
        requests.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
        return (status, Data("{}".utf8))
    }
}
