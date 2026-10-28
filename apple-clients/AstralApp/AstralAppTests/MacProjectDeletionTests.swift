// Verifies project deletion confirmation and account/navigation fences through the real catalog transport.
// Synthetic responses model success, already-absent projects, server failures and delayed completion.

#if os(macOS)
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacProjectDeletionTests: XCTestCase {
        func testCancelDoesNotDeleteOrNavigate() async throws {
            let (model, server) = try await fixture()
            let project = try XCTUnwrap(model.projects.projects.first)
            model.requestProjectDeletion(project)
            XCTAssertEqual(model.projectPendingDeletion?.id, project.id)
            model.cancelProjectDeletion()
            model.confirmProjectDeletion()
            for _ in 0..<100 { await Task.yield() }
            let requests = await server.deletes
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNil(model.projectPendingDeletion)
            XCTAssertEqual(model.activeChatId, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(model.composerDraft, "preserved draft")
        }

        func testConfirmedAndAlreadyAbsentDeletionClearOnlyTheDeletedProject() async throws {
            for status in [200, 404] {
                let (model, server) = try await fixture(status: status)
                let project = try XCTUnwrap(model.projects.projects.first)
                model.requestProjectDeletion(project)
                model.confirmProjectDeletion()
                for _ in 0..<2000 where model.projects.projects.contains(where: { $0.id == project.id }) {
                    await Task.yield()
                }
                for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
                let requests = await server.deletes
                XCTAssertEqual(requests, [project.id])
                XCTAssertNil(model.projects.errorMessage)
                XCTAssertNil(model.projectPendingDeletion)
                XCTAssertNil(model.projects.selectedId)
                XCTAssertNil(model.activeChatId)
                XCTAssertEqual(model.projects.projects.map(\.id), [server.other])
                XCTAssertNil(model.projects.chats[project.id])
                XCTAssertEqual(model.projects.chats[server.other]?.map(\.id), ["22222222-2222-4222-8222-222222222222"])
            }
        }

        func testStorageOrAuthenticationFailureKeepsProjectAndConversation() async throws {
            for status in [403, 500] {
                let (model, server) = try await fixture(status: status)
                let project = try XCTUnwrap(model.projects.projects.first)
                model.requestProjectDeletion(project)
                model.confirmProjectDeletion()
                for _ in 0..<2000 where model.projects.errorMessage == nil { await Task.yield() }
                let requests = await server.deletes
                XCTAssertEqual(requests, [project.id])
                XCTAssertNotNil(model.projects.errorMessage)
                XCTAssertEqual(model.projects.projects.count, 2)
                XCTAssertEqual(model.activeChatId, "11111111-1111-4111-8111-111111111111")
                XCTAssertEqual(model.composerDraft, "preserved draft")
            }
        }

        func testServerChangeRetiresAnUnconfirmedDelete() async throws {
            let (model, server) = try await fixture()
            model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
            model.serverBaseText = "https://changed.example.test"
            model.confirmProjectDeletion()
            for _ in 0..<100 { await Task.yield() }
            let requests = await server.deletes
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNil(model.projectPendingDeletion)
        }

        func testDelayedDeletionDoesNotClearAnotherConversationOrDraft() async throws {
            let (model, server) = try await fixture()
            await server.hold()
            let project = try XCTUnwrap(model.projects.projects.first)
            model.requestProjectDeletion(project)
            model.confirmProjectDeletion()
            for _ in 0..<2000 where await server.deletes.isEmpty { await Task.yield() }
            model.activeChatId = "22222222-2222-4222-8222-222222222222"
            model.projects.select(server.other)
            model.composerDraft = "another conversation draft"
            await server.release()
            for _ in 0..<2000 where model.projects.projects.contains(where: { $0.id == project.id }) {
                await Task.yield()
            }
            XCTAssertEqual(model.activeChatId, "22222222-2222-4222-8222-222222222222")
            XCTAssertEqual(model.composerDraft, "another conversation draft")
            XCTAssertEqual(model.projects.selectedId, server.other)
            XCTAssertNil(model.projects.errorMessage)
        }

        func testConfirmedDeleteClearsTheSavedResumeAnchorWithoutSocketDelivery() async throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let store = ConversationResumeStore(defaults: defaults)
            let account = try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "owner"))
            let (model, server) = try await fixture(resumeStore: store)
            model.bindConversationAccount(account)
            model.activeChatId = "11111111-1111-4111-8111-111111111111"
            XCTAssertTrue(store.save(chatId: try XCTUnwrap(model.activeChatId), for: account))
            model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
            model.confirmProjectDeletion()
            for _ in 0..<2000 where model.projects.projects.contains(where: { $0.id == server.project }) {
                await Task.yield()
            }
            for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
            XCTAssertNil(store.load(for: account))
            XCTAssertNil(model.activeChatId)
        }

        func testDelayedDeletionClearsNavigationToAnotherChatInTheDeletedProject() async throws {
            let (model, server) = try await fixture()
            await server.hold()
            let project = try XCTUnwrap(model.projects.projects.first)
            model.requestProjectDeletion(project)
            model.confirmProjectDeletion()
            for _ in 0..<2000 where await server.deletes.isEmpty { await Task.yield() }
            model.activeChatId = "33333333-3333-4333-8333-333333333333"
            await server.release()
            for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
            XCTAssertNil(model.activeChatId)
            XCTAssertNil(model.projects.errorMessage)
        }

        func testUnrelatedMutationCannotDiscardACommittedDeletionOrReviveItsSnapshot() async throws {
            for renameStatus in [200, 500] {
                let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
                let store = ConversationResumeStore(defaults: defaults)
                let account = try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "owner"))
                let (model, server) = try await fixture(resumeStore: store)
                model.bindConversationAccount(account)
                model.activeChatId = "11111111-1111-4111-8111-111111111111"
                XCTAssertTrue(store.save(chatId: try XCTUnwrap(model.activeChatId), for: account))
                await server.hold()
                await server.configureRename(status: renameStatus)
                model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
                model.confirmProjectDeletion()
                for _ in 0..<2000 where await server.deletes.isEmpty { await Task.yield() }
                let other = try XCTUnwrap(model.projects.projects.first { $0.id == server.other })
                let rename = Task { await model.projects.rename(other, name: "Renamed") }
                if renameStatus == 200 {
                    for _ in 0..<2000 where await !server.snapshotHeld() { await Task.yield() }
                    let held = await server.snapshotHeld()
                    XCTAssertTrue(held)
                } else {
                    await rename.value
                    XCTAssertEqual(model.projects.errorMessage, "Newer rename refusal")
                }
                await server.release()
                for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
                await server.releaseSnapshot()
                await rename.value
                XCTAssertNil(model.activeChatId)
                XCTAssertNil(store.load(for: account))
                XCTAssertFalse(model.projects.projects.contains { $0.id == server.project })
                if renameStatus == 500 { XCTAssertEqual(model.projects.errorMessage, "Newer rename refusal") }
            }
        }

        func testCommittedDeleteClearsResumeWhenFolderReconciliationFails() async throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let store = ConversationResumeStore(defaults: defaults)
            let account = try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "owner"))
            let (model, server) = try await fixture(resumeStore: store)
            model.bindConversationAccount(account)
            model.activeChatId = "11111111-1111-4111-8111-111111111111"
            XCTAssertTrue(store.save(chatId: try XCTUnwrap(model.activeChatId), for: account))
            model.projects.onReconciled = { _ in
                throw ProjectAPIError.refused(status: 500, code: "local", message: "Local folder state unavailable")
            }
            model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
            model.confirmProjectDeletion()
            for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
            XCTAssertNil(model.activeChatId)
            XCTAssertNil(store.load(for: account))
            XCTAssertFalse(model.projects.projects.contains { $0.id == server.project })
            XCTAssertEqual(model.projects.errorMessage, "Local folder state unavailable")
        }

        func testConfirmationRetainsMembersAfterAnotherMacDeletesTheProject() async throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let store = ConversationResumeStore(defaults: defaults)
            let account = try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "owner"))
            let (model, server) = try await fixture(status: 404, resumeStore: store)
            model.bindConversationAccount(account)
            model.activeChatId = "11111111-1111-4111-8111-111111111111"
            XCTAssertTrue(store.save(chatId: try XCTUnwrap(model.activeChatId), for: account))
            model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
            await server.removeProject()
            await model.projects.refresh()
            XCTAssertFalse(model.projects.projects.contains { $0.id == server.project })
            model.confirmProjectDeletion()
            for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
            XCTAssertNil(model.activeChatId)
            XCTAssertNil(store.load(for: account))
            XCTAssertNil(model.projects.errorMessage)
        }

        func testHeldDeleteClearsAChatThatArrivesAfterConfirmation() async throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let store = ConversationResumeStore(defaults: defaults)
            let account = try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "owner"))
            let (model, server) = try await fixture(resumeStore: store)
            model.bindConversationAccount(account)
            await server.hold()
            model.requestProjectDeletion(try XCTUnwrap(model.projects.projects.first))
            model.confirmProjectDeletion()
            for _ in 0..<2000 where await server.deletes.isEmpty { await Task.yield() }
            await server.publishChat()
            await model.projects.refresh()
            model.activeChatId = "44444444-4444-4444-8444-444444444444"
            XCTAssertTrue(store.save(chatId: try XCTUnwrap(model.activeChatId), for: account))
            await server.release()
            for _ in 0..<2000 where model.activeChatId != nil { await Task.yield() }
            XCTAssertNil(model.activeChatId)
            XCTAssertNil(store.load(for: account))
            XCTAssertNil(model.projects.errorMessage)
        }

        private func fixture(
            status: Int = 200, resumeStore: ConversationResumeStore = ConversationResumeStore()
        ) async throws -> (AppModel, ProjectDeletionTestServer) {
            let server = ProjectDeletionTestServer(status: status)
            let model = AppModel(
                conversationResumeStore: resumeStore, tokenStore: InMemoryTokenStore(),
                defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.projects.bind(
                scope: "owner/server",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            XCTAssertNil(model.projects.errorMessage)
            model.projects.select(server.project)
            model.activeChatId = "11111111-1111-4111-8111-111111111111"
            model.composerDraft = "preserved draft"
            return (model, server)
        }
    }

    private actor ProjectDeletionTestServer {
        nonisolated let project = "12345678-1234-4234-9234-123456789abc"
        nonisolated let other = "87654321-4321-4321-8321-cba987654321"
        let status: Int
        var deletes: [String] = []
        var deleted = false
        var extraChat = false
        func removeProject() { deleted = true }
        func publishChat() { extraChat = true }
        var holding = false
        var continuation: CheckedContinuation<Void, Never>?
        var renameStatus = 500
        var snapshot: CheckedContinuation<Void, Never>?
        func configureRename(status: Int) { renameStatus = status }
        func snapshotHeld() -> Bool { snapshot != nil }
        func releaseSnapshot() {
            snapshot?.resume()
            snapshot = nil
        }
        init(status: Int) { self.status = status }
        func hold() { holding = true }
        func release() {
            holding = false
            continuation?.resume()
            continuation = nil
        }
        func respond(_ request: URLRequest) async throws -> (Int, Data) {
            if request.httpMethod == "PATCH" {
                let value: JSONValue =
                    renameStatus == 200
                    ? .object([
                        "project_id": .string(other), "name": .string("Renamed"), "position": .number(0),
                        "revision": .number(2), "created_at": .number(1), "updated_at": .number(2),
                    ])
                    : .object(["detail": .object(["message": .string("Newer rename refusal")])])
                return (renameStatus, try value.encoded())
            }
            if request.httpMethod == "DELETE" {
                deletes.append(request.url!.lastPathComponent)
                if holding { await withCheckedContinuation { continuation = $0 } }
                if status == 200 || status == 404 { deleted = true }
                return (
                    status,
                    try JSONValue.object([
                        "detail": .object([
                            "code": .string("project_not_found"), "message": .string("Synthetic refusal"),
                        ])
                    ]).encoded()
                )
            }
            if request.url!.path == "/api/projects" {
                let rows = (deleted ? [other] : [project, other]).map { id in
                    JSONValue.object([
                        "project_id": .string(id), "name": .string("Synthetic project"), "position": .number(0),
                        "revision": .number(1), "created_at": .number(1), "updated_at": .number(1),
                    ])
                }
                if renameStatus == 200, holding { await withCheckedContinuation { snapshot = $0 } }
                return (200, try JSONValue.object(["projects": .array(rows), "next_cursor": .null]).encoded())
            }
            let selected = request.url!.path.contains(project) ? project : other
            var chatIds =
                selected == project
                ? ["11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333"]
                : ["22222222-2222-4222-8222-222222222222"]
            if selected == project, extraChat { chatIds.append("44444444-4444-4444-8444-444444444444") }
            return (
                200,
                try JSONValue.object([
                    "project_id": .string(selected), "next_cursor": .null,
                    "chats": .array(
                        chatIds.map { identity in
                            .object([
                                "id": .string(identity),
                                "project_id": .string(selected), "title": .string("Saved conversation"),
                            ])
                        }),
                ]).encoded()
            )
        }
    }
#endif
