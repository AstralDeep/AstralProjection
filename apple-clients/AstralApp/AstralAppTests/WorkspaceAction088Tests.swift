import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class WorkspaceAction088Tests: XCTestCase {
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let connection = "22222222-2222-4222-8222-222222222222"

    private func ready() -> AppModel {
        let defaults = UserDefaults(suiteName: "WorkspaceAction088.\(UUID().uuidString)")!
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: InMemoryTokenStore())
        model.signedIn = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "one")!)
        model.activeChatId = chat
        model.workspaceStarted = true
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Synthetic canvas")]))]
        model.chromeMenu = ChromeMenuModel.fromJSON(
            try! JSONValue.parse(
                Data(
                    #"{"version":2,"topbar":[{"key":"export","kind":"workspace_action","label":"Export page","icon":"download","operation":"export_canvas","context":"live_canvas"},{"key":"share","kind":"workspace_action","label":"Share page","icon":"share","operation":"share_canvas","context":"live_canvas"}]}"#
                        .utf8)))
        return model
    }

    func testActionsNeedCurrentServerCapabilityAndLiveCanvasButRemainAvailableWhileBusy() throws {
        let model = ready()
        XCTAssertNotNil(model.workspaceActionContext(for: .exportCanvas))
        XCTAssertNotNil(model.workspaceActionContext(for: .shareCanvas))
        model.pendingReplace = true
        model.liveOpsThisTurn = false
        XCTAssertTrue(model.showSkeleton)
        XCTAssertNotNil(model.workspaceActionContext(for: .exportCanvas))
        XCTAssertNotNil(model.workspaceActionContext(for: .shareCanvas))
        for invalidate: (AppModel) -> Void in [
            { $0.signedIn = false }, { $0.canvas = [] }, { $0.chromeMenu = nil },
            { $0.mandatorySurface = true }, { $0.timelineReadOnly = true },
            { $0.viewingIndex = 0 }, { $0.screen = .history }, { $0.activeChatId = nil },
            { $0.workspaceStarted = false },
        ] {
            let other = ready()
            invalidate(other)
            XCTAssertNil(other.workspaceActionContext(for: .exportCanvas))
            XCTAssertNil(other.workspaceActionContext(for: .shareCanvas))
        }
    }

    func testExportUsesOneEncodedChatSegmentAndExactRevisionQuery() throws {
        let model = ready()
        model.activeChatId = "a/b?c#d%2f"
        let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
        let url = try XCTUnwrap(model.workspaceExportURL(context))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.percentEncodedPath, "/api/export/canvas/a%2Fb%3Fc%23d%252f.html")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "render_revision", value: "0")])
        XCTAssertNil(parts.fragment)
    }

    func testCredentialRefreshCannotStartAnOldContextRequest() async throws {
        for invalidate: (AppModel) -> Void in [
            { $0.signedIn = false }, { $0.activeChatId = "other-chat" }, { $0.chromeMenu = nil },
            { $0.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "two")!) },
        ] {
            let model = ready()
            let context = try XCTUnwrap(model.workspaceActionContext(for: .shareCanvas))
            let credentials = WorkspaceCredentialGate()
            let client = RestClient(
                serverBase: model.serverBase,
                tokenProvider: {
                    await model.workspaceAccessToken(context) {
                        await credentials.resolve()
                    }
                },
                transport: { _ in
                    XCTFail("Stale credential must not issue a mint POST")
                    return (201, Data())
                }
            )
            let task = Task { try await client.shareCanvas(chatId: context.chatId) }
            while !(await credentials.isWaiting) { await Task.yield() }
            invalidate(model)
            await credentials.release()
            do {
                _ = try await task.value
                XCTFail("Stale mint")
            } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        }
    }

    func testDuplicateShareWhilePendingNeverReissuesAndLateLinkIsDiscarded() async throws {
        let model = ready()
        let context = try XCTUnwrap(model.workspaceActionContext(for: .shareCanvas))
        var continuation: CheckedContinuation<URL, Never>?
        let task = Task {
            try await model.shareWorkspaceCanvas(context) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(model.workspaceActionInFlight(.shareCanvas))
        do {
            _ = try await model.shareWorkspaceCanvas(context) {
                XCTFail("Duplicate mint")
                return URL(string: "https://unused.test")!
            }
            XCTFail("Duplicate accepted")
        } catch { XCTAssertTrue(error is AppModel.WorkspaceActionError) }
        model.activeChatId = "other"
        continuation?.resume(returning: URL(string: "https://example.test/share/synthetic")!)
        do {
            _ = try await task.value
            XCTFail("Old chat link delivered")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(model.workspaceActionInFlight(.shareCanvas))
    }

    func testUncertainShareDoesNotRetryAndReleasesExplicitActionLatch() async throws {
        let model = ready()
        let context = try XCTUnwrap(model.workspaceActionContext(for: .shareCanvas))
        var calls = 0
        do {
            _ = try await model.shareWorkspaceCanvas(context) {
                calls += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("Uncertain mint reported success")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.workspaceActionInFlight(.shareCanvas))
    }

    private func advanceRevision(_ model: AppModel) {
        let request = "33333333-3333-4333-8333-333333333333"
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .hydration))
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"conversation_snapshot","schema_version":1,
                 "snapshot_id":"55555555-5555-4555-8555-555555555555","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(request)",
                 "snapshot_purpose":"hydration","render_revision":1,"committed_at":"2026-07-15T18:41:00Z",
                 "transcript":[],"canvas":{"target":"canvas","components":[{"type":"text","content":"New canvas"}]}}
                """)!)
        XCTAssertEqual(model.lastCommittedRenderRevision, 1)
        model.workspaceStarted = true
    }

    func testStaleExportFileIsRemovedForChatOwnerRevisionAndCancellation() async throws {
        for change in 0..<4 {
            let model = ready()
            let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "astral-downloads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("canvas.html")
            try Data("synthetic".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: directory) }
            var continuation: CheckedContinuation<URL, Never>?
            let task = Task {
                try await model.downloadWorkspaceCanvas(context) {
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            while continuation == nil { await Task.yield() }
            switch change {
            case 0: model.activeChatId = "other"
            case 1: await model.signOut(revokeRemote: false)
            case 2: advanceRevision(model)
            default: task.cancel()
            }
            continuation?.resume(returning: file)
            do {
                _ = try await task.value
                XCTFail("Stale file offered")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(model.workspaceActionInFlight(.exportCanvas))
        }
    }

    func testShareUsesSnapshotAtMintWhileExportRequiresItsCapturedRevision() throws {
        let model = ready()
        let share = try XCTUnwrap(model.workspaceActionContext(for: .shareCanvas))
        let export = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
        advanceRevision(model)
        XCTAssertTrue(model.workspaceActionIsCurrent(share))
        XCTAssertFalse(model.workspaceActionIsCurrent(export))
    }

    func testCompactToolbarPreservesTargetsOrderAndTrailingRowsAt320AndEnlargedSizes() {
        for scale: CGFloat in [1, 2] {
            let width: CGFloat = 320 - 24 - 28 - 6
            let sizes = Array(repeating: CGSize(width: 44 * scale, height: 44 * scale), count: 7)
            let frames = AstralToolbarLayout.frames(sizes: sizes, width: width, spacing: 6, wraps: true)
            XCTAssertEqual(frames.count, 7)
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width)
                XCTAssertEqual(frame.size, sizes[index])
                if index > 0 {
                    let previous = frames[index - 1]
                    XCTAssertTrue(frame.minY > previous.minY || frame.minX > previous.maxX)
                }
            }
            XCTAssertEqual(frames.last?.maxX, width)
            XCTAssertGreaterThan(frames.last!.maxY, sizes[0].height)
        }
        let wide = AstralToolbarLayout.frames(
            sizes: Array(repeating: CGSize(width: 44, height: 44), count: 7), width: 900, spacing: 6, wraps: false)
        XCTAssertTrue(wide.allSatisfy { $0.minY == 0 })
        XCTAssertEqual(wide.last?.maxX, 900)
    }

    func testCancelledSaveCompletionCannotOverwriteDestinationOrAReplacementPresentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldFile = directory.appendingPathComponent("old.html")
        let newFile = directory.appendingPathComponent("new.html")
        let destination = directory.appendingPathComponent("saved.html")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)
        try Data("existing user document".utf8).write(to: destination)
        let old = NativeDownloadSaveLease(file: oldFile)
        var current: NativeDownloadSaveLease? = old
        old.cancel()
        try FileManager.default.removeItem(at: oldFile)
        let replacement = NativeDownloadSaveLease(file: newFile)
        current = replacement
        XCTAssertFalse(try old.save(to: destination, isCurrent: { current === old }))
        XCTAssertTrue(current === replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing user document")
        XCTAssertTrue(try replacement.save(to: destination, isCurrent: { current === replacement }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        try FileManager.default.removeItem(at: newFile)
        XCTAssertThrowsError(try replacement.save(to: destination, isCurrent: { true }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }
}

private actor WorkspaceCredentialGate {
    private var continuation: CheckedContinuation<String?, Never>?
    var isWaiting: Bool { continuation != nil }
    func resolve() async -> String? {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning: "synthetic-old-token")
        continuation = nil
    }
}
