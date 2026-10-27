// Owns the server-synchronized Mac project catalog and replay-safe project/chat mutations.
// Complete paginated snapshots authorize local grant reconciliation; navigation and connection epochs fence late results.

#if os(macOS)
    import AstralCore
    import Foundation
    import Observation

    @MainActor @Observable final class MacProjectCatalog {
        private(set) var enabled = false
        private(set) var negotiating = false
        var projectPresentation: Bool { enabled || negotiating }
        private(set) var projects: [ProjectRecord] = []
        private(set) var chats: [String: [ChatSummary]] = [:]
        private(set) var selectedId: String?
        private(set) var loading = false
        private(set) var creatingChat = false
        private(set) var errorMessage: String?
        @ObservationIgnored var onReconciled: (Set<String>) throws -> Void = { _ in }
        @ObservationIgnored private var client: RestClient?
        @ObservationIgnored private var scope: String?
        @ObservationIgnored private var epoch = UUID()
        @ObservationIgnored private var refreshEpoch = UUID()
        @ObservationIgnored private var mutationEpoch = UUID()
        @ObservationIgnored private var selectionEpoch = UUID()
        @ObservationIgnored private var pendingChats: [String: String] = [:]
        @ObservationIgnored private var pendingProject: (String, String)?

        func bind(scope: String?, client: RestClient?) {
            epoch = UUID()
            refreshEpoch = UUID()
            mutationEpoch = UUID()
            enabled = false
            negotiating = scope != nil && client != nil
            loading = false
            creatingChat = false
            self.client = client
            if self.scope != scope {
                projects = []
                chats = [:]
                selectedId = nil
                pendingChats = [:]
                pendingProject = nil
                selectionEpoch = UUID()
            }
            self.scope = scope
            errorMessage = nil
        }
        func awaitNegotiation() {
            enabled = false
            negotiating = scope != nil && client != nil
        }
        func negotiate(_ accepted: Bool) {
            negotiating = false
            enabled = accepted && scope != nil && client != nil
        }
        func select(_ id: String?) {
            guard id == nil || projects.contains(where: { $0.id == id }) else { return }
            guard id != selectedId else { return }
            selectedId = id
            selectionEpoch = UUID()
        }
        func project(for chat: String) -> String? {
            chats.first(where: { $0.value.contains(where: { $0.id == chat }) })?.key
        }
        func refresh() async {
            guard enabled, let client else { return }
            let connection = epoch
            let operation = UUID()
            refreshEpoch = operation
            loading = true
            do {
                var rows: [ProjectRecord] = []
                var next: String?
                var seen: Set<String> = []
                repeat {
                    let page = try await client.projects(cursor: next)
                    try current(connection)
                    guard refreshEpoch == operation else { return }
                    rows += page.projects
                    next = page.nextCursor
                    if let next, !seen.insert(next).inserted { throw ProjectAPIError.invalidResponse }
                    guard rows.count <= 10000 else { throw ProjectAPIError.invalidResponse }
                } while next != nil
                guard Set(rows.map(\.id)).count == rows.count else { throw ProjectAPIError.invalidResponse }
                var allChats: [String: [ChatSummary]] = [:]
                for project in rows {
                    var values: [ChatSummary] = []
                    next = nil
                    seen = []
                    repeat {
                        let page = try await client.projectChats(id: project.id, cursor: next)
                        try current(connection)
                        guard refreshEpoch == operation else { return }
                        values += page.chats
                        next = page.nextCursor
                        if let next, !seen.insert(next).inserted { throw ProjectAPIError.invalidResponse }
                        guard values.count <= 10000 else { throw ProjectAPIError.invalidResponse }
                    } while next != nil
                    guard Set(values.map(\.id)).count == values.count else { throw ProjectAPIError.invalidResponse }
                    allChats[project.id] = values
                }
                try current(connection)
                guard refreshEpoch == operation else { return }
                projects = rows.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
                chats = allChats
                if let selectedId, !rows.contains(where: { $0.id == selectedId }) { select(nil) }
                loading = false
                errorMessage = nil
                try onReconciled(Set(rows.map(\.id)))
            } catch {
                guard epoch == connection, refreshEpoch == operation else { return }
                loading = false
                errorMessage = error.localizedDescription
            }
        }
        func createProject(name: String) async -> String? {
            guard enabled, let client else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let operation = beginMutation()
            let connection = epoch
            let navigation = selectionEpoch
            let id = pendingProject?.1 == trimmed ? pendingProject!.0 : UUID().uuidString.lowercased()
            pendingProject = (id, trimmed)
            do {
                let created = try await client.createProject(id: id, name: trimmed)
                try current(connection)
                guard mutationEpoch == operation else { return nil }
                pendingProject = nil
                projects.removeAll { $0.id == id }
                projects.append(created)
                chats[id] = []
                if selectionEpoch == navigation { select(id) }
                errorMessage = nil
                await refresh()
                try current(connection)
                return projects.contains(where: { $0.id == id }) ? id : nil
            } catch {
                fail(error, connection: connection, operation: operation)
                return nil
            }
        }
        func rename(_ project: ProjectRecord, name: String) async {
            guard enabled, let client else { return }
            let operation = beginMutation()
            let connection = epoch
            do {
                let updated = try await client.renameProject(
                    id: project.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    revision: project.revision)
                try current(connection)
                guard mutationEpoch == operation,
                    let index = projects.firstIndex(where: { $0.id == project.id && $0.revision == project.revision })
                else { return }
                projects[index] = updated
                errorMessage = nil
                await refresh()
            } catch { fail(error, connection: connection, operation: operation) }
        }
        func delete(_ project: ProjectRecord) async {
            guard enabled, let client else { return }
            let operation = beginMutation()
            let connection = epoch
            do {
                try await client.deleteProject(id: project.id, revision: project.revision)
                try current(connection)
                guard mutationEpoch == operation else { return }
                projects.removeAll { $0.id == project.id }
                chats.removeValue(forKey: project.id)
                pendingChats.removeValue(forKey: project.id)
                if selectedId == project.id { select(nil) }
                try onReconciled(Set(projects.map(\.id)))
                errorMessage = nil
                await refresh()
            } catch { fail(error, connection: connection, operation: operation) }
        }
        func createChat() async throws -> String {
            guard enabled, let client, let project = selectedId, projects.contains(where: { $0.id == project }) else {
                let error = ComputerHostError("project_selection_required", "Select a project before starting a chat.")
                errorMessage = error.localizedDescription
                throw error
            }
            guard !creatingChat else { throw CancellationError() }
            let connection = epoch
            let navigation = selectionEpoch
            let operation = beginMutation()
            creatingChat = true
            let id = pendingChats[project] ?? UUID().uuidString.lowercased()
            pendingChats[project] = id
            do {
                _ = try await client.createProjectChat(id: id, projectId: project)
                try current(connection)
                guard selectionEpoch == navigation, selectedId == project, mutationEpoch == operation else {
                    throw CancellationError()
                }
                pendingChats.removeValue(forKey: project)
                if let chat = ChatSummary(
                    json: .object(["id": .string(id), "project_id": .string(project), "title": .string("")]))
                {
                    chats[project, default: []].insert(chat, at: 0)
                }
                creatingChat = false
                errorMessage = nil
                return id
            } catch {
                if epoch == connection, mutationEpoch == operation {
                    creatingChat = false
                    if !(error is CancellationError) { errorMessage = error.localizedDescription }
                }
                throw error
            }
        }
        private func beginMutation() -> UUID {
            creatingChat = false
            mutationEpoch = UUID()
            refreshEpoch = UUID()
            loading = false
            return mutationEpoch
        }
        private func current(_ connection: UUID) throws {
            guard connection == epoch, enabled else { throw CancellationError() }
        }
        private func fail(_ error: Error, connection: UUID, operation: UUID) {
            guard connection == epoch, mutationEpoch == operation else { return }
            errorMessage = error.localizedDescription
        }
    }
#endif
