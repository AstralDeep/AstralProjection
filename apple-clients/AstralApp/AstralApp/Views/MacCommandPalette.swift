// Command-K palette for the Mac workbench: the app's own commands, the server's slash composer actions and its
// settings menu in one keyboard list, plus the search field the agent directory and chat list share.
// MacWorkbenchView presents it as a sheet and runs the chosen action after the sheet closes.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacSearchField: View {
        @Environment(ThemeStore.self) private var theme
        let prompt: String
        @Binding var text: String
        var focused: FocusState<Bool>.Binding
        let identifier: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).frame(width: 24).foregroundStyle(
                    theme.palette.muted
                ).accessibilityHidden(true)
                TextField(prompt, text: $text).textFieldStyle(.plain).focused(focused)
                    .foregroundStyle(theme.palette.text)
                    .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            }
            .font(ConsoleTypography.subheadline)
            .padding(.horizontal, 8).frame(minHeight: 30)
            .background(theme.palette.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.fieldBorder))
        }
    }

    enum MacPaletteAction: Equatable {
        case newChat, toggleSidebar, toggleActivity, toggleBrowser, computerControls, agentDirectory
        case updates, settings, cancelTurn, signOut, toggleBypass
        case renameChat, togglePin, toggleArchive
        case composer(String)
        case menu(group: String, item: ChromeMenuItem)
    }

    struct MacPaletteChat: Equatable, Identifiable {
        let id: String
        let title: String
        let pinned: Bool
        let archived: Bool
    }

    struct MacPaletteContext: Equatable {
        var canNavigate = true
        var connected = true
        var chat: MacPaletteChat?
        var sidebarVisible = true
        var activityVisible = false
        var browserEnabled = false
        var browserVisible = false
        var computerAvailable = false
        var updatesEnabled = false
        var canCancelTurn = false
        var signedIn = true
        var composerLocked = false
        var runInBackground = false
        var computerEnabled = false
        var bypass = false
    }

    struct MacPaletteRow: Identifiable, Equatable {
        let id: String
        let section: String
        let title: String
        var token: String?
        var detail: String?
        var shortcut: String?
        let enabled: Bool
        let action: MacPaletteAction
    }

    enum MacCommandPaletteModel {
        static let actionsSection = "Actions"
        static let chatSection = "Chat"
        static let composerSection = "Composer"
        static let maximumTitleLength = 120

        static func renamedTitle(_ text: String, from current: String) -> String? {
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maximumTitleLength, title != current else { return nil }
            return title
        }

        static func rows(context: MacPaletteContext, menu: ChromeMenuModel?, query: String) -> [MacPaletteRow] {
            let all =
                appRows(context: context, menu: menu) + chatRows(context: context)
                + composerRows(context: context, menu: menu) + menuRows(context: context, menu: menu)
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/") {
                let words = normalized(String(trimmed.dropFirst())).split(whereSeparator: \.isWhitespace)
                return all.filter { row in
                    guard let token = row.token else { return false }
                    let text = normalized("\(token.dropFirst()) \(row.title)")
                    return words.allSatisfy { text.contains($0) }
                }
            }
            let words = normalized(trimmed).split(whereSeparator: \.isWhitespace)
            return all.filter { row in
                let text = normalized([row.section, row.title, row.token ?? ""].joined(separator: " "))
                return words.allSatisfy { text.contains($0) }
            }
        }

        static func firstEnabled(in rows: [MacPaletteRow]) -> String? { rows.first { $0.enabled }?.id }

        static func move(_ selection: String?, by delta: Int, in rows: [MacPaletteRow]) -> String? {
            let enabled = rows.filter(\.enabled).map(\.id)
            guard !enabled.isEmpty else { return nil }
            guard let selection, let index = enabled.firstIndex(of: selection) else {
                return delta < 0 ? enabled.last : enabled.first
            }
            return enabled[min(max(index + delta, 0), enabled.count - 1)]
        }

        static func runnable(_ action: MacPaletteAction, context: MacPaletteContext, menu: ChromeMenuModel?) -> Bool {
            rows(context: context, menu: menu, query: "").contains { $0.action == action && $0.enabled }
        }

        private static func appRows(context: MacPaletteContext, menu: ChromeMenuModel?) -> [MacPaletteRow] {
            let labels = menu?.console?.labels ?? [:]
            func row(
                _ id: String, _ title: String, _ shortcut: String?, _ enabled: Bool, _ action: MacPaletteAction
            ) -> MacPaletteRow {
                MacPaletteRow(
                    id: "app/\(id)", section: actionsSection, title: title, shortcut: shortcut, enabled: enabled,
                    action: action)
            }
            let bypass =
                context.computerAvailable
                ? [
                    row(
                        "bypass", context.bypass ? "Bypass Approvals Off" : "Bypass Approvals On", nil,
                        context.computerEnabled, .toggleBypass)
                ] : []
            return [
                row("new-chat", labels["new_chat"] ?? "New Chat", "⌘N", context.canNavigate, .newChat),
                row(
                    "sidebar", context.sidebarVisible ? "Hide Chats" : "Show Chats", "⇧⌘S", context.canNavigate,
                    .toggleSidebar),
                row(
                    "activity", context.activityVisible ? "Hide Activity" : "Show Activity", "⌘3", true,
                    .toggleActivity),
                row(
                    "browser", context.browserVisible ? "Hide Browser Pane" : "Show Browser Pane", nil,
                    context.browserEnabled && context.canNavigate, .toggleBrowser),
                row("computer", "Computer Controls…", "⇧⌘C", context.computerAvailable, .computerControls),
            ] + bypass + [
                row(
                    "agents", "\(labels["agent_directory"] ?? "Agent Directory")…", nil, context.canNavigate,
                    .agentDirectory),
                row("updates", "Updates…", nil, context.updatesEnabled, .updates),
                row("settings", "Settings…", "⌘,", true, .settings),
                row("cancel-turn", "Cancel Turn", "⌘.", context.canCancelTurn, .cancelTurn),
                row("sign-out", menu?.signout.label ?? "Sign out", nil, context.signedIn, .signOut),
            ]
        }

        private static func chatRows(context: MacPaletteContext) -> [MacPaletteRow] {
            let enabled = context.chat != nil && context.canNavigate && context.connected && context.signedIn
            let pinned = context.chat?.pinned == true
            let archived = context.chat?.archived == true
            return [
                MacPaletteRow(
                    id: "chat/rename", section: chatSection, title: "Rename Chat…", enabled: enabled,
                    action: .renameChat),
                MacPaletteRow(
                    id: "chat/pin", section: chatSection, title: pinned ? "Unpin Chat" : "Pin Chat", enabled: enabled,
                    action: .togglePin),
                MacPaletteRow(
                    id: "chat/archive", section: chatSection, title: archived ? "Unarchive Chat" : "Archive Chat",
                    enabled: enabled, action: .toggleArchive),
            ]
        }

        private static func composerRows(context: MacPaletteContext, menu: ChromeMenuModel?) -> [MacPaletteRow] {
            (menu?.console?.composerActions ?? []).map { control in
                let handoff = control.availability?.mode == .handoff
                return MacPaletteRow(
                    id: "composer/\(control.key)", section: composerSection, title: control.label,
                    token: "/\(control.key)",
                    detail: handoff
                        ? control.availability?.message
                        : control.kind == .toggle ? (context.runInBackground ? "On" : "Off") : nil,
                    enabled: !handoff && context.canNavigate && !context.composerLocked,
                    action: .composer(control.key))
            }
        }

        private static func menuRows(context: MacPaletteContext, menu: ChromeMenuModel?) -> [MacPaletteRow] {
            (menu?.menu ?? []).flatMap { group in
                group.items.map { item in
                    let handoff = item.availability?.mode == .handoff
                    return MacPaletteRow(
                        id: "\(group.key)/\(item.key)", section: group.label, title: item.label,
                        detail: handoff ? item.availability?.message : nil,
                        enabled: !handoff && context.canNavigate, action: .menu(group: group.key, item: item))
                }
            }
        }

        private static func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    struct MacWorkbenchCommandPalette: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        let context: MacPaletteContext
        @Binding var query: String
        let choose: (MacPaletteAction) -> Void
        @State private var selection: String?
        @FocusState private var focused: Bool
        private var p: AstralPalette { theme.palette }
        private var rows: [MacPaletteRow] {
            MacCommandPaletteModel.rows(context: context, menu: model.chromeMenu, query: query)
        }
        private var loading: Bool { model.chromeMenu == nil }

        var body: some View {
            let rows = rows
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    MacSearchField(
                        prompt: "Search commands", text: $query, focused: $focused,
                        identifier: "workbench-command-search"
                    )
                    .onSubmit { run(selection) }
                    .onKeyPress(.downArrow) { move(1, in: rows) }
                    .onKeyPress(.upArrow) { move(-1, in: rows) }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(SettingsButtonStyle(palette: p))
                        .accessibilityIdentifier("workbench-command-close")
                }
                .padding(.horizontal, 20).frame(minHeight: SettingsControlMetrics.headerHeight)
                Divider().overlay(p.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            list(rows)
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(p.text).background(p.surface)
            .frame(minWidth: 420, idealWidth: 560, maxWidth: 680, minHeight: 280, idealHeight: 460, maxHeight: 560)
            .onExitCommand { dismiss() }
            .onAppear {
                let initial = query
                query = ""
                selection = MacCommandPaletteModel.firstEnabled(in: rows)
                // Focus selects the field's text, so a "/" carried from the composer returns after focus lands
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.async { query = initial }
                }
            }
            .onChange(of: query) { _, _ in
                let current = self.rows
                selection = MacCommandPaletteModel.firstEnabled(in: current)
                let count = current.count
                AccessibilityNotification.Announcement(
                    count == 0 ? "No matching commands" : count == 1 ? "1 command" : "\(count) commands"
                ).post()
            }
        }

        @ViewBuilder
        private func list(_ rows: [MacPaletteRow]) -> some View {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading commands").foregroundStyle(p.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workbench-command-loading")
            }
            if rows.isEmpty && !loading {
                Text("No matching commands").foregroundStyle(p.muted)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .accessibilityIdentifier("workbench-command-empty")
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 || rows[index - 1].section != row.section {
                    Text(row.section).font(ConsoleTypography.caption.weight(.semibold)).foregroundStyle(p.muted)
                        .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 12).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                rowView(row)
            }
        }

        private func rowView(_ row: MacPaletteRow) -> some View {
            let selected = row.id == selection
            return Button {
                run(row.id)
            } label: {
                HStack(spacing: 10) {
                    if let token = row.token {
                        Text(token).font(ConsoleTypography.mono(13)).foregroundStyle(p.muted)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(row.enabled ? p.text : p.muted)
                        if let detail = row.detail, !row.enabled {
                            Text(detail).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail = row.detail, row.enabled {
                        Text(detail).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                    if let shortcut = row.shortcut {
                        Text(shortcut).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    selected ? p.primary.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: AstralRadius.sm)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.enabled)
            .id(row.id)
            .help(row.shortcut.map { "\(row.title) (\($0))" } ?? row.detail ?? row.title)
            .accessibilityLabel(row.token.map { "\($0), \(row.title)" } ?? row.title)
            .accessibilityValue(row.detail ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("workbench-command-\(row.id)")
        }

        private func move(_ delta: Int, in rows: [MacPaletteRow]) -> KeyPress.Result {
            selection = MacCommandPaletteModel.move(selection, by: delta, in: rows)
            return .handled
        }

        private func run(_ id: String?) {
            guard let id, let row = rows.first(where: { $0.id == id }), row.enabled else { return }
            choose(row.action)
            dismiss()
        }
    }

    struct MacRenameChatSheet: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        let chat: MacPaletteChat
        @State private var title: String
        @FocusState private var focused: Bool

        init(chat: MacPaletteChat) {
            self.chat = chat
            _title = State(initialValue: chat.title)
        }

        private var renamed: String? { MacCommandPaletteModel.renamedTitle(title, from: chat.title) }
        private var tooLong: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).count > MacCommandPaletteModel.maximumTitleLength
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Chat").font(ConsoleTypography.headline).accessibilityAddTraits(.isHeader)
                TextField("Chat name", text: $title).textFieldStyle(.plain).focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 10).frame(minHeight: 32)
                    .background(theme.palette.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .overlay(RoundedRectangle(cornerRadius: AstralRadius.sm).stroke(theme.palette.fieldBorder))
                    .accessibilityIdentifier("workbench-rename-title")
                if tooLong {
                    Text("Use \(MacCommandPaletteModel.maximumTitleLength) characters or fewer")
                        .font(ConsoleTypography.caption).foregroundStyle(theme.palette.error)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(SettingsButtonStyle(palette: theme.palette))
                    Button("Rename", action: save).keyboardShortcut(.defaultAction)
                        .buttonStyle(SettingsButtonStyle(palette: theme.palette, prominent: true))
                        .disabled(renamed == nil || !model.connected)
                        .accessibilityIdentifier("workbench-rename-save")
                }
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(theme.palette.text)
            .padding(20).frame(width: 380).background(theme.palette.surface)
            .onExitCommand { dismiss() }
            .onAppear { DispatchQueue.main.async { focused = true } }
        }

        private func save() {
            guard let renamed, model.connected, !model.mandatorySurface else { return }
            model.emit("chat_rename", payload: ["chat_id": .string(chat.id), "title": .string(renamed)])
            dismiss()
        }
    }
#endif
