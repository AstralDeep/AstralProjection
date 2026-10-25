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
        private(set) var roots: [String] = []
        private(set) var errorMessage: String?
        @ObservationIgnored private var workspaces: [ComputerWorkspace] = []
        @ObservationIgnored private var resources: [URL] = []
        @ObservationIgnored private var scope: String?
        @ObservationIgnored private let defaults: UserDefaults
        init(defaults: UserDefaults = .standard) { self.defaults = defaults }
        func bind(_ owner: String?) {
            guard scope != owner else { return }
            clearResources()
            scope = owner
            guard let key = storageKey, let bookmarks = defaults.array(forKey: key) as? [Data] else { return }
            for bookmark in bookmarks {
                var stale = false
                guard
                    let url = try? URL(
                        resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                        bookmarkDataIsStale: &stale), !stale
                else {
                    errorMessage = "A workspace grant expired. Choose that folder again."
                    continue
                }
                retain(url)
            }
        }
        private var storageKey: String? {
            scope.map {
                "computer.workspaces." + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        func choose() {
            guard scope != nil else { return }
            errorMessage = nil
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.message = "Choose dedicated folders that Astral may read and change after server authorization."
            guard panel.runModal() == .OK else { return }
            for url in panel.urls { retain(url) }
            save()
        }
        func remove(_ path: String) {
            let kept = resources.filter { $0.resolvingSymlinksInPath().path != path }
            clearResources()
            for url in kept { retain(url) }
            save()
        }
        func snapshot() -> [ComputerWorkspace] { workspaces }
        private func retain(_ url: URL) {
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                let workspace = try ComputerWorkspace(root: url.path)
                guard !roots.contains(workspace.root) else {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    return
                }
                resources.append(url)
                workspaces.append(workspace)
                roots.append(workspace.root)
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                errorMessage = error.localizedDescription
            }
        }
        private func save() {
            guard let key = storageKey else { return }
            defaults.set(
                resources.compactMap {
                    try? $0.bookmarkData(
                        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                }, forKey: key)
        }
        private func clearResources() {
            for resource in resources { resource.stopAccessingSecurityScopedResource() }
            resources = []
            roots = []
            workspaces = []
        }
    }
#endif
