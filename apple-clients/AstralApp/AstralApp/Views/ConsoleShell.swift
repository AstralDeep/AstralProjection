// Renders the shared console catalog and ROTE-selected navigation and settings geometry.
// AppModel retains authenticated dispatch, conversation state and server surface ownership.

import AstralCore
import Network
import SwiftUI

extension ConsoleInsets {
    var edgeInsets: EdgeInsets { EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right) }
}

struct ConsoleShell: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let console: ConsoleModel
    let presentation: ConsolePresentation
    @State private var networkMonitor: NWPathMonitor?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    if presentation.navigationMode == .sidebar {
                        ConsoleSidebar(console: console, presentation: presentation)
                            .frame(width: presentation.sidebarWidth)
                    }
                    main
                }
                .overlayPreferenceValue(ConsoleCanvasBoundsKey.self) { anchors in
                    if let anchor = anchors.result {
                        let bounds = model.consoleFullscreen ? geometry.frame(in: .local) : geometry[anchor]
                        let viewport =
                            model.consoleFullscreen
                            ? geometry.frame(in: .local) : anchors.viewport.map { geometry[$0] } ?? .zero
                        ZStack(alignment: .topLeading) {
                            ConsoleResultPane(presentation: presentation)
                                .frame(width: bounds.width, height: bounds.height)
                                .position(x: bounds.midX, y: bounds.midY)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask {
                            Rectangle().frame(width: viewport.width, height: viewport.height)
                                .position(x: viewport.midX, y: viewport.midY)
                        }
                        .contentShape(Path(viewport))
                        .opacity(model.consoleDashboardVisible ? 0 : 1)
                        .allowsHitTesting(!model.consoleDashboardVisible)
                        .accessibilityHidden(model.consoleDashboardVisible)
                    }
                }
                .blur(radius: model.screen == .surface ? 6 : 0)
                .allowsHitTesting(model.screen != .surface)
                .accessibilityHidden(model.screen == .surface)
                if presentation.navigationMode == .drawer, model.consoleDrawerOpen {
                    Color.black.opacity(0.48).ignoresSafeArea()
                        .onTapGesture { model.consoleDrawerOpen = false }
                    HStack(spacing: 0) {
                        ConsoleSidebar(console: console, presentation: presentation)
                            .frame(width: presentation.sidebarWidth)
                        Spacer(minLength: 0)
                    }
                }
                if model.screen == .surface {
                    ConsoleSurfaceOverlay(console: console, presentation: presentation, size: geometry.size)
                }
            }
            .background(p.bg.ignoresSafeArea())
        }
        .onAppear {
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
            monitor.start(queue: DispatchQueue(label: "astral.console.network"))
        }
        .onDisappear {
            networkMonitor?.cancel()
            networkMonitor = nil
        }
        .onChange(of: presentation.navigationMode) { _, mode in
            if mode == .sidebar { model.consoleDrawerOpen = false }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            ConsoleHeader(presentation: presentation)
            if let label = model.connectionStripLabel { ConnectionStrip(label: label) }
            if let banner = model.errorBanner {
                BannerBar(text: banner, isError: model.bannerIsError) { model.dismissBanner() }
            }
            ViewportRefreshNotice()
            ZStack {
                ConsoleConversation(presentation: presentation)
                    .opacity(model.consoleDashboardVisible ? 0 : 1)
                    .allowsHitTesting(!model.consoleDashboardVisible)
                    .accessibilityHidden(model.consoleDashboardVisible)
                if model.consoleDashboardVisible || !model.workspaceStarted {
                    ConsoleLanding(console: console, presentation: presentation)
                        .background(p.bg)
                }
            }
            InputBar(input: Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 }))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [p.primary.opacity(0.07), p.bg], startPoint: .top, endPoint: .center))
    }
}

