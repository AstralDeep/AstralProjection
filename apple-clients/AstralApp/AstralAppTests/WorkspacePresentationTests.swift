import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class WorkspacePresentationTests: XCTestCase {
    private let welcome = AstralComponent(
        json: .object([
            "type": .string("hero"), "data-welcome": .string("intro"),
            "component_id": .string("wel_intro"), "title": .string("How can I help?"),
        ]))!

    func testSendAndLateWelcomeRemainWorkUntilNewChat() {
        let model = AppModel()
        model.canvas = [welcome]
        XCTAssertFalse(model.workspaceStarted)
        model.sendChat("First request")
        XCTAssertTrue(model.workspaceStarted)
        XCTAssertTrue(model.workspaceCanvas.isEmpty)
        let result = AstralComponent(type: "text", raw: .object(["content": .string("Result")]))
        model.canvas = [result]
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"ui_render","target":"canvas","components":[{"type":"hero","data-welcome":"intro","component_id":"wel_late"}]}"#
            )!)
        XCTAssertEqual(model.workspaceCanvas, [result])
        model.canvas = []
        model.turns = []
        XCTAssertTrue(model.workspaceStarted)
        model.newChat()
        XCTAssertFalse(model.workspaceStarted)
    }

    func testDraftAndBackgroundArmStayForSameOwnerReconnectAndClearOnOwnerChange() async {
        let model = AppModel()
        let first = ConversationAccount(issuer: "https://iam.example.test", subject: "first")!
        let second = ConversationAccount(issuer: "https://iam.example.test", subject: "second")!
        model.bindConversationAccount(first)
        model.composerDraft = "Unsent private note\nsecond line"
        model.runInBackground = true
        model.bindConversationAccount(first)
        await model.handle(.disconnected(reason: "test disconnect"))
        XCTAssertEqual(model.composerDraft, "Unsent private note\nsecond line")
        XCTAssertTrue(model.runInBackground)
        model.bindConversationAccount(second)
        XCTAssertEqual(model.composerDraft, "")
        XCTAssertFalse(model.runInBackground)
        model.composerDraft = "Another draft"
        model.newChat()
        XCTAssertEqual(model.composerDraft, "")
    }

    func testBackgroundArmAppliesToExactlyOneSendAndKeepsComposerAvailable() throws {
        let model = AppModel()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.runInBackground = true
        model.sendChat("One")
        XCTAssertEqual(sent.last?["payload"]?["async_mode"], .bool(true))
        XCTAssertFalse(model.pendingReplace)
        XCTAssertFalse(model.runInBackground)
        model.sendChat("Two")
        XCTAssertNil(sent.last?["payload"]?["async_mode"])
        model.runInBackground = true
        model.sendEvent("chat_message", .object(["message": .string("Example")]))
        XCTAssertEqual(sent.last?["payload"]?["async_mode"], .bool(true))
        XCTAssertFalse(model.runInBackground)
    }

    func testDeniedAndEmptySendDoNotConsumeBackgroundArm() {
        let model = AppModel()
        model.runInBackground = true
        model.sendChat(" \n ")
        XCTAssertTrue(model.runInBackground)
        XCTAssertFalse(model.workspaceStarted)
        model.timelineReadOnly = true
        model.sendChat("Denied")
        XCTAssertTrue(model.runInBackground)
        XCTAssertFalse(model.workspaceStarted)
    }

    func testDelayedDownloadAfterOwnerChangeOrSignOutIsRemoved() async throws {
        for signOut in [false, true] {
            let model = AppModel()
            model.signedIn = true
            model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "one")!)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "astral-downloads/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("private.csv")
            try Data("synthetic private fixture".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: directory) }
            var continuation: CheckedContinuation<URL, Never>?
            let task = Task {
                try await model.downloadArtifact(from: "/export", suggestedFilename: nil) {
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            while continuation == nil { await Task.yield() }
            if signOut {
                await model.signOut(revokeRemote: false)
            } else {
                model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "two")!)
            }
            continuation?.resume(returning: file)
            do {
                _ = try await task.value
                XCTFail("Stale download must not reach the native save/share UI")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testSameOwnerDownloadSurvivesReconnectButCancellationRemovesFile() async throws {
        let model = AppModel()
        model.signedIn = true
        let account = ConversationAccount(issuer: "https://iam.test", subject: "one")!
        model.bindConversationAccount(account)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astral-downloads/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("export.csv")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }
        let completed = try await model.downloadArtifact(from: "/export", suggestedFilename: nil) {
            model.bindConversationAccount(account)
            return file
        }
        XCTAssertEqual(completed, file)
        let task = Task {
            try await model.downloadArtifact(from: "/export", suggestedFilename: nil) { file }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled download must not be offered")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAuditAndAgentsRouteThroughServerOwnedSurface() throws {
        for surface in ["audit", "agents"] {
            let model = AppModel()
            var sent: JSONValue?
            model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
            model.openSurface(surface, params: .object(["event_type": .string("denied")]))
            XCTAssertEqual(model.screen, .surface)
            XCTAssertEqual(sent?["action"], .string("chrome_open"))
            XCTAssertEqual(sent?["payload"]?["params"]?["event_type"], .string("denied"))
            XCTAssertEqual(model.pendingSurfaceKey, surface)
        }
    }
}
