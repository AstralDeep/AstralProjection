// Presents the native Mac chat workbench using server chrome, shared components, and existing action fences.
// A single canvas renderer retains generated work while the conversation and navigation adapt around it.

#if os(macOS)
    import AppKit
    import AstralCore
    import Network
    import SwiftUI

    struct MacWorkbenchActions {
        let newChat: () -> Void
        let commands: () -> Void
        let sidebar: () -> Void
        let activity: () -> Void
        let conversation: () -> Void
        let canvas: () -> Void
        let hasCanvas: Bool
        let canNavigate: Bool
    }

    private struct MacWorkbenchActionsKey: FocusedValueKey {
        typealias Value = MacWorkbenchActions
    }

    private struct MacComputerControlsKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    extension FocusedValues {
        var astralComputerControls: (() -> Void)? {
            get { self[MacComputerControlsKey.self] }
            set { self[MacComputerControlsKey.self] = newValue }
        }

        var astralWorkbench: MacWorkbenchActions? {
            get { self[MacWorkbenchActionsKey.self] }
            set { self[MacWorkbenchActionsKey.self] = newValue }
        }
    }

    struct MacWorkbenchCommands: Commands {
        @FocusedValue(\.astralWorkbench) private var actions
        @FocusedValue(\.astralComputerControls) private var computerControls

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("New chat") { actions?.newChat() }
                    .keyboardShortcut("n").disabled(actions?.canNavigate != true)
            }
            CommandGroup(after: .appSettings) {
                if let computerControls {
                    Button("Computer controls…", action: computerControls)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
            CommandMenu("Workspace") {
                Button("Search commands…") { actions?.commands() }
                    .keyboardShortcut("k").disabled(actions?.canNavigate != true)
                Divider()
                Button("Show chats") { actions?.sidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(actions?.canNavigate != true)
                Button("Conversation") { actions?.conversation() }
                    .keyboardShortcut("1").disabled(actions?.canNavigate != true)
                Button("Canvas") { actions?.canvas() }
                    .keyboardShortcut("2").disabled(actions?.hasCanvas != true || actions?.canNavigate != true)
                Button("Activity") { actions?.activity() }
                    .keyboardShortcut("3").disabled(actions == nil)
            }
        }
    }

    struct MacWorkbenchView: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let console: ConsoleModel
        let presentation: ConsolePresentation
        let workbench: ConsoleWorkbenchPresentation
        @State private var sidebarVisible = true
        @State private var selectedPane = MacWorkbenchPane.conversation
        @State private var commandsPresented = false
        @State private var activityPresented = false
        @State private var agentsPresented = false
        @State private var networkMonitor: NWPathMonitor?
        private var p: AstralPalette { theme.palette }
        private var hasCanvas: Bool { !model.workspaceCanvas.isEmpty || model.showSkeleton }
        private var title: String {
            model.history.first { $0.id == model.activeChatId }?.displayTitle
                ?? model.visibleTurns.first { $0.role == "user" }?.text
                ?? model.consoleLabel("new_chat")
        }

        var body: some View {
            GeometryReader { geometry in
                let showsSidebar = sidebarVisible && presentation.navigationMode == .sidebar && !model.consoleFullscreen
                let sidebarWidth = showsSidebar ? min(presentation.sidebarWidth, geometry.size.width) : 0
                let contentWidth = max(0, geometry.size.width - sidebarWidth)
                let pane = showsSidebar ? workbench.withSidebar : workbench.withoutSidebar
                let layout = MacWorkbenchLayout.resolve(
                    width: contentWidth, pane: pane, hasCanvas: hasCanvas, selectedPane: selectedPane,
                    expandedCanvas: model.consoleFullscreen)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        MacWorkbenchSidebar(console: console)
                            .frame(width: sidebarWidth)
                            .clipped().opacity(showsSidebar ? 1 : 0)
                            .allowsHitTesting(showsSidebar).accessibilityHidden(!showsSidebar)
                        VStack(spacing: 0) {
                            toolbar(compact: pane.compactToolbar, layout: layout)
                            if let label = model.connectionStripLabel { ConnectionStrip(label: label) }
                            if let banner = model.errorBanner {
                                BannerBar(text: banner, isError: model.bannerIsError, isWarning: model.bannerIsWarning)
                                {
                                    model.dismissBanner()
                                }
                            }
                            ViewportRefreshNotice()
                            HStack(spacing: 0) {
                                conversation
                                    .frame(width: layout.conversationVisible ? layout.conversationWidth : contentWidth)
                                    .frame(width: layout.conversationWidth)
                                    .clipped().opacity(layout.conversationVisible ? 1 : 0)
                                    .allowsHitTesting(layout.conversationVisible)
                                    .accessibilityHidden(!layout.conversationVisible)
                                MacWorkbenchCanvas()
                                    .frame(width: layout.canvasVisible ? layout.canvasWidth : contentWidth)
                                    .frame(width: layout.canvasWidth)
                                    .clipped().opacity(layout.canvasVisible ? 1 : 0)
                                    .allowsHitTesting(layout.canvasVisible).accessibilityHidden(!layout.canvasVisible)
                            }
                            .frame(maxHeight: .infinity)
                            InputBar(
                                input: Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 }),
                                workbenchStyle: true
                            )
                            .frame(maxWidth: workbench.composerMaxWidth)
                            .frame(maxWidth: .infinity)
                        }
                        .frame(width: contentWidth)
                    }
                    .blur(radius: model.screen == .surface ? 5 : 0)
                    .allowsHitTesting(model.screen != .surface)
                    .accessibilityHidden(model.screen == .surface)
                    if presentation.navigationMode != .sidebar && model.consoleDrawerOpen && !model.mandatorySurface {
                        p.bg.opacity(0.7).ignoresSafeArea().onTapGesture { model.consoleDrawerOpen = false }
                        MacWorkbenchSidebar(console: console)
                            .frame(width: min(presentation.sidebarWidth, max(0, geometry.size.width - 32)))
                            .shadow(color: p.bg.opacity(0.5), radius: 24, x: 12)
                    }
                    if model.screen == .surface {
                        ConsoleSurfaceOverlay(console: console, presentation: presentation, size: geometry.size)
                    }
                }
            }
            .background(p.bg)
            .foregroundStyle(p.text)
            .focusedSceneValue(
                \.astralWorkbench,
                MacWorkbenchActions(
                    newChat: { model.newChat() }, commands: { commandsPresented = true },
                    sidebar: toggleSidebar, activity: { activityPresented = true },
                    conversation: {
                        model.consoleFullscreen = false
                        selectedPane = .conversation
                    },
                    canvas: { selectedPane = .canvas },
                    hasCanvas: hasCanvas, canNavigate: !model.mandatorySurface)
            )
            .sheet(isPresented: $commandsPresented) { MacWorkbenchCommandPalette() }
            .sheet(isPresented: $activityPresented) { MacWorkbenchActivity() }
            .popover(isPresented: $agentsPresented, arrowEdge: .top) { MacWorkbenchAgents(console: console) }
            .onChange(of: model.activeChatId) { _, _ in selectedPane = .conversation }
            .onChange(of: model.mandatorySurface) { _, mandatory in
                if mandatory {
                    commandsPresented = false
                    activityPresented = false
                    agentsPresented = false
                    model.consoleDrawerOpen = false
                }
            }
            .onAppear(perform: start)
            .onDisappear {
                networkMonitor?.cancel()
                networkMonitor = nil
            }
        }

        private var conversation: some View {
            ZStack {
                MacWorkbenchTranscript(
                    maximumWidth: workbench.transcriptMaxWidth, contentPadding: presentation.contentPadding.edgeInsets
                )
                .opacity(model.workspaceStarted && !model.consoleDashboardVisible ? 1 : 0)
                .allowsHitTesting(model.workspaceStarted && !model.consoleDashboardVisible)
                .accessibilityHidden(!model.workspaceStarted || model.consoleDashboardVisible)
                if !model.workspaceStarted || model.consoleDashboardVisible {
                    MacWorkbenchWelcome(console: console, columns: presentation.scenarioColumns)
                }
            }
        }

        private func toolbar(compact: Bool, layout: MacWorkbenchLayout) -> some View {
            HStack(spacing: compact ? 2 : 8) {
                iconButton("sidebar.left", label: "Show chats", action: toggleSidebar)
                    .disabled(model.mandatorySurface)
                Text(title).font(ConsoleTypography.subheadline.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(title)
                if hasCanvas && !(layout.conversationVisible && layout.canvasVisible) {
                    Menu {
                        Button("Conversation") {
                            model.consoleFullscreen = false
                            selectedPane = .conversation
                        }
                        Button("Canvas") { selectedPane = .canvas }
                    } label: {
                        Image(systemName: layout.canvasVisible ? "rectangle.inset.filled" : "text.bubble")
                            .frame(width: 36, height: 40)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .help("Switch conversation and canvas").accessibilityLabel("Switch conversation and canvas")
                }
                Menu {
                    if compact {
                        Button(model.consoleLabel("new_chat")) { model.newChat() }
                        Divider()
                    }
                    ForEach(model.chromeMenu?.topbarActions.filter { $0.action != nil } ?? []) { control in
                        if let action = control.action {
                            Button(control.label ?? control.key) {
                                model.openSurface(action.surface, params: action.params)
                            }
                        }
                    }
                    if model.chromeMenu?.topbarActions.contains(where: { $0.action != nil }) == true { Divider() }
                    Button(model.consoleLabel("agent_directory")) { agentsPresented = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 40)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .disabled(model.mandatorySurface).help("Workspace actions").accessibilityLabel("Workspace actions")
                iconButton("waveform.path", label: "Activity") { activityPresented = true }
                if model.macComputerHost.available {
                    iconButton("desktopcomputer", label: "Computer controls") { model.macComputerHost.showControls() }
                    if model.macComputerHost.enabled {
                        Button("Stop") { model.macComputerHost.stop() }
                            .font(ConsoleTypography.caption.weight(.semibold)).foregroundStyle(p.error)
                            .buttonStyle(.bordered).help("Stop this Mac computer session")
                    }
                }
                iconButton("magnifyingglass", label: "Search commands (⌘K)") { commandsPresented = true }
                    .disabled(model.mandatorySurface)
            }
            .padding(.horizontal, 12).frame(height: 56)
            .overlay(alignment: .bottom) { p.border.frame(height: 1) }
        }

        private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon).frame(width: 36, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(p.muted).help(label).accessibilityLabel(label)
        }

        private func toggleSidebar() {
            if presentation.navigationMode == .sidebar {
                sidebarVisible.toggle()
            } else {
                model.consoleDrawerOpen.toggle()
            }
        }

        private func start() {
            model.sendEvent("get_history")
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { path in
                let kind =
                    path.status != .satisfied
                    ? "none"
                    : path.usesInterfaceType(.wifi)
                        ? "wifi"
                        : path.usesInterfaceType(.cellular)
                            ? "cellular"
                            : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "unknown"
                Task { @MainActor in model.networkCapabilitiesChanged(kind) }
            }
            monitor.start(queue: DispatchQueue(label: "astral.workbench.network"))
        }
    }

    private struct MacWorkbenchSidebar: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let console: ConsoleModel
        @State private var query = ""
        private var p: AstralPalette { theme.palette }
        private var chats: [ChatSummary] {
            model.history.filter {
                query.isEmpty || ($0.displayTitle + " " + $0.displayPreview).localizedCaseInsensitiveContains(query)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image("AstralIcon").resizable().frame(width: 26, height: 26).clipShape(
                        RoundedRectangle(cornerRadius: 7))
                    Text("AstralDeep").font(ConsoleTypography.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if model.consoleDrawerOpen {
                        Button {
                            model.consoleDrawerOpen = false
                        } label: {
                            Image(systemName: "xmark").frame(width: 32, height: 36)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Hide chats")
                    }
                }
                .frame(height: 32)
                Button {
                    model.newChat()
                    model.consoleDrawerOpen = false
                } label: {
                    Label(model.consoleLabel("new_chat"), systemImage: "square.and.pencil")
                        .font(ConsoleTypography.subheadline).frame(
                            maxWidth: .infinity, minHeight: 40, alignment: .leading
                        )
                        .padding(.horizontal, 12)
                        .background(p.primary.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).disabled(model.mandatorySurface)
                .accessibilityIdentifier("new-chat-button")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search chats", text: $query).textFieldStyle(.plain)
                }
                .font(ConsoleTypography.caption).foregroundStyle(p.muted).padding(10)
                .background(p.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Search chats")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.historyLoading { ProgressView().controlSize(.small).padding(8) }
                        if chats.isEmpty && !model.historyLoading {
                            Text(query.isEmpty ? "No chats" : "No matching chats")
                                .font(ConsoleTypography.caption).foregroundStyle(p.muted).padding(8)
                        }
                        ForEach(chats) { chat in
                            Button {
                                model.openChat(chat.id)
                            } label: {
                                HistoryRow(chat: chat, showsDetails: false)
                                    .background(
                                        model.activeChatId == chat.id ? p.primary.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).disabled(model.mandatorySurface)
                            .accessibilityIdentifier("workbench-chat-\(chat.id)")
                            .accessibilityValue(
                                [chat.displayPreview, chat.relativeTime()].filter { !$0.isEmpty }.joined(
                                    separator: ", ")
                            )
                            .contextMenu {
                                Button("Delete conversation", role: .destructive) { model.deleteChat(chat.id) }
                            }
                        }
                    }
                }
                .accessibilityLabel(model.historyTitle)
                .accessibilityIdentifier("workbench-chat-history")
                Spacer(minLength: 0)
                Divider().overlay(p.border)
                Menu {
                    ForEach(model.chromeMenu?.menu ?? []) { group in
                        Section(group.label) {
                            ForEach(group.items) { item in
                                Button(item.label) { model.openMenuItem(item) }
                            }
                        }
                    }
                    Divider()
                    Button(model.chromeMenu?.signout.label ?? "Sign out") { Task { await model.signOut() } }
                } label: {
                    HStack(spacing: 10) {
                        Text(console.identity.initials).font(ConsoleTypography.caption.weight(.semibold))
                            .frame(width: 32, height: 32).background(p.primary.opacity(0.18), in: Circle())
                        Text(console.identity.name).font(ConsoleTypography.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(ConsoleTypography.caption2).foregroundStyle(
                            p.muted)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel(model.chromeMenu?.settingsControl?.label ?? "Settings")
                .accessibilityValue("\(console.identity.name), \(console.identity.role)")
                .accessibilityIdentifier("console-settings-menu")
            }
            .padding(16).frame(maxHeight: .infinity)
            .background(p.surface.opacity(0.6))
            .overlay(alignment: .trailing) { p.border.frame(width: 1) }
        }
    }

    private struct MacWorkbenchWelcome: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let console: ConsoleModel
        let columns: Int
        private var p: AstralPalette { theme.palette }

        var body: some View {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: columns), spacing: 12
                ) {
                    ForEach(console.catalog.scenarios) { scenario in
                        Button {
                            model.useConsoleScenario(scenario, run: false)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(scenario.title).font(ConsoleTypography.subheadline.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.up.left").font(ConsoleTypography.caption)
                                    .foregroundStyle(p.muted).accessibilityHidden(true)
                            }
                            .padding(14).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!model.connected || model.mutationsLocked)
                        .accessibilityLabel("Load prompt: \(scenario.title)")
                        .accessibilityIdentifier("workbench-scenario-\(scenario.id)")
                    }
                }
                .frame(maxWidth: 600, alignment: .leading).padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(p.bg)
        }
    }

    private struct MacWorkbenchCanvas: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @State private var showTimeline = false
        @State private var actionTarget: ComponentActionTarget?
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(model.consoleResultTitle).font(ConsoleTypography.caption.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("\(model.consoleResultTitle), \(model.consoleResultAgent)")
                        .accessibilityIdentifier("workbench-canvas-title")
                    WorkspaceActionButtons()
                    Button {
                        showTimeline = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").frame(width: 36, height: 44)
                    }
                    .disabled(model.canvasHistory.isEmpty).help("Canvas history").accessibilityLabel("Canvas history")
                    Button {
                        model.consoleFullscreen.toggle()
                    } label: {
                        Image(
                            systemName: model.consoleFullscreen
                                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                        )
                        .frame(width: 36, height: 44)
                    }
                    .help(model.consoleFullscreen ? "Restore conversation and canvas" : "Expand canvas")
                    .accessibilityLabel(model.consoleFullscreen ? "Restore conversation and canvas" : "Expand canvas")
                    .accessibilityIdentifier("workbench-expand-canvas")
                }
                .buttonStyle(.plain).foregroundStyle(p.muted).padding(.horizontal, 14).frame(height: 56)
                .overlay(alignment: .bottom) { p.border.frame(height: 1) }
                CanvasArea(
                    showTimeline: $showTimeline, componentActionTarget: $actionTarget, showsTimelineControl: false)
            }
            .background(p.surface.opacity(0.45))
            .overlay(alignment: .leading) { p.border.frame(width: 1) }
            .sheet(isPresented: $showTimeline) {
                CanvasTimelineOverlay(history: model.canvasHistory) { index in
                    model.viewCanvasSnapshot(index)
                    showTimeline = false
                }
            }
            .sheet(item: $actionTarget) { target in ComponentActionSheet(target: target) }
            .onChange(of: actionTarget.map { model.componentActionIsCurrent($0.context) } ?? false) { _, current in
                if !current { actionTarget = nil }
            }
            .onDisappear { actionTarget = nil }
        }
    }

    private struct MacWorkbenchCommandPalette: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        @State private var query = ""
        @FocusState private var focused: Bool
        private var commands: [MacWorkbenchCommand] { MacWorkbenchCommand.search(menu: model.chromeMenu, query: query) }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.muted)
                    TextField("Search commands", text: $query).textFieldStyle(.plain).focused($focused)
                        .onSubmit { if let first = commands.first { open(first) } }
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(20)
                Divider()
                List {
                    if commands.isEmpty {
                        Text("No matching commands.").foregroundStyle(theme.palette.muted)
                    }
                    ForEach(model.chromeMenu?.menu ?? []) { group in
                        let matches = commands.filter { $0.groupKey == group.key }
                        if !matches.isEmpty {
                            Section(group.label) {
                                ForEach(matches) { command in
                                    Button {
                                        open(command)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(command.item.label).foregroundStyle(theme.palette.text)
                                            if let message = command.item.availability?.message {
                                                Text(message).font(ConsoleTypography.caption).foregroundStyle(
                                                    theme.palette.muted)
                                            }
                                        }
                                        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("workbench-command-\(command.id)")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .font(ConsoleTypography.subheadline).background(theme.palette.surface)
            .frame(minWidth: 280, idealWidth: 560, maxWidth: 680, minHeight: 280, idealHeight: 460)
            .onAppear { focused = true }
        }

        private func open(_ command: MacWorkbenchCommand) {
            guard !model.mandatorySurface,
                model.chromeMenu?.menu.first(where: { $0.key == command.groupKey })?.items.contains(command.item)
                    == true
            else { return }
            model.openMenuItem(command.item)
            dismiss()
        }
    }

    private struct MacWorkbenchActivity: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Activity").font(ConsoleTypography.headline)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let status = model.statusText {
                            StatusLine(text: status, showsActivity: model.statusShowsActivity)
                        }
                        ForEach(Array(model.stepTrail.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(theme.palette.muted)
                                Text(step).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if model.statusText == nil && model.stepTrail.isEmpty {
                            Text("No activity").foregroundStyle(theme.palette.muted)
                        }
                        if model.macComputerHost.available {
                            Divider()
                            Label(model.macComputerHost.statusLabel, systemImage: "desktopcomputer")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(theme.palette.text)
            .padding(24).background(theme.palette.surface)
            .frame(minWidth: 280, idealWidth: 480, minHeight: 280, idealHeight: 440)
        }
    }

    private struct MacWorkbenchAgents: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        let console: ConsoleModel
        @State private var query = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.consoleLabel("agent_directory")).font(ConsoleTypography.headline)
                TextField(model.consoleLabel("search_agents"), text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            console.catalog.agents.filter {
                                query.isEmpty
                                    || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(query)
                            }
                        ) { agent in
                            Button {
                                guard !model.mandatorySurface else { return }
                                model.openSurface("agent_intro", params: .object(["agent_id": .string(agent.id)]))
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Circle().fill(agent.state == .ready ? theme.palette.success : theme.palette.muted)
                                        .frame(width: 7, height: 7).padding(.top, 6)
                                        .accessibilityHidden(true)
                                    Text(agent.name).font(ConsoleTypography.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 12).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(agent.name)
                            .accessibilityValue(agent.state == .ready ? "Available" : "Offline")
                            .accessibilityHint(agent.description)
                            .accessibilityIdentifier("workbench-agent-\(agent.id)")
                            Divider()
                        }
                    }
                }
            }
            .foregroundStyle(theme.palette.text).padding(20).background(theme.palette.surface)
            .frame(width: 360, height: 480)
        }
    }
#endif
