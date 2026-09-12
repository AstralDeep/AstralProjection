import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class ComponentAction088Tests: XCTestCase {
    private var suites: [String] = []

    private func ready() -> AppModel {
        let suite = "ComponentAction088Tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
            defaults: defaults)
        model.signedIn = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "one")!)
        model.activeChatId = "11111111-1111-4111-8111-111111111111"
        model.workspaceStarted = true
        model.canvas = [component()]
        return model
    }

    private func component() -> AstralComponent {
        let actions = ComponentActionKind.allCases.map { kind in
            JSONValue.object([
                "kind": .string(kind.rawValue), "label": .string(kind.rawValue), "icon": .string("↗"),
                "title": .string("Component action"),
                "context": .string(kind.requiresLiveCanvas ? "live_canvas" : "owned_chat"),
            ])
        }
        return AstralComponent(
            type: "table",
            raw: .object([
                "type": .string("table"), "component_id": .string("saved"), "title": .string("Synthetic result"),
                "component_chrome": .object(["version": .number(1), "actions": .array(actions)]),
                "versions": .array([.object(["version_no": .number(2), "title": .string("Earlier result")])]),
            ]))
    }

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    func testServerDescriptorsAndExactVisibleIdentityControlPresenceWithoutBusyRule() throws {
        let model = ready()
        let component = model.canvas[0]
        model.pendingReplace = true
        XCTAssertTrue(
            ComponentActionKind.allCases.allSatisfy {
                model.componentActionContext(for: $0, component: component) != nil
            })
        for change: (AppModel) -> Void in [
            { $0.signedIn = false }, { $0.activeChatId = nil }, { $0.mandatorySurface = true },
            { $0.screen = .history }, { $0.canvas = [] }, { $0.canvas.append(component) },
            { $0.workspaceStarted = false },
        ] {
            let other = ready()
            change(other)
            XCTAssertNil(other.componentActionContext(for: .refine, component: component))
        }
        var raw = component.raw.objectValue!
        raw.removeValue(forKey: "component_chrome")
        let legacy = AstralComponent(type: "table", raw: .object(raw))
        model.canvas = [legacy]
        XCTAssertNil(model.componentActionContext(for: .csv, component: legacy))
        XCTAssertNil(model.componentActionContext(for: .refine, component: component))
    }

    func testTimelineKeepsOwnedChatActionsButRejectsRefineAndHistory() {
        let model = ready()
        let component = model.canvas[0]
        model.timelineReadOnly = true
        XCTAssertNil(model.componentActionContext(for: .refine, component: component))
        XCTAssertNil(model.componentActionContext(for: .history, component: component))
        XCTAssertNotNil(model.componentActionContext(for: .csv, component: component))
        XCTAssertNotNil(model.componentActionContext(for: .share, component: component))
    }

    func testContextSurvivesUnrelatedResultAndReconnectButNotReplacementOwnerOrChat() throws {
        let model = ready()
        let context = try XCTUnwrap(model.componentActionContext(for: .history, component: model.canvas[0]))
        model.canvas.append(
            AstralComponent(
                type: "text", raw: .object(["component_id": .string("another"), "content": .string("Progress")])))
        model.connected = false
        model.connected = true
        XCTAssertTrue(model.componentActionIsCurrent(context))
        var raw = context.component.raw.objectValue!
        raw["title"] = .string("Changed result")
        model.canvas[0] = AstralComponent(type: "table", raw: .object(raw))
        XCTAssertFalse(model.componentActionIsCurrent(context))
        model.canvas[0] = context.component
        XCTAssertTrue(model.componentActionIsCurrent(context))
        model.activeChatId = "other"
        XCTAssertFalse(model.componentActionIsCurrent(context))
        model.activeChatId = context.chatId
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "two")!)
        XCTAssertFalse(model.componentActionIsCurrent(context))
    }

    func testDisconnectedRefineAndRestoreRefuseWithoutQueueOrOptimisticReplacement() throws {
        let model = ready()
        let component = model.canvas[0]
        let refine = try XCTUnwrap(model.componentActionContext(for: .refine, component: component))
        let history = try XCTUnwrap(model.componentActionContext(for: .history, component: component))
        var frames: [String] = []
        model.outboundTap = { frames.append($0) }
        model.refineComponent(refine, instruction: "  sort by value  ")
        model.restoreComponent(history, version: 2)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(model.errorBanner, "Reconnect before changing this component.")
        XCTAssertEqual(model.canvas, [component])
        XCTAssertFalse(model.componentActionInFlight(refine))
        XCTAssertFalse(model.componentActionInFlight(history))
        model.errorBanner = nil
        model.refineComponent(refine, instruction: " \n ")
        model.restoreComponent(history, version: 99)
        model.restoreComponent(refine, version: 2)
        model.timelineReadOnly = true
        model.refineComponent(refine, instruction: "sort")
        model.restoreComponent(history, version: 2)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertNil(model.errorBanner)
    }

    func testStaleCredentialRefreshCannotDispatchShareOrCSV() async throws {
        for kind in [ComponentActionKind.share, .csv] {
            let model = ready()
            let context = try XCTUnwrap(model.componentActionContext(for: kind, component: model.canvas[0]))
            var continuation: CheckedContinuation<String?, Never>?
            let token = Task {
                await model.componentAccessToken(context) { await withCheckedContinuation { continuation = $0 } }
            }
            while continuation == nil { await Task.yield() }
            model.canvas = []
            continuation?.resume(returning: "synthetic")
            let resolved = await token.value
            XCTAssertNil(resolved)
        }
    }

    func testDuplicatePendingMintIsRefusedAndLateLinkDiscarded() async throws {
        let model = ready()
        let context = try XCTUnwrap(model.componentActionContext(for: .share, component: model.canvas[0]))
        var continuation: CheckedContinuation<URL, Never>?
        let task = Task {
            try await model.shareComponent(context) { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        do {
            _ = try await model.shareComponent(context) {
                XCTFail("Duplicate mint dispatched")
                return URL(string: "https://unused.test")!
            }
            XCTFail("Duplicate accepted")
        } catch { XCTAssertTrue(error is AppModel.WorkspaceActionError) }
        model.canvas = []
        continuation?.resume(returning: URL(string: "https://astral.test/share/synthetic")!)
        do {
            _ = try await task.value
            XCTFail("Stale link delivered")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(model.componentActionInFlight(context))
    }

    func testStaleCSVCompletionDeletesOnlyItsPrivateTemporaryFile() async throws {
        let model = ready()
        let context = try XCTUnwrap(model.componentActionContext(for: .csv, component: model.canvas[0]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astral-downloads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("table.csv")
        try Data("Alpha,2".utf8).write(to: file)
        do {
            _ = try await model.downloadComponentCSV(context) {
                model.activeChatId = "other"
                return file
            }
            XCTFail("Stale file delivered")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(model.componentActionInFlight(context))
    }
    func testReplacementDoesNotInheritOldPendingShareAndOldCompletionIsDiscarded() async throws {
        let model = ready()
        let old = try XCTUnwrap(model.componentActionContext(for: .share, component: model.canvas[0]))
        var continuation: CheckedContinuation<URL, Never>?
        let task = Task {
            try await model.shareComponent(old) { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        var raw = old.component.raw.objectValue!
        raw["title"] = .string("Replacement result")
        model.canvas[0] = AstralComponent(type: "table", raw: .object(raw))
        let replacement = try XCTUnwrap(model.componentActionContext(for: .share, component: model.canvas[0]))
        XCTAssertFalse(model.componentActionIsCurrent(old))
        XCTAssertFalse(model.componentActionInFlight(replacement))
        let current = try await model.shareComponent(replacement) { URL(string: "https://astral.test/share/current")! }
        XCTAssertEqual(current.path, "/share/current")
        continuation?.resume(returning: URL(string: "https://astral.test/share/old")!)
        do {
            _ = try await task.value
            XCTFail("Replaced component delivered a late share")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(model.componentActionInFlight(replacement))
    }

}