struct ConsoleHeader: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let presentation: ConsolePresentation
    private var p: AstralPalette { theme.palette }
    private var compact: Bool { presentation.settingsPresentation == .sheet }

    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            if presentation.navigationMode == .drawer {
                Button {
                    model.consoleDrawerOpen.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Show the agent directory")
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }
            Button {
                model.showConsoleDashboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left")
                    Text(
                        model.consoleLabel("dashboard")
                            + (presentation.settingsPresentation == .sheet
                                ? "" : model.consoleLabel("dashboard_suffix")))
                }
                .padding(.horizontal, compact ? 8 : 14).frame(minHeight: max(32, presentation.minimumControlHeight))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            .buttonStyle(.plain)
            Button {
                model.consoleDashboardVisible = false
                model.screen = .chat
            } label: {
                let turns = model.visibleTurns.filter { $0.role == "user" }.count
                Text("(\(turns) \(model.consoleLabel(turns == 1 ? "turn_singular" : "turn_plural")))")
                    .foregroundStyle(p.accent).padding(.horizontal, compact ? 6 : 12).padding(.vertical, 8)
                    .frame(minHeight: presentation.minimumControlHeight)
                    .background(compact ? .clear : p.bg, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).disabled(!model.workspaceStarted)
            .accessibilityLabel("View active conversation")
            Spacer(minLength: 0)
            Button {
                model.newChat()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    if presentation.settingsPresentation != .sheet { Text(model.consoleLabel("new_chat")) }
                }
                .foregroundStyle(p.accent).padding(.horizontal, 14)
                .frame(width: compact ? 44 : nil)
                .frame(minHeight: max(32, presentation.minimumControlHeight))
                .background(p.primary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.primary.opacity(0.4)))
            }
            .buttonStyle(.plain).accessibilityLabel("New chat").accessibilityIdentifier("new-chat-button")
        }
        .lineLimit(1)
        .font(ConsoleTypography.sans(13)).foregroundStyle(p.muted)
        .padding(.horizontal, presentation.navigationMode == .drawer ? 10 : 32).padding(.vertical, compact ? 8 : 10)
        .background(p.surface.opacity(0.9)).overlay(alignment: .bottom) { p.border.frame(height: 1) }
    }
}

