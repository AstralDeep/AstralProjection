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
        @ObservationIgnored private var refreshDuringCreation = false
        @ObservationIgnored private var pendingProject: (String, String)?
        @ObservationIgnored private var observedActivity: [String: (raw: String, timestamp: Double)] = [:]

        static func mostRecentFirst(_ chats: [ChatSummary]) -> [ChatSummary] {
            chats.sorted { left, right in
                let leftActivity = activityTimestamp(left.updatedAt)
                let rightActivity = activityTimestamp(right.updatedAt)
                switch (leftActivity, rightActivity) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.id < right.id
                }
            }
        }

        private static func activityTimestamp(_ value: String) -> Double? {
            guard let timestamp = Double(value), timestamp.isFinite, timestamp >= 0 else { return nil }
            return timestamp >= 1e11 ? timestamp / 1000 : timestamp
        }

        private static func updatingActivity(_ chat: ChatSummary, project: String, updatedAt: String) -> ChatSummary? {
            ChatSummary(json: .object([
                "id": .string(chat.id), "project_id": .string(project),
                "title": .string(chat.title), "updated_at": .string(updatedAt),
                "preview": .string(chat.preview),
                "has_saved_components": .bool(chat.hasSavedComponents),
                "icon": .string(chat.icon),
                "time": .null,
                "pinned": .bool(chat.pinned), "archived": .bool(chat.archived),
            ]))
        }

        func mergeRecentActivity(_ summaries: [ChatSummary]) {
            guard enabled, !summaries.isEmpty else { return }
            var timestamps: [String: (String, Double)] = [:]
            for summary in summaries {
                guard let timestamp = Self.activityTimestamp(summary.updatedAt) else { continue }
                if let current = timestamps[summary.id], current.1 >= timestamp { continue }
                timestamps[summary.id] = (summary.updatedAt, timestamp)
            }
            for project in Array(chats.keys) {
                guard var values = chats[project] else { continue }
                var changed = false
                for index in values.indices {
                    let current = values[index]
                    guard let incoming = timestamps[current.id],
                        observedActivity[current.id].map({ incoming.1 > $0.timestamp }) ?? true
                    else { continue }
                    observedActivity[current.id] = (incoming.0, incoming.1)
                    if Self.activityTimestamp(current.updatedAt).map({ incoming.1 > $0 }) ?? true,
                        let updated = Self.updatingActivity(current, project: project, updatedAt: incoming.0)
                    {
                        values[index] = updated
                        changed = true
                    }
                }
                if changed {
                    chats[project] = values
                }
            }
        }

        func bind(scope: String?, client: RestClient?) {
            epoch = UUID()
            refreshEpoch = UUID()
            mutationEpoch = UUID()
            enabled = false
            negotiating = scope != nil && client != nil
            loading = false
            creatingChat = false
            refreshDuringCreation = false
            self.client = client
            if self.scope != scope {
                projects = []
                chats = [:]
                observedActivity = [:]
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
            if creatingChat { refreshDuringCreation = true }
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
                for project in Array(allChats.keys) {
                    guard let values = allChats[project] else { continue }
                    allChats[project] = values.map { chat in
                        guard let observed = observedActivity[chat.id],
                            Self.activityTimestamp(chat.updatedAt).map({ observed.timestamp > $0 }) ?? true
                        else { return chat }
                        return Self.updatingActivity(chat, project: project, updatedAt: observed.raw) ?? chat
                    }
                }
                projects = rows.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
                chats = allChats
                observedActivity = [:]
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
        func delete(_ project: ProjectRecord) async -> Set<String>? {
            guard enabled, let client else { return nil }
            let operation = beginMutation()
            let connection = epoch
            do {
                do {
                    try await client.deleteProject(id: project.id, revision: project.revision, deleteChats: true)
                } catch let error as ProjectAPIError {
                    guard case .refused(404, _, _) = error else { throw error }
                }
                try current(connection)
                refreshEpoch = UUID()
                loading = false
                let deletedChats = Set(chats[project.id]?.map(\.id) ?? [])
                deletedChats.forEach { observedActivity.removeValue(forKey: $0) }
                projects.removeAll { $0.id == project.id }
                chats.removeValue(forKey: project.id)
                pendingChats.removeValue(forKey: project.id)
                if selectedId == project.id { select(nil) }
                do {
                    try onReconciled(Set(projects.map(\.id)))
                } catch {
                    try current(connection)
                    fail(error, connection: connection, operation: operation)
                    return deletedChats
                }
                if mutationEpoch == operation {
                    errorMessage = nil
                    await refresh()
                }
                try current(connection)
                return deletedChats
            } catch {
                fail(error, connection: connection, operation: operation)
                return nil
            }
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
                    json: .object([
                        "id": .string(id), "project_id": .string(project), "title": .string(""),
                        "updated_at": .number(Date().timeIntervalSince1970 * 1000),
                    ]))
                {
                    let current = chats[project]?.first { $0.id == id } ?? chat
                    chats[project, default: []].removeAll { $0.id == id }
                    chats[project, default: []].insert(current, at: 0)
                }
                finishChatCreation(connection: connection)
                errorMessage = nil
                return id
            } catch {
                if epoch == connection, mutationEpoch == operation {
                    finishChatCreation(connection: connection)
                    if !(error is CancellationError) { errorMessage = error.localizedDescription }
                }
                throw error
            }
        }
        private func finishChatCreation(connection: UUID) {
            creatingChat = false
            refreshEpoch = UUID()
            loading = false
            guard refreshDuringCreation else { return }
            refreshDuringCreation = false
            Task { [weak self] in
                guard let self, self.epoch == connection else { return }
                await self.refresh()
            }
        }
        private func beginMutation() -> UUID {
            creatingChat = false
            refreshDuringCreation = false
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
