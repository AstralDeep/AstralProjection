// Holds owner/server-scoped directory grants selected in the native computer controls.
// Physical operations use AstralCore's descriptor-relative workspace boundary on the driver actor.

#if os(macOS)
    import AppKit
    import AstralCore
    import CryptoKit
    import Foundation
    import Observation

    @MainActor @Observable
    final class MacComputerFiles {
        private struct GrantRecord: Codable {
            let version: Int
            let scopeKey: String
            let bookmark: Data
            let identity: ComputerWorkspaceIdentity

            private enum CodingKeys: String, CodingKey {
                case version, bookmark, identity
                case scopeKey = "scope_key"
            }
        }
        private struct Resource {
            let url: URL
            let accessed: Bool
            let workspace: ComputerWorkspace
            let record: Data
        }
        private(set) var roots: [String] = []
        private(set) var errorMessage: String?
        @ObservationIgnored private var resources: [Resource] = []
        @ObservationIgnored private var scope: String?
        @ObservationIgnored private var scopeEpoch = UUID()
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let grants: MacComputerWorkspaceGrantIO
        init(defaults: UserDefaults = .standard, grants: MacComputerWorkspaceGrantIO? = nil) {
            self.defaults = defaults
            self.grants = grants ?? .live
        }
        func bind(_ owner: String?) {
            guard scope != owner else { return }
            scope = owner
            scopeEpoch = UUID()
            let epoch = scopeEpoch
            errorMessage = nil
            clearResources()
            guard scopeEpoch == epoch else { return }
            guard let key = storageKey, let stored = defaults.object(forKey: key) else { return }
            guard let entries = stored as? [Data] else {
                errorMessage = "A workspace grant cannot be verified. Choose that folder again."
                return
            }
            for data in entries {
                guard scopeEpoch == epoch else { return }
                guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    Set(document.keys) == Set(["version", "scope_key", "bookmark", "identity"]),
                    let record = try? JSONDecoder().decode(GrantRecord.self, from: data),
                    record.version == 1, record.scopeKey == key,
                    let (url, stale) = try? grants.resolveBookmark(record.bookmark), !stale
                else {
                    guard scopeEpoch == epoch else { return }
                    errorMessage = "A workspace grant cannot be verified. Choose that folder again."
                    continue
                }
                guard scopeEpoch == epoch else { return }
                retain(url, record: record)
            }
        }
        private var storageKey: String? {
            scope.map {
                "computer.workspaces." + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        func choose() {
            guard let key = storageKey else { return }
            let epoch = scopeEpoch
            errorMessage = nil
            guard let urls = grants.chooseDirectories() else { return }
            for url in urls {
                guard scopeEpoch == epoch else { return }
                retain(url)
            }
            save(epoch: epoch, key: key)
        }
        func remove(_ path: String) {
            let epoch = scopeEpoch
            let key = storageKey
            let removed = resources.filter { $0.workspace.root == path }
            resources.removeAll { $0.workspace.root == path }
            roots = resources.map { $0.workspace.root }
            for resource in removed where resource.accessed { grants.stopAccess(resource.url) }
            save(epoch: epoch, key: key)
        }
        func snapshot() -> [ComputerWorkspace] { resources.map(\.workspace) }
        private func retain(_ url: URL, record: GrantRecord? = nil) {
            guard let key = storageKey else { return }
            guard record == nil || record?.scopeKey == key else { return }
            let epoch = scopeEpoch
            let accessed = grants.startAccess(url)
            do {
                try verifyScope(epoch: epoch, key: key)
                let workspace = try ComputerWorkspace(root: url.path)
                if let record, workspace.rootIdentity != record.identity {
                    throw ComputerHostError(
                        "permission_denied", "The saved workspace identity changed. Choose it again.")
                }
                guard !roots.contains(workspace.root) else {
                    if accessed { grants.stopAccess(url) }
                    return
                }
                let captured = try record?.bookmark ?? grants.makeBookmark(url)
                try verifyScope(epoch: epoch, key: key)
                let (resolved, stale) = try grants.resolveBookmark(captured)
                try verifyScope(epoch: epoch, key: key)
                guard !stale, workspace.matchesRoot(resolved.path) else {
                    throw ComputerHostError(
                        "permission_denied", "The selected workspace changed. Choose that folder again.")
                }
                let saved =
                    record
                    ?? GrantRecord(version: 1, scopeKey: key, bookmark: captured, identity: workspace.rootIdentity)
                let encoded = try JSONEncoder().encode(saved)
                try verifyScope(epoch: epoch, key: key)
                resources.append(
                    Resource(
                        url: url, accessed: accessed, workspace: workspace, record: encoded))
                roots.append(workspace.root)
            } catch {
                if accessed { grants.stopAccess(url) }
                guard scopeEpoch == epoch, storageKey == key else { return }
                errorMessage = error.localizedDescription
            }
        }
        private func verifyScope(epoch: UUID, key: String) throws {
            guard scopeEpoch == epoch, storageKey == key else {
                throw ComputerHostError("permission_denied", "The workspace selection was superseded.")
            }
        }
        private func save(epoch: UUID, key: String?) {
            guard scopeEpoch == epoch, let key, storageKey == key else { return }
            defaults.set(
                resources.map(\.record), forKey: key)
        }
        private func clearResources() {
            let released = resources
            resources = []
            roots = []
            for resource in released where resource.accessed { grants.stopAccess(resource.url) }
        }
    }
#endif
