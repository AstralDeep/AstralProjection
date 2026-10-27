// Presents the native Mac chat workbench using server chrome, shared components, and existing action fences.
// A single canvas renderer retains generated work while the conversation, browser pane and activity panel adapt
// around it; Esc and Command-period cancel the current turn through AppModel.

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
        let cancelTurn: () -> Void
        let agents: () -> Void
        let agentDirectoryTitle: String
        let hasCanvas: Bool
        let canNavigate: Bool
        let canCancelTurn: Bool
    }

    private struct MacUpdateCoordinatorKey: EnvironmentKey {
        static var defaultValue: UpdateCoordinator? { nil }
    }

    extension EnvironmentValues {
        var astralUpdateCoordinator: UpdateCoordinator? {
            get { self[MacUpdateCoordinatorKey.self] }
            set { self[MacUpdateCoordinatorKey.self] = newValue }
        }
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
                Divider()
                Button("Cancel turn") { actions?.cancelTurn() }
                    .keyboardShortcut(".", modifiers: .command).disabled(actions?.canCancelTurn != true)
                Divider()
                Button("\(actions?.agentDirectoryTitle ?? "Agent Directory")…") { actions?.agents() }
                    .disabled(actions?.canNavigate != true)
            }
        }
    }

    struct MacWorkbenchView: View {
        static let activityPanelWidth = 320.0
        static let activityDockMinimumWidth = 720.0
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.astralUpdateCoordinator) private var updates
        @Environment(\.openSettings) private var openSettings
        let console: ConsoleModel
        let presentation: ConsolePresentation
        let workbench: ConsoleWorkbenchPresentation
        @State private var sidebarVisible = true
        @State private var selectedPane = MacWorkbenchPane.conversation
        @State private var commandsPresented = false
        @State private var activityPresented = false
        @State private var agentsPresented = false
        @State private var paletteQuery = ""
        @State private var paletteChoice: MacPaletteAction?
        @State private var paletteFromComposer = false
        @State private var restoringDraft = false
        @State private var networkMonitor: NWPathMonitor?

        init(
            console: ConsoleModel, presentation: ConsolePresentation, workbench: ConsoleWorkbenchPresentation,
            activityPresented: Bool = false, agentsPresented: Bool = false
        ) {
            self.console = console
            self.presentation = presentation
            self.workbench = workbench
            _activityPresented = State(initialValue: activityPresented)
            _agentsPresented = State(initialValue: agentsPresented)
        }

        private var p: AstralPalette { theme.palette }
        private var hasCanvas: Bool { !model.workspaceCanvas.isEmpty || model.showSkeleton || browserPresented }
        private var browserPresented: Bool { model.macBrowser.isPresented }
        private var title: String {
            model.history.first { $0.id == model.activeChatId }?.displayTitle
                ?? model.visibleTurns.first { $0.role == "user" }?.text
                ?? model.consoleLabel("new_chat")
        }

        var body: some View {
            GeometryReader { geometry in
                let showsSidebar = sidebarVisible && presentation.navigationMode == .sidebar && !model.consoleFullscreen
                let sidebarWidth = showsSidebar ? min(presentation.sidebarWidth, geometry.size.width) : 0
                let available = max(0, geometry.size.width - sidebarWidth)
                let activityDocked = activityPresented && available >= Self.activityDockMinimumWidth
                let activityWidth = min(Self.activityPanelWidth, max(0, available - 32))
                let contentWidth = activityDocked ? available - activityWidth : available
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
                                MacWorkbenchCanvasSlot(browserPresented: browserPresented)
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
                        if activityDocked {
                            MacWorkbenchActivityPanel { activityPresented = false }
                                .frame(width: activityWidth)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if activityPresented && !activityDocked {
                            MacWorkbenchActivityPanel { activityPresented = false }
                                .frame(width: activityWidth)
                                .shadow(color: p.bg.opacity(0.5), radius: 24, x: -12)
                        }
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
            .background(
                MacWorkbenchEscapeMonitor(
                    blocked: commandsPresented || agentsPresented || model.screen == .surface,
                    cancel: { model.cancelCurrentTurn() })
            )
            .foregroundStyle(p.text)
            .focusedSceneValue(
                \.astralWorkbench,
                MacWorkbenchActions(
                    newChat: { model.newChat() }, commands: { presentPalette(query: "") },
                    sidebar: toggleSidebar, activity: { activityPresented.toggle() },
                    conversation: {
                        model.consoleFullscreen = false
                        selectedPane = .conversation
                    },
                    canvas: { selectedPane = .canvas },
                    cancelTurn: { model.cancelCurrentTurn() },
                    agents: { agentsPresented = true },
                    agentDirectoryTitle: model.consoleLabel("agent_directory"),
                    hasCanvas: hasCanvas, canNavigate: !model.mandatorySurface, canCancelTurn: model.canCancelTurn)
            )
            .sheet(isPresented: $commandsPresented, onDismiss: finishPalette) {
                MacWorkbenchCommandPalette(context: paletteContext, query: $paletteQuery) { paletteChoice = $0 }
            }
            .onChange(of: model.composerDraft) { old, new in
                if restoringDraft {
                    restoringDraft = false
                } else if old.isEmpty, new == "/", !commandsPresented, !model.mandatorySurface {
                    model.composerDraft = ""
                    paletteFromComposer = true
                    presentPalette(query: "/")
                }
            }
            .onChange(of: model.activeChatId) { _, _ in selectedPane = .conversation }
            .onChange(of: browserPresented) { _, presented in
                if presented { selectedPane = .canvas }
            }
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
                .accessibilityIdentifier("workbench-actions-menu")
                .popover(isPresented: $agentsPresented, arrowEdge: .bottom) { MacWorkbenchAgents(console: console) }
                if let updates { UpdateStatusChip(coordinator: updates) }
                iconButton("waveform.path", label: "Activity") { activityPresented.toggle() }
                    .accessibilityValue(activityPresented ? "Shown" : "Hidden")
                    .accessibilityIdentifier("workbench-activity-toggle")
                if model.macBrowser.isEnabled {
                    iconButton("globe", label: "Browser pane") { model.macBrowser.isPresented.toggle() }
                        .accessibilityValue(browserPresented ? "Shown" : "Hidden")
                        .accessibilityIdentifier("workbench-browser-toggle")
                }
                if model.macComputerHost.available {
                    iconButton("desktopcomputer", label: "Computer controls") { model.macComputerHost.showControls() }
                    if model.macComputerHost.taskActive {
                        Button("Stop") { model.stopComputerTask() }
                            .font(ConsoleTypography.caption.weight(.semibold)).foregroundStyle(p.error)
                            .buttonStyle(.bordered).help("Stop this Mac computer session")
                            .accessibilityIdentifier("workbench-stop")
                    }
                }
                iconButton("magnifyingglass", label: "Search commands (⌘K)") { presentPalette(query: "") }
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

        private var paletteContext: MacPaletteContext {
            MacPaletteContext(
                canNavigate: !model.mandatorySurface,
                sidebarVisible: presentation.navigationMode == .sidebar ? sidebarVisible : model.consoleDrawerOpen,
                activityVisible: activityPresented, browserEnabled: model.macBrowser.isEnabled,
                browserVisible: browserPresented, computerAvailable: model.macComputerHost.available,
                updatesEnabled: updates?.isEnabled == true, canCancelTurn: model.canCancelTurn,
                signedIn: model.signedIn, composerLocked: model.mutationsLocked,
                runInBackground: model.runInBackground)
        }

        private func presentPalette(query: String) {
            guard !model.mandatorySurface else { return }
            paletteQuery = query
            paletteChoice = nil
            commandsPresented = true
        }

        private func finishPalette() {
            let choice = paletteChoice
            let fromComposer = paletteFromComposer
            paletteChoice = nil
            paletteFromComposer = false
            guard let choice else {
                if fromComposer, paletteQuery.hasPrefix("/"), model.composerDraft.isEmpty {
                    restoringDraft = true
                    model.composerDraft = paletteQuery
                }
                return
            }
            guard MacCommandPaletteModel.runnable(choice, context: paletteContext, menu: model.chromeMenu) else {
                return
            }
            switch choice {
            case .newChat: model.newChat()
            case .toggleSidebar: toggleSidebar()
            case .toggleActivity: activityPresented.toggle()
            case .toggleBrowser: model.macBrowser.isPresented.toggle()
            case .computerControls: model.macComputerHost.showControls()
            case .agentDirectory: agentsPresented = true
            case .updates: updates?.settingsPresented = true
            case .settings: openSettings()
            case .cancelTurn: _ = model.cancelCurrentTurn()
            case .signOut: Task { await model.signOut() }
            case .composer(let key):
                guard let control = model.console?.composerActions.first(where: { $0.key == key }) else { return }
                if control.kind == .toggle {
                    model.runInBackground.toggle()
                } else if let action = control.action {
                    model.openSurface(action.surface, params: action.params)
                }
            case .menu(_, let item): model.openMenuItem(item)
            }
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
        @FocusState private var searchFocused: Bool
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
                        RoundedRectangle(cornerRadius: 7)
                    )
                    .accessibilityLabel("AstralDeep")
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
                MacSearchField(
                    prompt: "Search chats", text: $query, focused: $searchFocused, identifier: "workbench-chat-search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.historyLoading { ProgressView().controlSize(.small).padding(8) }
                        if chats.isEmpty && !model.historyLoading && !query.isEmpty {
                            Text("No matching chats").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                .padding(8)
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
                        .accessibilityLabel(model.consoleResultAccessibilityLabel)
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

    struct MacWorkbenchActivityPanel: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let close: () -> Void
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Activity").font(ConsoleTypography.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark").frame(width: 32, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(p.muted).help("Hide activity")
                    .accessibilityLabel("Hide activity").accessibilityIdentifier("workbench-activity-close")
                }
                .padding(.horizontal, 16).frame(height: 56)
                .overlay(alignment: .bottom) { p.border.frame(height: 1) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let status = model.statusText {
                                StatusLine(text: status, showsActivity: model.statusShowsActivity)
                            }
                            ForEach(model.activity) { row in
                                MacActivityRowView(row: row, compact: false)
                                    .accessibilityIdentifier("activity-row-\(row.id)")
                                    .id(row.id)
                            }
                            if model.macComputerHost.available {
                                Divider().overlay(p.border)
                                Label(model.macComputerHost.statusLabel, systemImage: "desktopcomputer")
                                    .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { if let last = model.activity.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: model.activity.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(p.text)
            .frame(maxHeight: .infinity)
            .background(p.surface)
            .overlay(alignment: .leading) { p.border.frame(width: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity")
            .accessibilityIdentifier("workbench-activity-panel")
        }
    }

    private struct MacWorkbenchCanvasSlot: View {
        @Environment(AppModel.self) private var model
        let browserPresented: Bool

        var body: some View {
            ZStack {
                MacWorkbenchCanvas()
                    .opacity(browserPresented ? 0 : 1)
                    .allowsHitTesting(!browserPresented).accessibilityHidden(browserPresented)
                if browserPresented {
                    MacWorkbenchBrowserSlot(driver: model.macBrowser)
                }
            }
        }
    }

    private struct MacWorkbenchBrowserSlot: View {
        @Environment(ThemeStore.self) private var theme
        @Bindable var driver: MacBrowserDriver

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(driver.pane.title).font(ConsoleTypography.caption.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        driver.isPresented = false
                    } label: {
                        Image(systemName: "xmark").frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.palette.muted).help("Hide browser pane")
                    .accessibilityLabel("Hide browser pane").accessibilityIdentifier("workbench-browser-close")
                }
                .padding(.horizontal, 14).frame(height: 56)
                .overlay(alignment: .bottom) { theme.palette.border.frame(height: 1) }
                MacBrowserPaneView(driver: driver)
            }
            .background(theme.palette.surface)
            .overlay(alignment: .leading) { theme.palette.border.frame(width: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workbench-browser-slot")
        }
    }

    struct MacWorkbenchEscapeMonitor: NSViewRepresentable {
        let blocked: Bool
        let cancel: () -> Bool

        static func cancels(
            keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editingText: Bool, sheetPresented: Bool, blocked: Bool
        ) -> Bool {
            keyCode == 53
                && modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
                    .isEmpty
                && !editingText && !sheetPresented && !blocked
        }

        static func editingText(_ responder: NSResponder?) -> Bool {
            guard let text = responder as? NSTextView, text.isEditable else { return false }
            return text.hasMarkedText() || !text.string.isEmpty
        }

        static func consume(_ event: NSEvent, in window: NSWindow?, blocked: Bool, cancel: () -> Bool) -> NSEvent? {
            guard let window, event.window === window,
                cancels(
                    keyCode: event.keyCode, modifiers: event.modifierFlags,
                    editingText: editingText(window.firstResponder),
                    sheetPresented: window.attachedSheet != nil || NSApp.modalWindow != nil, blocked: blocked),
                cancel()
            else { return event }
            return nil
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.view = view
            context.coordinator.update(blocked: blocked, cancel: cancel)
            context.coordinator.start()
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            context.coordinator.update(blocked: blocked, cancel: cancel)
        }

        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

        @MainActor
        final class Coordinator {
            weak var view: NSView?
            private var blocked = false
            private var cancel: () -> Bool = { false }
            private var monitor: Any?

            func update(blocked: Bool, cancel: @escaping () -> Bool) {
                self.blocked = blocked
                self.cancel = cancel
            }

            func start() {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    MainActor.assumeIsolated { self?.consume(event) ?? event }
                }
            }

            func stop() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            func consume(_ event: NSEvent) -> NSEvent? {
                MacWorkbenchEscapeMonitor.consume(event, in: view?.window, blocked: blocked, cancel: cancel)
            }
        }
    }

    struct MacWorkbenchAgents: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        let console: ConsoleModel
        @State private var query = ""
        @FocusState private var searchFocused: Bool
        private var p: AstralPalette { theme.palette }
        private var agents: [ConsoleAgent] {
            console.catalog.agents.filter {
                query.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(query)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.consoleLabel("agent_directory")).font(ConsoleTypography.headline)
                    .accessibilityAddTraits(.isHeader)
                MacSearchField(
                    prompt: model.consoleLabel("search_agents"), text: $query, focused: $searchFocused,
                    identifier: "workbench-agent-search"
                )
                .onSubmit { if let first = agents.first { open(first) } }
                if agents.isEmpty {
                    Text(console.catalog.agents.isEmpty ? "No agents available" : "No matching agents")
                        .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        .accessibilityIdentifier("workbench-agent-empty")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                                if index > 0 { Divider().overlay(p.border) }
                                row(agent)
                            }
                        }
                    }
                    .frame(maxHeight: 440).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(p.text).padding(20)
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 440, minHeight: 160, maxHeight: 560, alignment: .top)
            .background(p.surface)
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
        }

        private func row(_ agent: ConsoleAgent) -> some View {
            let ready = agent.state == .ready
            return Button {
                open(agent)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ready ? "circle.fill" : "circle.slash")
                        .font(.system(size: ready ? 8 : 12, weight: .semibold))
                        .foregroundStyle(ready ? p.success : p.muted)
                        .frame(width: 14).accessibilityHidden(true)
                    Text(agent.name).font(ConsoleTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !ready {
                        Text("Offline").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                }
                .padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(agent.description)
            .accessibilityLabel(agent.name)
            .accessibilityValue(ready ? "Available" : "Offline")
            .accessibilityHint(agent.description)
            .accessibilityIdentifier("workbench-agent-\(agent.id)")
        }

        private func open(_ agent: ConsoleAgent) {
            guard !model.mandatorySurface else { return }
            model.openSurface("agent_intro", params: .object(["agent_id": .string(agent.id)]))
            dismiss()
        }
    }
#endif
