// Covers the Command-K palette: its rows, slash filter, disabled entries and keyboard selection, rendered in the
// three reference themes with focus checked through real key events.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    private struct PaletteHost: View {
        @State private var query: String
        let choose: (MacPaletteAction) -> Void

        init(query: String = "", choose: @escaping (MacPaletteAction) -> Void) {
            _query = State(initialValue: query)
            self.choose = choose
        }

        var body: some View {
            MacWorkbenchCommandPalette(context: MacPaletteContext(), query: $query, choose: choose)
        }
    }

    @MainActor
    final class MacCommandPaletteTests: XCTestCase {
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func menu(handoff: Bool = false) throws -> ChromeMenuModel {
            var root = try SurfaceFixtures.json("chrome-console")
            if handoff {
                var groups = try XCTUnwrap(root["menu"]?.arrayValue)
                var account = try XCTUnwrap(groups.first?.objectValue)
                var items = try XCTUnwrap(account["items"]?.arrayValue)
                var audit =
                    try XCTUnwrap(items.firstIndex { $0["key"]?.stringValue == "audit" }.map { items[$0] })
                    .objectValue ?? [:]
                audit["availability"] = .object(["mode": .string("handoff"), "message": .string("Open on the web")])
                items[try XCTUnwrap(items.firstIndex { $0["key"]?.stringValue == "audit" })] = .object(audit)
                account["items"] = .array(items)
                groups[0] = .object(account)
                root = try SurfaceFixtures.replacing(root, path: ["menu"], with: .array(groups))
            }
            return try XCTUnwrap(ChromeMenuModel.fromJSON(root))
        }

        private func model(menu: ChromeMenuModel?) throws -> AppModel {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            model.chromeMenu = menu
            return model
        }

        func testRowsListAppCommandsThenSlashActionsThenServerGroups() throws {
            let rows = MacCommandPaletteModel.rows(context: MacPaletteContext(), menu: try menu(), query: "")
            XCTAssertEqual(
                rows.map(\.id),
                [
                    "app/new-chat", "app/sidebar", "app/activity", "app/browser", "app/computer", "app/agents",
                    "app/updates", "app/settings", "app/cancel-turn", "app/sign-out", "chat/rename", "chat/pin",
                    "chat/archive", "composer/background",
                    "composer/advanced", "composer/timeline", "composer/pulse", "composer/work", "account/agents",
                    "account/llm", "account/personalization", "account/audit", "account/theme", "account/guidance",
                    "help/guide",
                ])
            XCTAssertEqual(rows.first?.title, "New Chat")
            XCTAssertEqual(rows.first { $0.id == "app/agents" }?.title, "Agent Directory…")
            XCTAssertEqual(rows.first { $0.id == "app/settings" }?.shortcut, "⌘,")
            XCTAssertEqual(rows.first { $0.id == "composer/timeline" }?.token, "/timeline")
            XCTAssertEqual(rows.first { $0.id == "composer/background" }?.detail, "Off")
            XCTAssertEqual(
                Set(rows.filter { !$0.enabled }.map(\.id)),
                [
                    "app/browser", "app/computer", "app/updates", "app/cancel-turn", "chat/rename", "chat/pin",
                    "chat/archive",
                ])
            XCTAssertEqual(
                Array(Set(rows.map(\.section))).sorted(), ["Account", "Actions", "Chat", "Composer", "Help"])
        }

        func testSlashQueriesKeepOnlyComposerActionsAndWordsMatchAcrossSections() throws {
            let menu = try menu()
            let context = MacPaletteContext()
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "/").map(\.id),
                ["composer/background", "composer/advanced", "composer/timeline", "composer/pulse", "composer/work"])
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "/time").map(\.id),
                ["composer/timeline"])
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "/ recent").map(\.id),
                ["composer/work"])
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "account llm").map(\.id),
                ["account/llm"])
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "PULSE").map(\.id),
                ["composer/pulse"])
            XCTAssertTrue(MacCommandPaletteModel.rows(context: context, menu: menu, query: "zzzz").isEmpty)
            XCTAssertTrue(MacCommandPaletteModel.rows(context: context, menu: menu, query: "/agents").isEmpty)
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: nil, query: "").map(\.id).first, "app/new-chat")
            XCTAssertTrue(MacCommandPaletteModel.rows(context: context, menu: nil, query: "/").isEmpty)
        }

        func testUnavailableEntriesAreDisabledWithTheirReasonAndNeverRunnable() throws {
            let menu = try menu(handoff: true)
            var context = MacPaletteContext(
                browserEnabled: true, computerAvailable: true, updatesEnabled: true, canCancelTurn: true)
            let audit = try XCTUnwrap(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "").first { $0.id == "account/audit" })
            XCTAssertFalse(audit.enabled)
            XCTAssertEqual(audit.detail, "Open on the web")
            XCTAssertFalse(MacCommandPaletteModel.runnable(audit.action, context: context, menu: menu))
            XCTAssertTrue(MacCommandPaletteModel.runnable(.computerControls, context: context, menu: menu))
            XCTAssertTrue(MacCommandPaletteModel.runnable(.composer("timeline"), context: context, menu: menu))
            context.composerLocked = true
            XCTAssertFalse(MacCommandPaletteModel.runnable(.composer("timeline"), context: context, menu: menu))
            context.composerLocked = false
            context.canNavigate = false
            for action in [
                MacPaletteAction.newChat, .toggleSidebar, .toggleBrowser, .agentDirectory, .composer("timeline"),
            ] {
                XCTAssertFalse(MacCommandPaletteModel.runnable(action, context: context, menu: menu), "\(action)")
            }
            XCTAssertTrue(MacCommandPaletteModel.runnable(.toggleActivity, context: context, menu: menu))
            let llm = try XCTUnwrap(menu.allItems.first { $0.key == "llm" })
            XCTAssertFalse(
                MacCommandPaletteModel.runnable(.menu(group: "account", item: llm), context: context, menu: menu))
            context.canNavigate = true
            XCTAssertTrue(
                MacCommandPaletteModel.runnable(.menu(group: "account", item: llm), context: context, menu: menu))
            let forgedMenu = try XCTUnwrap(
                ChromeMenuModel.fromJSON(
                    .object([
                        "menu": .array([
                            .object([
                                "key": .string("account"), "label": .string("Account"),
                                "items": .array([
                                    .object([
                                        "key": .string("llm"), "label": .string("LLM settings"),
                                        "surface": .string("admin_tools"),
                                    ])
                                ]),
                            ])
                        ])
                    ])))
            let forged = try XCTUnwrap(forgedMenu.allItems.first)
            XCTAssertFalse(
                MacCommandPaletteModel.runnable(.menu(group: "account", item: forged), context: context, menu: menu))
            XCTAssertFalse(MacCommandPaletteModel.runnable(.composer("unknown"), context: context, menu: menu))
            context.signedIn = false
            XCTAssertFalse(MacCommandPaletteModel.runnable(.signOut, context: context, menu: menu))
        }

        func testCurrentChatEntriesNameTheirStateAndNeedAConnectedOwner() throws {
            let menu = try menu()
            var context = MacPaletteContext(
                chat: MacPaletteChat(id: "c1", title: "Roll notes", pinned: true, archived: true))
            let rows = MacCommandPaletteModel.rows(context: context, menu: menu, query: "").filter {
                $0.section == "Chat"
            }
            XCTAssertEqual(rows.map(\.title), ["Rename Chat…", "Unpin Chat", "Unarchive Chat"])
            XCTAssertTrue(rows.allSatisfy(\.enabled))
            context.chat = MacPaletteChat(id: "c1", title: "Roll notes", pinned: false, archived: false)
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: menu, query: "").filter { $0.section == "Chat" }
                    .map(\.title),
                ["Rename Chat…", "Pin Chat", "Archive Chat"])
            for blocked in [
                MacPaletteContext(connected: false, chat: context.chat),
                MacPaletteContext(canNavigate: false, chat: context.chat),
                MacPaletteContext(chat: context.chat, signedIn: false),
                MacPaletteContext(),
            ] {
                for action in [MacPaletteAction.renameChat, .togglePin, .toggleArchive] {
                    XCTAssertFalse(MacCommandPaletteModel.runnable(action, context: blocked, menu: menu), "\(action)")
                }
            }
            XCTAssertEqual(MacCommandPaletteModel.renamedTitle("  Dice log \n", from: "Roll notes"), "Dice log")
            XCTAssertNil(MacCommandPaletteModel.renamedTitle("   ", from: "Roll notes"))
            XCTAssertNil(MacCommandPaletteModel.renamedTitle("Roll notes ", from: "Roll notes"))
            XCTAssertNotNil(MacCommandPaletteModel.renamedTitle(String(repeating: "a", count: 120), from: ""))
            XCTAssertNil(MacCommandPaletteModel.renamedTitle(String(repeating: "a", count: 121), from: ""))
        }

        func testRenameSheetSendsTheTrimmedTitleAndRefusesBlankOrLongNames() async throws {
            let model = try model(menu: try menu())
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            let chat = MacPaletteChat(id: "c1", title: "Roll notes", pinned: false, archived: false)
            for preset in SurfaceFixtures.presets {
                let mount = SurfaceMount(
                    MacRenameChatSheet(chat: chat), model: model, size: CGSize(width: 380, height: 160), preset: preset)
                defer { mount.close() }
                try await mount.settle()
                XCTAssertEqual(mount.focusedPrompt(), "Chat name", preset)
                XCTAssertTrue(try mount.text().contains("Rename Chat"), preset)
                try mount.snapshot(self, name: "rename_chat-\(preset)")
            }
            let blank = SurfaceMount(
                MacRenameChatSheet(chat: chat), model: model, size: CGSize(width: 380, height: 160))
            defer { blank.close() }
            try await blank.settle()
            blank.type("   ")
            try blank.key(.returnKey)
            try await blank.settle()
            let long = SurfaceMount(MacRenameChatSheet(chat: chat), model: model, size: CGSize(width: 380, height: 200))
            defer { long.close() }
            try await long.settle()
            long.type(String(repeating: "a", count: 121))
            try await long.settle()
            XCTAssertTrue(try long.text().contains("Use 120 characters or fewer"))
            try long.key(.returnKey)
            try await long.settle()
            XCTAssertTrue(sent.isEmpty, "\(sent)")
            let valid = SurfaceMount(
                MacRenameChatSheet(chat: chat), model: model, size: CGSize(width: 380, height: 160))
            defer { valid.close() }
            try await valid.settle()
            valid.type("  Dice log  ")
            try valid.key(.returnKey)
            try await valid.settle()
            XCTAssertEqual(sent.last?["action"], .string("chat_rename"))
            XCTAssertEqual(sent.last?["payload"]?["chat_id"], .string("c1"))
            XCTAssertEqual(sent.last?["payload"]?["title"], .string("Dice log"))
        }

        func testSelectionSkipsDisabledRowsAndStopsAtTheEnds() throws {
            let rows = MacCommandPaletteModel.rows(context: MacPaletteContext(), menu: try menu(), query: "")
            let enabled = rows.filter(\.enabled).map(\.id)
            XCTAssertEqual(MacCommandPaletteModel.firstEnabled(in: rows), "app/new-chat")
            XCTAssertEqual(MacCommandPaletteModel.move("app/activity", by: 1, in: rows), "app/agents")
            XCTAssertEqual(MacCommandPaletteModel.move("app/agents", by: -1, in: rows), "app/activity")
            XCTAssertEqual(MacCommandPaletteModel.move("app/new-chat", by: -1, in: rows), "app/new-chat")
            XCTAssertEqual(MacCommandPaletteModel.move(enabled.last, by: 1, in: rows), enabled.last)
            XCTAssertEqual(MacCommandPaletteModel.move(nil, by: 1, in: rows), "app/new-chat")
            XCTAssertEqual(MacCommandPaletteModel.move(nil, by: -1, in: rows), enabled.last)
            XCTAssertEqual(MacCommandPaletteModel.move("gone", by: 1, in: rows), "app/new-chat")
            XCTAssertNil(MacCommandPaletteModel.move(nil, by: 1, in: rows.filter { !$0.enabled }))
            XCTAssertNil(MacCommandPaletteModel.firstEnabled(in: []))
        }

        func testArrowsMoveTheHighlightAndReturnRunsItWithFocusInTheSearchField() async throws {
            let model = try model(menu: try menu())
            var chosen: [MacPaletteAction] = []
            let mount = SurfaceMount(
                PaletteHost { chosen.append($0) },
                model: model, size: CGSize(width: 560, height: 460))
            defer { mount.close() }
            try await mount.settle()
            XCTAssertEqual(mount.focusedPrompt(), "Search commands")
            try mount.key(.down)
            try mount.key(.down)
            try mount.key(.down)
            try mount.key(.up)
            try await mount.settle()
            XCTAssertEqual(mount.focusedPrompt(), "Search commands")
            try mount.key(.returnKey)
            try await mount.settle()
            XCTAssertEqual(chosen, [.toggleActivity])
            let second = SurfaceMount(
                PaletteHost { chosen.append($0) }, model: model, size: CGSize(width: 560, height: 460))
            defer { second.close() }
            try await second.settle()
            second.type("llm")
            try await second.settle()
            try second.key(.returnKey)
            try await second.settle()
            let llm = try XCTUnwrap(model.chromeMenu?.allItems.first { $0.key == "llm" })
            XCTAssertEqual(chosen.last, .menu(group: "account", item: llm))
            let third = SurfaceMount(
                PaletteHost { chosen.append($0) }, model: model, size: CGSize(width: 560, height: 460))
            defer { third.close() }
            try await third.settle()
            third.type(" zzz")
            try await third.settle()
            try third.key(.returnKey)
            try await third.settle()
            XCTAssertEqual(chosen.count, 2)
            XCTAssertTrue(try third.text().contains("No matching commands"))
        }

        func testSlashQueryFiltersToComposerActionsAndBackspaceRemovesTheSlash() async throws {
            let model = try model(menu: try menu())
            var chosen: [MacPaletteAction] = []
            let mount = SurfaceMount(
                PaletteHost(query: "/") { chosen.append($0) }, model: model, size: CGSize(width: 560, height: 460))
            defer { mount.close() }
            try await mount.settle()
            XCTAssertEqual(mount.focusedPrompt(), "Search commands")
            XCTAssertFalse(try mount.text().contains("New Chat"))
            mount.type("time")
            try await mount.settle()
            try mount.key(.returnKey)
            try await mount.settle()
            XCTAssertEqual(chosen, [.composer("timeline")])
            let second = SurfaceMount(
                PaletteHost(query: "/") { chosen.append($0) }, model: model, size: CGSize(width: 560, height: 460))
            defer { second.close() }
            try await second.settle()
            try second.key(.delete)
            try await second.settle()
            XCTAssertTrue(try second.text().contains("New Chat"))
            second.type("llm")
            try await second.settle()
            try second.key(.returnKey)
            try await second.settle()
            let llm = try XCTUnwrap(model.chromeMenu?.allItems.first { $0.key == "llm" })
            XCTAssertEqual(chosen.last, .menu(group: "account", item: llm))
        }

        func testClickingADisabledRowDoesNothingAndAnEnabledRowRuns() async throws {
            let model = try model(menu: try menu(handoff: true))
            var chosen: [MacPaletteAction] = []
            let mount = SurfaceMount(
                MacWorkbenchCommandPalette(
                    context: MacPaletteContext(), query: .constant("audit")
                ) {
                    chosen.append($0)
                }, model: model, size: CGSize(width: 560, height: 300))
            defer { mount.close() }
            try await mount.settle()
            XCTAssertTrue(try mount.text().contains("Open on the web"))
            try mount.click(text: "Audit")
            try mount.key(.returnKey)
            try await mount.settle()
            XCTAssertTrue(chosen.isEmpty, "\(chosen)")
        }

        func testPaletteRendersEveryStateInEachTheme() async throws {
            for preset in SurfaceFixtures.presets {
                for (name, menu, query) in [
                    ("palette", try menu(handoff: true), ""), ("palette_slash", try menu(), "/"),
                    ("palette_loading", nil, ""), ("palette_no_match", try menu(), "zzzz"),
                ] as [(String, ChromeMenuModel?, String)] {
                    let model = try model(menu: menu)
                    let context = MacPaletteContext(activityVisible: true, computerAvailable: true)
                    let mount = SurfaceMount(
                        MacWorkbenchCommandPalette(
                            context: context, query: .constant(query)
                        ) { _ in },
                        model: model, size: CGSize(width: 560, height: 460), preset: preset)
                    defer { mount.close() }
                    try await mount.settle()
                    let text = try mount.text()
                    switch name {
                    case "palette":
                        for kept in ["Actions", "New Chat", "Hide Activity", "Computer Controls", "Agent Directory"] {
                            XCTAssertTrue(text.contains(kept), "\(preset) \(name) missing \(kept): \(text)")
                        }
                        XCTAssertFalse(text.contains("Done"))
                    case "palette_slash":
                        for kept in ["/background", "/timeline", "Workspace timeline"] {
                            XCTAssertTrue(text.contains(kept), "\(preset) \(name) missing \(kept): \(text)")
                        }
                        XCTAssertFalse(text.contains("New Chat"), "\(preset): \(text)")
                    case "palette_loading":
                        XCTAssertTrue(text.contains("Loading commands"), "\(preset): \(text)")
                        XCTAssertTrue(text.contains("New Chat"), "\(preset): \(text)")
                    default:
                        XCTAssertTrue(text.contains("No matching commands"), "\(preset): \(text)")
                    }
                    try mount.snapshot(self, name: "\(name)-\(preset)")
                }
            }
        }

        func testPaletteExposesNamesStateAndSelectionToAccessibility() async throws {
            try SurfaceAccessibility.requireTrust()
            let model = try model(menu: try menu(handoff: true))
            let mount = SurfaceMount(
                MacWorkbenchCommandPalette(
                    context: MacPaletteContext(), query: .constant("")
                ) { _ in },
                model: model, size: CGSize(width: 560, height: 460))
            defer { mount.close() }
            try await mount.settle()
            let tree = mount.accessibility
            XCTAssertEqual(tree.first { $0.identifier == "workbench-command-search" }?.label, "Search commands")
            XCTAssertEqual(tree.first { $0.identifier == "workbench-command-close" }?.label, "Close")
            let first = try XCTUnwrap(tree.first { $0.identifier == "workbench-command-app/new-chat" })
            XCTAssertEqual(first.label, "New Chat")
            XCTAssertTrue(first.selected)
            let background = try XCTUnwrap(tree.first { $0.identifier == "workbench-command-composer/background" })
            XCTAssertEqual(background.label, "/background, Run in background")
            XCTAssertEqual(background.value, "Off")
            let audit = try XCTUnwrap(tree.first { $0.identifier == "workbench-command-account/audit" })
            XCTAssertFalse(audit.enabled)
            XCTAssertEqual(audit.value, "Open on the web")
            XCTAssertFalse(tree.contains { $0.identifier == "workbench-command-app/computer" && $0.enabled })
            XCTAssertEqual(
                tree.compactMap(\.identifier).filter { $0.hasPrefix("workbench-command-") }.prefix(3),
                ["workbench-command-search", "workbench-command-close", "workbench-command-app/new-chat"])
        }
    }
#endif
