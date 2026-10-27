// Persists device-local project bookmarks separately from synchronized project metadata and legacy grants.
// Replacements revoke authority before releasing resources and publish only durable, catalog-reconciled manifests.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import Foundation
    import Observation

    @MainActor struct MacProjectGrantPersistence {
        let read: (String) throws -> Data?
        let write: (String, Data) throws -> Void
        static let live = MacProjectGrantPersistence(
            read: { key in
                let url = try location(key)
                return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            },
            write: { key, data in
                try data.write(to: location(key), options: [.atomic, .completeFileProtection])
            })
        private static func location(_ key: String) throws -> URL {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            .appendingPathComponent("AstralDeep/ProjectGrants", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return root.appendingPathComponent(key + ".json")
        }
    }

    @MainActor @Observable final class MacProjectGrants {
        private struct Bookmark: Codable {
            let data: Data
            let identity: ComputerWorkspaceIdentity
        }
        private struct Entry: Codable {
            var revision: UInt64
            var bookmarks: [Bookmark]
            var quarantined: Bool
        }
        private struct Document: Codable {
            let scope: String
            var generation: UInt64
            var projects: [String: Entry]
        }
        private struct Resource {
            let url: URL
            let accessed: Bool
            let workspace: ComputerWorkspace
            let bookmark: Bookmark
        }
        private(set) var manifest: ComputerProjectManifest?
        private(set) var errorMessage: String?
        @ObservationIgnored var onRevoke: (String) -> Void = { _ in }
        @ObservationIgnored private let grants: MacComputerWorkspaceGrantIO
        @ObservationIgnored private let persistence: MacProjectGrantPersistence
        @ObservationIgnored private var key: String?
        @ObservationIgnored private var epoch = UUID()
        @ObservationIgnored private var document: Document?
        @ObservationIgnored private var resources: [String: [Resource]] = [:]
        @ObservationIgnored private var catalog: Set<String>?
        @ObservationIgnored private var failedScopes: Set<String> = []
        @ObservationIgnored private var choices: [String: UUID] = [:]
        init(grants: MacComputerWorkspaceGrantIO? = nil, persistence: MacProjectGrantPersistence = .live) {
            self.grants = grants ?? .live
            self.persistence = persistence
        }
        static func scope(server: URL, account: String, device: String) -> String {
            var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
            parts.fragment = nil
            parts.query = nil
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            let bytes = try! JSONEncoder().encode([parts.string!, account, device])
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        func bind(server: URL?, account: String?, device: String) {
            let next = server.flatMap { server in
                account.map { Self.scope(server: server, account: $0, device: device) }
            }
            guard next != key else { return }
            epoch = UUID()
            for project in resources.keys { onRevoke(project) }
            let released = resources.values.flatMap { $0 }
            resources = [:]
            release(released)
            manifest = nil
            catalog = nil
            key = next
            document = nil
            errorMessage = nil
            guard let next else { return }
            let operation = epoch
            do {
                if let bytes = try persistence.read(next) {
                    let stored = try JSONDecoder().decode(Document.self, from: bytes)
                    guard stored.scope == next, stored.generation < 9_007_199_254_740_991,
                        stored.projects.count <= 4096,
                        stored.projects.allSatisfy({
                            ProjectIdentity.valid($0.key) && (1...9_007_199_254_740_990).contains($0.value.revision)
                                && $0.value.bookmarks.count <= 16
                        })
                    else {
                        throw ComputerHostError("invalid_project_grant", "Saved project folders cannot be verified.")
                    }
                    try current(operation, key: next)
                    document = stored
                } else {
                    document = Document(scope: next, generation: 1, projects: [:])
                }
                if failedScopes.contains(next) {
                    throw ComputerHostError(
                        "project_storage_failed", "Choose project folders again after restoring local storage.")
                }
            } catch { if epoch == operation { errorMessage = error.localizedDescription } }
        }
        func awaitReconciliation() {
            manifest = nil
            catalog = nil
        }
        func reconcile(projectIds: Set<String>) throws {
            guard projectIds.allSatisfy(ProjectIdentity.valid), var candidate = document, let key else {
                throw ComputerHostError("project_catalog_unavailable", "The complete project catalog is not available.")
            }
            let operation = epoch
            catalog = projectIds
            for (id, entry) in candidate.projects where !projectIds.contains(id) && !entry.quarantined {
                let removed = resources.removeValue(forKey: id) ?? []
                onRevoke(id)
                release(removed)
                try current(operation, key: key)
                candidate.projects[id]?.revision = try increment(entry.revision)
                candidate.projects[id]?.quarantined = true
            }
            candidate.generation = try increment(candidate.generation)
            do {
                try persistence.write(key, JSONEncoder().encode(candidate))
                try current(operation, key: key)
                document = candidate
                guard !failedScopes.contains(key) else {
                    throw ComputerHostError(
                        "project_storage_failed", "Choose project folders again after restoring local storage.")
                }
                for (id, entry) in candidate.projects
                where projectIds.contains(id) && !entry.quarantined && resources[id] == nil {
                    var restored: [Resource] = []
                    do {
                        for bookmark in entry.bookmarks {
                            let (url, stale) = try grants.resolveBookmark(bookmark.data)
                            guard !stale else {
                                throw ComputerHostError("stale_project_grant", "Choose this project's folders again.")
                            }
                            restored.append(try retain(url, bookmark: bookmark))
                        }
                        try current(operation, key: key)
                        candidate.projects[id]?.revision = try increment(entry.revision)
                        candidate.generation = try increment(candidate.generation)
                        try persistence.write(key, JSONEncoder().encode(candidate))
                        try current(operation, key: key)
                        document = candidate
                        resources[id] = restored
                    } catch {
                        release(restored)
                        onRevoke(id)
                        try current(operation, key: key)
                        candidate.projects[id]?.revision = try increment(entry.revision)
                        candidate.projects[id]?.quarantined = true
                        candidate.generation = try increment(candidate.generation)
                        try persistence.write(key, JSONEncoder().encode(candidate))
                        try current(operation, key: key)
                        document = candidate
                        errorMessage = error.localizedDescription
                    }
                }
                try publish()
            } catch {
                if epoch == operation { fail(error) }
                throw error
            }
        }
        func roots(project: String) -> [String] {
            _ = manifest
            return resources[project, default: []].map { $0.workspace.root }
        }
        func choose(project: String) throws {
            let operation = epoch
            let choice = UUID()
            choices[project] = choice
            guard catalog?.contains(project) == true else {
                throw ComputerHostError("project_not_found", "Select an available project first.")
            }
            guard let urls = grants.chooseDirectories() else { return }
            guard epoch == operation, choices[project] == choice, catalog?.contains(project) == true else {
                throw CancellationError()
            }
            var selected: [Resource] = []
            do {
                for url in urls {
                    let item = try retain(url)
                    guard epoch == operation else {
                        release([item])
                        throw CancellationError()
                    }
                    if selected.contains(where: { $0.workspace.root == item.workspace.root }) {
                        release([item])
                    } else {
                        selected.append(item)
                    }
                }
                guard selected.count <= 16 else {
                    throw ComputerHostError("invalid_project_manifest", "Choose at most 16 folders per project.")
                }
                try replace(project: project, selected: selected)
            } catch {
                release(selected)
                if epoch == operation, !failedScopes.contains(key ?? "") { errorMessage = error.localizedDescription }
                throw error
            }
        }
        func remove(project: String, path: String) throws {
            choices[project] = UUID()
            let current = resources[project, default: []]
            try replace(project: project, selected: current.filter { $0.workspace.root != path }, retained: true)
        }
        func primary(project: String, path: String) throws {
            choices[project] = UUID()
            let current = resources[project, default: []]
            guard let first = current.first(where: { $0.workspace.root == path }) else { return }
            try replace(
                project: project, selected: [first] + current.filter { $0.workspace.root != path }, retained: true)
        }
        func snapshot(context: ComputerProjectContext?) throws -> [ComputerWorkspace] {
            guard let context, let manifest, context.manifestGeneration <= manifest.generation,
                let entry = manifest.projects.first(where: { $0.projectId == context.projectId }),
                entry.grantRevision == context.grantRevision
            else {
                throw ComputerHostError("stale_project_grant", "The origin project's folders are no longer available.")
            }
            return resources[context.projectId, default: []].map(\.workspace)
        }
        private func replace(project: String, selected: [Resource], retained: Bool = false) throws {
            guard var candidate = document, let key, catalog?.contains(project) == true else {
                throw CancellationError()
            }
            let operation = epoch
            let revision = try increment(candidate.projects[project]?.revision ?? 0)
            let proposed = try ComputerProjectWorkspace(
                projectId: project, grantRevision: revision, roots: selected.map { root($0.workspace.root) })
            let others = try candidate.projects.keys.sorted().compactMap { id -> ComputerProjectWorkspace? in
                guard id != project, catalog?.contains(id) == true, let entry = candidate.projects[id],
                    !entry.quarantined
                else { return nil }
                return try ComputerProjectWorkspace(
                    projectId: id, grantRevision: entry.revision, roots: roots(project: id).map(root))
            }
            _ = try ComputerProjectManifest(
                generation: try increment(candidate.generation), projects: others + [proposed])
            let old = resources.removeValue(forKey: project) ?? []
            onRevoke(project)
            guard epoch == operation, self.key == key else {
                release(old)
                throw CancellationError()
            }
            manifest = nil
            candidate.projects[project] = Entry(
                revision: revision, bookmarks: selected.map(\.bookmark), quarantined: true)
            candidate.generation = try increment(candidate.generation)
            document = candidate
            do {
                try persistence.write(key, JSONEncoder().encode(candidate))
                try current(operation, key: key)
                candidate.projects[project]?.quarantined = false
                try persistence.write(key, JSONEncoder().encode(candidate))
                try current(operation, key: key)
                document = candidate
                resources[project] = selected
                failedScopes.remove(key)
                try publish()
                errorMessage = nil
                release(
                    retained
                        ? old.filter { item in !selected.contains(where: { $0.workspace.root == item.workspace.root }) }
                        : old)
            } catch {
                if epoch == operation { resources.removeValue(forKey: project) }
                release(old)
                if epoch == operation { fail(error) }
                throw error
            }
        }
        private func current(_ operation: UUID, key: String) throws {
            guard epoch == operation, self.key == key else { throw CancellationError() }
        }
        private func retain(_ url: URL, bookmark: Bookmark? = nil) throws -> Resource {
            let accessed = grants.startAccess(url)
            do {
                let workspace = try ComputerWorkspace(root: url.path)
                if let bookmark, bookmark.identity != workspace.rootIdentity {
                    throw ComputerHostError("stale_project_grant", "The saved folder identity changed.")
                }
                let saved = try bookmark ?? Bookmark(data: grants.makeBookmark(url), identity: workspace.rootIdentity)
                let (resolved, stale) = try grants.resolveBookmark(saved.data)
                guard !stale, workspace.matchesRoot(resolved.path) else {
                    throw ComputerHostError("stale_project_grant", "The selected folder changed.")
                }
                return Resource(url: url, accessed: accessed, workspace: workspace, bookmark: saved)
            } catch {
                if accessed { grants.stopAccess(url) }
                throw error
            }
        }
        private func root(_ path: String) -> ComputerHostWorkspaceRoot {
            ComputerHostWorkspaceRoot(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        private func publish() throws {
            guard let document, let catalog else { return }
            let projects = try document.projects.keys.sorted().compactMap { id -> ComputerProjectWorkspace? in
                guard catalog.contains(id), let entry = document.projects[id], !entry.quarantined else { return nil }
                return try ComputerProjectWorkspace(
                    projectId: id, grantRevision: entry.revision, roots: roots(project: id).map(root))
            }
            manifest = try ComputerProjectManifest(generation: document.generation, projects: projects)
        }
        private func increment(_ value: UInt64) throws -> UInt64 {
            guard value < 9_007_199_254_740_991 else {
                throw ComputerHostError("project_revision_exhausted", "The project grant revision is exhausted.")
            }
            return value + 1
        }
        private func fail(_ error: Error) {
            if let key { failedScopes.insert(key) }
            manifest = nil
            let revoked = resources
            resources = [:]
            for (id, items) in revoked {
                onRevoke(id)
                if var entry = document?.projects[id] {
                    entry.revision = (try? increment(entry.revision)) ?? entry.revision
                    entry.quarantined = true
                    document?.projects[id] = entry
                }
                release(items)
            }
            errorMessage =
                "The folder change was not saved. Access is revoked for this session. Restarting may restore previously saved folders; retry when storage is available. \(error.localizedDescription)"
        }
        private func release(_ items: [Resource]) {
            for item in items where item.accessed { grants.stopAccess(item.url) }
        }
    }
#endif
