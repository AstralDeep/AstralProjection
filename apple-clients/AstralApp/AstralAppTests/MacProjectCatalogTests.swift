// Verifies complete project catalog reconciliation and replay-safe chat creation.
// Scripted Bearer transport isolates network failure and delayed responses from presentation state.

#if os(macOS)
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacProjectCatalogTests: XCTestCase {
        let project = "12345678-1234-1234-9234-123456789abc"
        func testNoSelectionRefusesAndUncertainCreationReusesExactRequest() async throws {
            let server = ProjectCatalogServer(project: project)
            let catalog = MacProjectCatalog()
            catalog.bind(
                scope: "owner/server/device",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
                    transport: { try await server.respond($0) }))
            catalog.negotiate(true)
            await catalog.refresh()
            XCTAssertEqual(catalog.projects.map(\.id), [project])
            do {
                _ = try await catalog.createChat()
                XCTFail("selection required")
            } catch {}
            catalog.select(project)
            do {
                _ = try await catalog.createChat()
                XCTFail("first response lost")
            } catch {}
            let id = try await catalog.createChat()
            let requests = await server.created
            XCTAssertEqual(requests, [id, id])
            XCTAssertNil(catalog.errorMessage)
            XCTAssertEqual(catalog.selectedId, project)
        }
        func testAllTextCreationEntrypointsPreserveDraftAndRetryTheSameChat() async throws {
            for route in ["button", "event", "send", "component"] {
                let server = ProjectCatalogServer(project: project)
                let model = AppModel(
                    tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
                model.projects.bind(
                    scope: "owner/server/device",
                    client: RestClient(
                        serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                        transport: { try await server.respond($0) }))
                model.projects.negotiate(true)
                await model.projects.refresh()
                model.projects.select(project)
                model.activeChatId = "old-chat"
                model.composerDraft = "draft"
                model.staged = [
                    .init(
                        uid: 1, filename: "notes.txt", category: "text", attachmentId: "attachment", state: "ready",
                        note: nil)
                ]
                var sent: [JSONValue] = []
                model.outboundTap = { if let frame = try? JSONValue.parse(Data($0.utf8)) { sent.append(frame) } }
                func submit() {
                    switch route {
                    case "button": model.newChat()
                    case "event": model.sendEvent("new_chat")
                    case "send": model.sendChat("draft")
                    default: model.sendEvent("chat_message", .object(["message": .string("component")]))
                    }
                }
                submit()
                for _ in 0..<2000 where model.errorBanner == nil { await Task.yield() }
                XCTAssertEqual(model.activeChatId, "old-chat", route)
                XCTAssertEqual(model.composerDraft, "draft", route)
                XCTAssertEqual(model.staged.count, 1, route)
                XCTAssertFalse(
                    sent.contains { $0["action"] == .string("new_chat") || $0["action"] == .string("chat_message") },
                    route)
                submit()
                for _ in 0..<2000 where model.activeChatId == "old-chat" { await Task.yield() }
                let requests = await server.created
                XCTAssertEqual(requests.count, 2, route)
                XCTAssertEqual(requests.first, requests.last, route)
                XCTAssertEqual(model.activeChatId, requests.last, route)
                XCTAssertFalse(sent.contains { $0["action"] == .string("new_chat") }, route)
            }
        }
        func testMissingSelectionOpensChooserAndResumesOnlyTheCurrentIntent() async throws {
            for route in ["button", "event", "send", "component", "voice"] {
                let server = ProjectCatalogServer(project: project)
                await server.succeedCreations()
                let model = AppModel(
                    tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
                model.projects.bind(
                    scope: "owner",
                    client: RestClient(
                        serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                        transport: { try await server.respond($0) }))
                model.projects.negotiate(true)
                await model.projects.refresh()
                model.composerDraft = "preserved"
                model.activeChatId = "old-chat"
                switch route {
                case "button": model.newChat()
                case "event": model.sendEvent("new_chat")
                case "send": model.sendChat("preserved")
                case "component": model.sendEvent("chat_message", .object(["message": .string("component")]))
                default: await model.activateVoice()
                }
                XCTAssertTrue(model.projectChooserPresented, route)
                XCTAssertEqual(model.composerDraft, "preserved", route)
                XCTAssertEqual(model.activeChatId, "old-chat", route)
                model.chooseProjectForPendingChat(project)
                for _ in 0..<2000 where model.activeChatId == "old-chat" { await Task.yield() }
                XCTAssertFalse(model.projectChooserPresented, route)
                let created = await server.created
                XCTAssertEqual(created.count, 1, route)
                XCTAssertEqual(model.activeChatId, created.first, route)
                model.voice.close()
            }
        }

        func testServerChangeRetiresPendingProjectChoiceAndCatalog() async throws {
            let server = ProjectCatalogServer(project: project)
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            model.newChat()
            XCTAssertTrue(model.projectChooserPresented)
            model.serverBaseText = "https://another.test"
            XCTAssertFalse(model.projects.enabled)
            XCTAssertFalse(model.projectChooserPresented)
            model.chooseProjectForPendingChat(project)
            let created = await server.created
            XCTAssertTrue(created.isEmpty)
        }

        func testEmptyCatalogCreationOffersFoldersAndPickerCancellationKeepsTextChat() async throws {
            for folders in [false, true] {
                let server = ProjectCatalogServer(project: project)
                await server.startEmpty()
                await server.succeedCreations()
                let io = MacComputerTestWorkspaceGrants()
                io.selection = nil
                var bytes: [String: Data] = [:]
                let grants = MacProjectGrants(
                    grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
                let host = MacComputerHost(available: false, projectGrants: grants)
                let model = AppModel(
                    tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                    computerHost: host)
                host.beginWorkspaceNegotiation(server: URL(string: "https://example.test")!, account: "owner")
                host.workspaceNegotiated(projects: true)
                model.projects.bind(
                    scope: "owner",
                    client: RestClient(
                        serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                        transport: { try await server.respond($0) }))
                model.projects.negotiate(true)
                await model.projects.refresh()
                XCTAssertTrue(model.projects.projects.isEmpty)
                model.newChat()
                XCTAssertTrue(model.projectChooserPresented)
                await model.createProject(name: "New project", chooseFolders: folders)
                model.projectChoiceDidDismiss()
                for _ in 0..<2000 where model.activeChatId == nil { await Task.yield() }
                XCTAssertEqual(model.projects.projects.count, 1)
                XCTAssertNotNil(model.activeChatId)
                XCTAssertFalse(model.projectChooserPresented)
                XCTAssertEqual(io.choices, folders ? 1 : 0)
                XCTAssertTrue(grants.manifest?.projects.isEmpty == true)
            }
        }

        func testCreatedProjectWaitsForChooserDismissalBeforeOpeningNativeFolders() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            for url in [first, second] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let (model, io, server, grants) = await projectChoiceFixture(selection: [first, second])
            defer {
                io.onChoose = nil
                grants.bind(server: nil, account: nil, device: "mac")
            }
            model.composerDraft = "preserved draft"
            model.staged = [
                .init(
                    uid: 1, filename: "notes.txt", category: "text", attachmentId: "attachment", state: "ready",
                    note: nil)
            ]
            io.onChoose = {
                XCTAssertFalse(model.projectChooserPresented)
                XCTAssertNil(model.activeChatId)
                XCTAssertEqual(model.composerDraft, "preserved draft")
                XCTAssertEqual(model.staged.count, 1)
            }
            model.newChat()
            await model.createProject(name: "New project", chooseFolders: true)
            XCTAssertFalse(model.projectChooserPresented)
            XCTAssertEqual(io.choices, 0)
            XCTAssertNil(model.activeChatId)
            XCTAssertEqual(model.composerDraft, "preserved draft")
            let created = await server.created
            XCTAssertTrue(created.isEmpty)
            model.projectChoiceDidDismiss()
            model.projectChoiceDidDismiss()
            for _ in 0..<2000 where model.activeChatId == nil { await Task.yield() }
            XCTAssertEqual(io.choices, 1)
            XCTAssertNotNil(model.activeChatId)
            XCTAssertEqual(model.composerDraft, "preserved draft")
            XCTAssertEqual(model.staged.count, 1)
            XCTAssertEqual(grants.roots(project: try XCTUnwrap(model.projects.selectedId)), [first.path, second.path])
            let completed = await server.created
            XCTAssertEqual(completed.count, 1)
        }

        func testDelayedProjectPickerCannotResumeAfterItsIntentChanges() async throws {
            for change in ["cancel", "server", "account", "connection", "navigation", "selection", "intent"] {
                let (model, io, server, _) = await projectChoiceFixture()
                model.composerDraft = "preserved"
                model.newChat()
                await model.createProject(name: "New project", chooseFolders: true)
                switch change {
                case "cancel": model.cancelProjectChoice()
                case "server": model.serverBaseText = "https://another.test"
                case "account":
                    model.bindConversationAccount(ConversationAccount(issuer: "https://id.test", subject: "other")!)
                case "connection": _ = model.beginConversationConnection(UUID().uuidString.lowercased())
                case "navigation": model.activeChatId = "other-chat"
                case "selection": model.projects.select(nil)
                default:
                    model.projects.select(nil)
                    model.newChat()
                }
                model.projectChoiceDidDismiss()
                for _ in 0..<100 { await Task.yield() }
                XCTAssertEqual(io.choices, 0, change)
                let created = await server.created
                XCTAssertTrue(created.isEmpty, change)
                if change == "intent" { XCTAssertTrue(model.projectChooserPresented) }
                if change == "cancel" || change == "selection" || change == "intent" {
                    XCTAssertEqual(model.composerDraft, "preserved", change)
                }
            }
        }

        func testReconnectNegotiationCannotFallBackToLegacyChatActions() async throws {
            let (model, _, server, _) = await projectChoiceFixture()
            await model.createProject(name: "Existing project", chooseFolders: false)
            model.projectChoiceDidDismiss()
            _ = model.beginConversationConnection(UUID().uuidString.lowercased())
            let replay = try XCTUnwrap(
                QueuedOperationReplay(
                    frameText: Outbound.uiEvent(
                        action: "chat_message", sessionId: UUID().uuidString.lowercased(),
                        payload: .object(["message": .string("queued project turn")]), snapshotPurpose: .commit)))
            XCTAssertTrue(model.replayQueuedOperation(replay))
            await model.handle(.disconnected(reason: "reconnect"))
            XCTAssertTrue(model.projects.projectPresentation)
            XCTAssertFalse(model.projects.enabled)
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.composerDraft = "retained draft"
            model.activeChatId = "existing-chat"
            var sent: [JSONValue] = []
            model.outboundTap = { if let value = try? JSONValue.parse(Data($0.utf8)) { sent.append(value) } }
            model.newChat()
            model.sendEvent("new_chat")
            model.sendChat("retained draft")
            model.sendEvent("chat_message", .object(["message": .string("component")]))
            model.openChat("other-chat")
            XCTAssertEqual(model.activeChatId, "existing-chat")
            XCTAssertEqual(model.composerDraft, "retained draft")
            XCTAssertFalse(model.replayQueuedOperation(replay))
            XCTAssertFalse(
                sent.contains { ["new_chat", "chat_message", "load_chat"].contains($0["action"]?.stringValue ?? "") })
            XCTAssertFalse(model.projects.enabled)
            XCTAssertTrue(model.projects.projectPresentation)
            XCTAssertEqual(model.projects.projects.count, 1)
            model.projects.negotiate(false)
            XCTAssertFalse(model.projects.projectPresentation)
            model.newChat()
            XCTAssertTrue(sent.contains { $0["action"] == .string("new_chat") })
        }

        func testGenericErrorDoesNotWithdrawProjectNegotiation() async throws {
            let (model, _, _, _) = await projectChoiceFixture()
            let frame = try XCTUnwrap(
                InboundFrame.parse(#"{"type":"error","code":"operation_failed","message":"Retry the request"}"#))
            await model.handle(.frame(frame))
            XCTAssertTrue(model.projects.enabled)
        }

        func testSidebarCreationWaitsForSheetDismissalBeforeChoosingFolders() async throws {
            let (model, io, server, _) = await projectChoiceFixture()
            await model.createProject(name: "Existing project", chooseFolders: false)
            model.projectChoiceDidDismiss()
            XCTAssertNotNil(model.projects.selectedId)
            model.presentProjectCreation()
            XCTAssertTrue(model.projectChooserPresented)
            await model.createProject(name: "New project", chooseFolders: true)
            XCTAssertFalse(model.projectChooserPresented)
            XCTAssertEqual(io.choices, 0)
            XCTAssertEqual(model.projects.projects.count, 1)
            XCTAssertNotNil(model.projects.selectedId)
            XCTAssertNil(model.activeChatId)
            model.projectChoiceDidDismiss()
            XCTAssertEqual(io.choices, 1)
            let created = await server.created
            XCTAssertTrue(created.isEmpty)
        }

        func testPickerReturnRechecksIntentBeforeResumingChat() async throws {
            for change in ["cancel", "server", "account", "connection", "navigation", "selection", "capability"] {
                let (model, io, server, _) = await projectChoiceFixture()
                model.composerDraft = "preserved"
                model.newChat()
                await model.createProject(name: "New project", chooseFolders: true)
                io.onChoose = {
                    switch change {
                    case "cancel": model.cancelProjectChoice()
                    case "server": model.serverBaseText = "https://another.test"
                    case "account":
                        model.bindConversationAccount(ConversationAccount(issuer: "https://id.test", subject: "other")!)
                    case "connection": _ = model.beginConversationConnection(UUID().uuidString.lowercased())
                    case "navigation": model.activeChatId = "other-chat"
                    case "selection": model.projects.select(nil)
                    default: model.projects.negotiate(false)
                    }
                }
                model.projectChoiceDidDismiss()
                io.onChoose = nil
                for _ in 0..<100 { await Task.yield() }
                XCTAssertEqual(io.choices, 1, change)
                let created = await server.created
                XCTAssertTrue(created.isEmpty, change)
                if change == "cancel" || change == "selection" {
                    XCTAssertEqual(model.composerDraft, "preserved", change)
                }
            }
        }

        private func projectChoiceFixture(selection: [URL]? = nil) async -> (
            AppModel, MacComputerTestWorkspaceGrants, ProjectCatalogServer, MacProjectGrants
        ) {
            let server = ProjectCatalogServer(project: project)
            await server.startEmpty()
            await server.succeedCreations()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = selection
            var bytes: [String: Data] = [:]
            let grants = MacProjectGrants(
                grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
            let host = MacComputerHost(available: false, projectGrants: grants)
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                computerHost: host)
            host.beginWorkspaceNegotiation(server: URL(string: "https://example.test")!, account: "owner")
            host.workspaceNegotiated(projects: true)
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            return (model, io, server, grants)
        }

        func testVoiceWithoutSelectedProjectNeverCreatesAnUnscopedChat() async throws {
            let server = ProjectCatalogServer(project: project)
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            await model.activateVoice()
            XCTAssertNil(model.activeChatId)
            XCTAssertTrue(model.projectChooserPresented)
            let requests = await server.created
            XCTAssertTrue(requests.isEmpty)
        }

        func testLateChatResponseCannotNavigateAfterSelectionOrAccountChanges() async throws {
            for change in ["selection", "account", "rename"] {
                let server = ProjectCatalogServer(project: project)
                await server.holdCreations()
                let catalog = MacProjectCatalog()
                let client = RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) })
                catalog.bind(scope: "owner", client: client)
                catalog.negotiate(true)
                await catalog.refresh()
                catalog.select(project)
                let pending = Task { try await catalog.createChat() }
                while await server.created.isEmpty { await Task.yield() }
                switch change {
                case "selection": catalog.select(nil)
                case "account":
                    catalog.bind(scope: "other", client: client)
                    catalog.negotiate(true)
                default: await catalog.rename(catalog.projects[0], name: "Renamed")
                }
                await server.releaseCreation()
                do {
                    _ = try await pending.value
                    XCTFail("late creation adopted after \(change)")
                } catch {}
                XCTAssertFalse(catalog.creatingChat, change)
                XCTAssertTrue(catalog.chats.values.flatMap { $0 }.isEmpty, change)
                if change != "rename" { XCTAssertNil(catalog.selectedId, change) }
                XCTAssertNil(catalog.errorMessage, change)
            }
        }

        func testPartialCatalogFailureCannotQuarantineOrPublishPartialRows() async throws {
            let server = ProjectCatalogServer(project: project)
            let catalog = MacProjectCatalog()
            catalog.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            catalog.negotiate(true)
            var reconciled: [Set<String>] = []
            catalog.onReconciled = { reconciled.append($0) }
            await catalog.refresh()
            await server.failPagination()
            await catalog.refresh()
            XCTAssertEqual(catalog.projects.map(\.id), [project])
            XCTAssertEqual(reconciled, [[project]])
            XCTAssertNotNil(catalog.errorMessage)
        }
    }

    actor ProjectCatalogServer {
        var project: String
        var empty = false
        func startEmpty() { empty = true }
        var created: [String] = []
        var pagedFailure = false
        var loseFirst = true
        func succeedCreations() { loseFirst = false }
        var heldCreation: CheckedContinuation<Void, Never>?
        var hold = false
        func holdCreations() { hold = true }
        func releaseCreation() {
            hold = false
            heldCreation?.resume()
            heldCreation = nil
        }
        init(project: String) { self.project = project }
        func failPagination() { pagedFailure = true }
        func respond(_ request: URLRequest) async throws -> (Int, Data) {
            if request.httpMethod == "PATCH" {
                return (
                    200,
                    try JSONValue.object([
                        "project_id": .string(project), "name": .string("Renamed"), "position": .number(0),
                        "revision": .number(2), "created_at": .number(1), "updated_at": .number(2),
                    ]).encoded()
                )
            }
            if request.url!.path == "/api/projects", request.httpMethod == "POST" {
                let value = try JSONValue.parse(request.httpBody!)
                project = value["project_id"]!.stringValue!
                empty = false
                return (
                    200,
                    try JSONValue.object([
                        "project_id": .string(project), "name": value["name"]!, "position": .number(0),
                        "revision": .number(1), "created_at": .number(1), "updated_at": .number(1),
                    ]).encoded()
                )
            }
            if request.url!.path == "/api/projects" {
                if request.url!.query != nil && request.url!.query!.contains("cursor") {
                    throw URLError(.networkConnectionLost)
                }
                let record: JSONValue = .object([
                    "project_id": .string(project), "name": .string("Project"), "position": .number(0),
                    "revision": .number(1), "created_at": .number(1), "updated_at": .number(1),
                ])
                return (
                    200,
                    try JSONValue.object([
                        "projects": .array(empty ? [] : [record]),
                        "next_cursor": pagedFailure ? .string("next") : .null,
                    ]).encoded()
                )
            }
            if request.url!.path.hasSuffix("/chats") && request.httpMethod == "GET" {
                return (
                    200,
                    try JSONValue.object(["project_id": .string(project), "chats": .array([]), "next_cursor": .null])
                        .encoded()
                )
            }
            let value = try JSONValue.parse(request.httpBody!)
            let id = value["chat_id"]!.stringValue!
            created.append(id)
            if hold {
                await withCheckedContinuation { heldCreation = $0 }
            } else if loseFirst && created.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return (200, try JSONValue.object(["chat_id": .string(id), "project_id": .string(project)]).encoded())
        }
    }
#endif