struct ConsoleSidebar: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let console: ConsoleModel
    let presentation: ConsolePresentation
    @State private var historyExpanded = true
    @State private var query = ""
    private var p: AstralPalette { theme.palette }
    private var agents: [ConsoleAgent] {
        console.catalog.agents.filter {
            query.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    model.showConsoleDashboard()
                } label: {
                    Image("AstralWordmark").resizable().scaledToFit().frame(width: 150, height: 42)
                }
                .buttonStyle(.plain).accessibilityLabel("Return to the dashboard")
                Spacer()
                if presentation.navigationMode == .drawer {
                    Button {
                        model.consoleDrawerOpen = false
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Hide the agent directory")
                }
            }
            Divider().overlay(p.border)
            HStack {
                Button {
                    historyExpanded.toggle()
                } label: {
                    HStack {
                        sectionLabel("history")
                        Spacer()
                        Image(systemName: historyExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain).accessibilityLabel(console.labels["history"] ?? "")
                .accessibilityValue(historyExpanded ? "Expanded" : "Collapsed")
                Button {
                    model.newChat()
                    model.consoleDrawerOpen = false
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
                .buttonStyle(.plain).accessibilityLabel("New chat")
            }
            if historyExpanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.history) { chat in
                            Button {
                                model.openChat(chat.id)
                            } label: {
                                HistoryRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete conversation", role: .destructive) { model.deleteChat(chat.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: model.history.isEmpty ? 0 : 190)
            }
            HStack {
                sectionLabel("agent_directory")
                Spacer()
                Text("\(console.catalog.agents.count)").font(ConsoleTypography.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.primary.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(p.primary.opacity(0.35)))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField(console.labels["search_agents"] ?? "", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel(console.labels["search_agents"] ?? "")
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(p.muted).padding(10)
            .background(p.text.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.text.opacity(0.14)))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(agents) { agent in
                        Button {
                            model.consoleDrawerOpen = false
                            model.openSurface("agent_intro", params: .object(["agent_id": .string(agent.id)]))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.name).font(ConsoleTypography.subheadline.weight(.semibold))
                                        .foregroundStyle(p.text)
                                    Text(agent.description).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Circle().fill(agent.state == .ready ? p.success : p.muted).frame(width: 8, height: 8)
                                    .accessibilityLabel(agent.state == .ready ? "Available" : "Offline")
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                model.consoleDrawerOpen = false
                if let first = model.chromeMenu?.allItems.first { model.openMenuItem(first) }
            } label: {
                HStack(spacing: 10) {
                    Image("AstralAccountAvatar").resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(console.identity.name).font(ConsoleTypography.subheadline).foregroundStyle(p.text)
                        Text(console.identity.role).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").foregroundStyle(p.muted)
                }
                .padding(10).background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }
            .buttonStyle(.plain).accessibilityLabel(model.chromeMenu?.settingsControl?.label ?? "Settings")
        }
        .padding(.horizontal, 22).padding(.vertical, 16).foregroundStyle(p.muted)
        .background(p.surface.opacity(presentation.navigationMode == .drawer ? 1 : 0.62))
        .overlay(alignment: .trailing) { p.border.frame(width: 1) }
    }

    private func sectionLabel(_ key: String) -> some View {
        Text((console.labels[key] ?? "").uppercased()).tracking(1.2)
            .font(ConsoleTypography.caption.weight(.bold)).foregroundStyle(p.muted)
    }
}

struct ConsoleLanding: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let console: ConsoleModel
    let presentation: ConsolePresentation
    @State private var category: String?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(console.labels["title"] ?? "").font(ConsoleTypography.title2.weight(.heavy)).foregroundStyle(
                        p.text)
                    Text(console.labels["subtitle"] ?? "").font(ConsoleTypography.subheadline).foregroundStyle(p.muted)
                    Divider().overlay(p.border).padding(.top, 8)
                }
                HStack(spacing: 16) {
                    Text(console.labels["start_here"] ?? "").font(ConsoleTypography.sans(18).bold()).fixedSize()
                    Spacer(minLength: 0)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            filter(nil, label: console.labels["all_categories"] ?? "")
                            ForEach(console.catalog.categories, id: \.self) { filter($0, label: $0) }
                        }
                        .padding(5)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420).background(p.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                }
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                        count: presentation.scenarioColumns), spacing: 14
                ) {
                    ForEach(console.catalog.scenarios.filter { category == nil || $0.category == category }) {
                        scenario in
                        scenarioCard(scenario)
                    }
                }
            }
            .padding(presentation.contentPadding.edgeInsets)
        }
        .accessibilityIdentifier("workspace-start")
    }

    private func filter(_ value: String?, label: String) -> some View {
        Button {
            category = value
        } label: {
            Text(label).font(ConsoleTypography.caption).foregroundStyle(category == value ? p.text : p.muted)
                .padding(.horizontal, 14).frame(minHeight: max(32, presentation.minimumControlHeight))
                .background(category == value ? p.primary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(category == value ? p.primary.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
    }

    private func scenarioCard(_ scenario: ConsoleScenario) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(scenario.category).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                Spacer()
                Text(console.labels["example"] ?? "").font(ConsoleTypography.sans(11))
                    .foregroundStyle(p.muted).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.text.opacity(0.04), in: Capsule()).overlay(Capsule().stroke(p.border))
            }
            Text(scenario.title).font(ConsoleTypography.subheadline.bold()).foregroundStyle(p.text)
            Text(scenario.description).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button(console.labels["run"] ?? "") { model.useConsoleScenario(scenario, run: true) }
                    .buttonStyle(ConsoleButtonStyle(primary: true, minimumHeight: presentation.minimumControlHeight))
                    .accessibilityLabel("Run: \(scenario.title)")
                Button(console.labels["load_prompt"] ?? "") { model.useConsoleScenario(scenario, run: false) }
                    .buttonStyle(ConsoleButtonStyle(primary: false, minimumHeight: presentation.minimumControlHeight))
                    .accessibilityLabel("Load the prompt for: \(scenario.title)")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    @Environment(ThemeStore.self) var theme
    var primary = false
    var minimumHeight = 0.0
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(ConsoleTypography.caption.weight(primary ? .semibold : .regular))
            .foregroundStyle(primary ? .white : theme.palette.text.opacity(0.85))
            .padding(.horizontal, 14).frame(minHeight: max(34, minimumHeight))
            .background(
                primary ? AnyShapeStyle(theme.palette.gradient) : AnyShapeStyle(theme.palette.text.opacity(0.025)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? .clear : theme.palette.border))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ConsoleSurfaceOverlay: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let console: ConsoleModel
    let presentation: ConsolePresentation
    let size: CGSize
    private var p: AstralPalette { theme.palette }
    private var currentNavigationItem: ChromeMenuItem? {
        guard
            model.pendingSurfaceKey != "guidance"
                || model.pendingSurfaceParams["view"]?.stringValue != "selection"
        else { return nil }
        let candidates = model.chromeMenu?.allItems.filter { $0.surface == model.pendingSurfaceKey } ?? []
        return candidates.first { item in
            item.params.objectValue?.allSatisfy { key, value in model.pendingSurfaceParams[key] == value } == true
        } ?? candidates.first
    }
    private var hasNavigation: Bool { currentNavigationItem != nil && !model.mandatorySurface }
    private var isIntro: Bool { model.pendingSurfaceKey == "agent_intro" && model.pendingSurface != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { model.closeSurface() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("✦").font(ConsoleTypography.title3).foregroundStyle(p.primary)
                        .frame(width: 36, height: 36).background(
                            p.primary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            model.pendingSurface?.title ?? currentNavigationItem?.label
                                ?? console.composerActions.first {
                                    $0.action?.surface == model.pendingSurfaceKey
                                        && $0.action?.params == model.pendingSurfaceParams
                                }?.label ?? "Settings"
                        )
                        .font(ConsoleTypography.headline).foregroundStyle(p.text)
                        if let subtitle = model.pendingSurface?.subtitle {
                            Text(subtitle).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        }
                    }
                    Spacer()
                    if model.mandatorySurface {
                        Button(model.chromeMenu?.signout.label ?? "Sign out") { Task { await model.signOut() } }
                            .buttonStyle(.plain).foregroundStyle(p.error)
                    } else {
                        Button {
                            model.closeSurface()
                        } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).foregroundStyle(p.muted).accessibilityLabel("Close")
                    }
                }
                .padding(.horizontal, presentation.settingsPresentation == .sheet ? 16 : 20).padding(.vertical, 18)
                Divider().overlay(p.border)
                if hasNavigation, presentation.settingsNavigationAxis == .horizontal {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.chromeMenu?.allItems ?? []) { item in navigationButton(item) }
                            signoutButton
                        }
                        .padding(12)
                    }.fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(p.border)
                }
                HStack(spacing: 0) {
                    if hasNavigation, presentation.settingsNavigationAxis == .vertical {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 10) {
                                Text(console.identity.initials).font(ConsoleTypography.caption.bold()).foregroundStyle(
                                    .white
                                )
                                .frame(width: 34, height: 34).background(p.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(console.identity.name).font(ConsoleTypography.subheadline.weight(.semibold))
                                    Text(console.identity.role).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                }
                            }
                            Divider().overlay(p.border)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(model.chromeMenu?.menu ?? []) { group in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.label.uppercased()).font(ConsoleTypography.sans(10).bold())
                                                .tracking(0.8).foregroundStyle(p.muted).padding(8)
                                            ForEach(group.items) { item in navigationButton(item) }
                                        }
                                    }
                                }
                            }
                            signoutButton
                        }
                        .padding(12).frame(width: presentation.settingsNavigationWidth)
                        .background(p.bg.opacity(0.35))
                        Divider().overlay(p.border)
                    }
                    if isIntro, let surface = model.pendingSurface {
                        ConsoleIntroSurfaceView(
                            components: surface.components, presentation: presentation,
                            maximumHeight: max(0, min(size.height, presentation.settingsMaxHeight) - 80))
                    } else {
                        SurfaceView(embedded: true)
                    }
                }
            }
            .frame(
                width: min(size.width, hasNavigation ? presentation.settingsWidth : presentation.dialogWidth),
                height: isIntro && presentation.settingsPresentation != .sheet
                    ? nil : min(size.height, presentation.settingsMaxHeight)
            )
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: presentation.settingsPresentation == .sheet ? 0 : 14))
            .overlay(
                RoundedRectangle(cornerRadius: presentation.settingsPresentation == .sheet ? 0 : 14).stroke(p.border)
            )
            .accessibilityAddTraits(.isModal)
        }
    }

    private var signoutButton: some View {
        Button(model.chromeMenu?.signout.label ?? "Sign out") { Task { await model.signOut() } }
            .buttonStyle(.plain).foregroundStyle(p.error).font(ConsoleTypography.subheadline)
            .padding(.horizontal, 8).frame(minHeight: max(32, presentation.minimumControlHeight))
            .accessibilityIdentifier("console-settings-signout")
    }

    private func navigationButton(_ item: ChromeMenuItem) -> some View {
        Button {
            model.openMenuItem(item)
        } label: {
            Text(item.label).font(ConsoleTypography.subheadline)
                .foregroundStyle(item.key == currentNavigationItem?.key ? p.text : p.muted)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(
                    maxWidth: presentation.settingsNavigationAxis == .vertical ? .infinity : nil, alignment: .leading
                )
                .background(
                    item.key == currentNavigationItem?.key ? p.primary.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).accessibilityAddTraits(item.key == currentNavigationItem?.key ? .isSelected : [])
    }
}
