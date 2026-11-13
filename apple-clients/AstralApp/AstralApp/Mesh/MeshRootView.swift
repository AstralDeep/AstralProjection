// The root of mesh mode: opens the runtime, shows onboarding or the shell, and hosts the consent sheet and the voice model setup sheet.
// The shell has chats, devices and settings, each under the honest sync strip and any approvals waiting on this device.

import SwiftUI

struct MeshRootView: View {
    var start: MeshDestination?
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModeStore.self) private var modeStore
    @Environment(ConsentCoordinator.self) private var consent
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        content
            .background(p.bg.ignoresSafeArea())
            .consentSheet(consent)
            .sheet(
                isPresented: Binding(
                    get: { model.onDeviceVoice.showingSetup }, set: { model.onDeviceVoice.showingSetup = $0 })
            ) {
                VoiceModelSetupView(controller: model.onDeviceVoice) {
                    model.onDeviceVoice.showingSetup = false
                    Task { await model.onDeviceVoice.activate() }
                }
            }
            .task { await mesh.open() }
    }

    @ViewBuilder
    private var content: some View {
        switch mesh.phase {
        case .closed, .opening:
            ProgressView("Opening your mesh").accessibilityIdentifier("mesh.opening")
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.failed")
                Button("Try again") { Task { await mesh.open() } }.accessibilityIdentifier("mesh.retry")
                Button("Connect to a node") { modeStore.choose(.node) }.accessibilityIdentifier("mesh.node")
            }
            .padding(24)
        case .ready:
            if case .recovery(let words) = mesh.creation {
                MeshRecoveryView(words: words)
            } else if case .restored(let restored) = mesh.restore {
                MeshRestoredView(restored: restored)
            } else if !mesh.hasMesh {
                MeshOnboardingView()
            } else {
                MeshShell(start: start)
            }
        }
    }
}

enum MeshDestination: Hashable {
    case chat(String)
    case devices
    case runs
    case settings
}

struct MeshShell: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModel.self) private var model
    @State private var destination: MeshDestination?
    @State private var selectedChat: String?

    init(start: MeshDestination? = nil) {
        #if DEBUG
            _destination = State(initialValue: start ?? MeshUITestFixture.requestedDestination())
        #else
            _destination = State(initialValue: start)
        #endif
    }

    var body: some View {
        shell
            .alert(
                "Mesh", isPresented: Binding(get: { mesh.notice != nil }, set: { if !$0 { mesh.notice = nil } })
            ) {
                Button("OK") { mesh.notice = nil }
            } message: {
                Text(mesh.notice ?? "")
            }
            .task {
                mesh.attachVoice(model.onDeviceVoice)
            }
            .onDisappear { mesh.detachVoice(model.onDeviceVoice) }
    }

    #if os(macOS)
        private var shell: some View {
            NavigationSplitView {
                MeshSidebar(destination: $destination)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            } detail: {
                VStack(spacing: 0) {
                    MeshConsentCards()
                    MeshSyncStrip(showsSync: false)
                    detail
                }
            }
            .font(ConsoleTypography.body)
            .onChange(of: destination) { _, value in
                Task {
                    if case .chat(let id) = value { await mesh.openChat(id) } else { mesh.closeChat() }
                }
            }
            .onAppear {
                if destination == nil { destination = .devices }
                if case .chat(let id) = destination { Task { await mesh.openChat(id) } }
            }
        }

        @ViewBuilder
        private var detail: some View {
            switch destination {
            case .chat:
                MeshChatDetailView()
            case .devices:
                NavigationStack { MeshDevicesView() }
            case .runs:
                NavigationStack { MeshRunsView() }
            case .settings:
                NavigationStack { MeshSettingsView() }
            case nil:
                ContentUnavailableView("Choose something", systemImage: "sidebar.left")
            }
        }
    #else
        private var shell: some View {
            VStack(spacing: 0) {
                MeshConsentCards()
                TabView {
                    NavigationSplitView {
                        MeshChatListView(selection: $selectedChat)
                    } detail: {
                        if selectedChat != nil {
                            MeshChatDetailView()
                        } else {
                            ContentUnavailableView("Choose a chat", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .accessibilityIdentifier("mesh.tab.chats")
                    NavigationStack {
                        VStack(spacing: 0) {
                            MeshSyncStrip()
                            MeshDevicesView()
                        }
                    }
                    .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                    .accessibilityIdentifier("mesh.tab.devices")
                    NavigationStack {
                        VStack(spacing: 0) {
                            MeshSyncStrip()
                            MeshRunsView()
                        }
                    }
                    .tabItem { Label("Runs", systemImage: "arrow.triangle.2.circlepath") }
                    .accessibilityIdentifier("mesh.tab.runs")
                    NavigationStack {
                        VStack(spacing: 0) {
                            MeshSyncStrip()
                            MeshSettingsView()
                        }
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("mesh.tab.settings")
                }
            }
            .onChange(of: selectedChat) { _, id in
                Task {
                    if let id { await mesh.openChat(id) } else { mesh.closeChat() }
                }
            }
        }
    #endif
}

#if os(macOS)
    struct MeshSidebar: View {
        @Binding var destination: MeshDestination?
        @Environment(MeshRuntime.self) private var mesh
        @Environment(ThemeStore.self) private var theme
        private var p: AstralPalette { theme.palette }

        var body: some View {
            List(selection: $destination) {
                Section {
                    Label("Devices", systemImage: "laptopcomputer.and.iphone").tag(MeshDestination.devices)
                        .accessibilityIdentifier("mesh.side.devices")
                    Label("Runs", systemImage: "arrow.triangle.2.circlepath").tag(MeshDestination.runs)
                        .accessibilityIdentifier("mesh.side.runs")
                    Label("Settings", systemImage: "gearshape").tag(MeshDestination.settings)
                        .accessibilityIdentifier("mesh.side.settings")
                }
                Section("Chats") {
                    if mesh.chats.isEmpty {
                        Text("No chats yet").foregroundStyle(p.muted).accessibilityIdentifier("mesh.chats.empty")
                    }
                    ForEach(mesh.chats) { chat in
                        MeshChatRow(chat: chat).tag(MeshDestination.chat(chat.chatId))
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(syncColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(MeshPresentation.syncLine(mesh.syncSummary))
                        .font(ConsoleTypography.footnote).foregroundStyle(p.muted).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mesh.strip.sync")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { destination = await mesh.newChat().map { .chat($0) } }
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Chat")
                    .accessibilityIdentifier("mesh.chats.new")
                }
            }
        }

        private var syncColor: Color {
            switch mesh.syncSummary {
            case .synced: return p.success
            case .waiting: return p.warning
            case .alone, .unknown: return p.muted
            }
        }
    }
#endif
