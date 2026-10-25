// Supplies the native chooser, bookmark and security-scope boundary for selected workspace grants.
// Immutable live defaults use public macOS APIs on the main actor.

#if os(macOS)
    import AppKit
    import Foundation

    @MainActor
    struct MacComputerWorkspaceGrantIO {
        let chooseDirectories: @MainActor () -> [URL]?
        let resolveBookmark: @MainActor (Data) throws -> (URL, Bool)
        let makeBookmark: @MainActor (URL) throws -> Data
        let startAccess: @MainActor (URL) -> Bool
        let stopAccess: @MainActor (URL) -> Void

        static let live = MacComputerWorkspaceGrantIO(
            chooseDirectories: {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.message = "Choose dedicated folders that Astral may read and change after server authorization."
                return panel.runModal() == .OK ? panel.urls : nil
            },
            resolveBookmark: {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            makeBookmark: {
                try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            },
            startAccess: { $0.startAccessingSecurityScopedResource() },
            stopAccess: { $0.stopAccessingSecurityScopedResource() })
    }
#endif
