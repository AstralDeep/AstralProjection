// The root of mesh mode: opens the runtime, shows onboarding or the shell, and hosts the consent sheet and the voice model setup sheet.
// The shell has chats, devices and settings, each under the honest sync strip and any approvals waiting on this device.

import SwiftUI

struct MeshRootView: View {
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
            } else if !mesh.hasMesh {
                MeshOnboardingView()
            } else {
                MeshShell()
            }
        }
    }
}

struct MeshShell: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModel.self) private var model
    @State private var selectedChat: String?

    var body: some View {
        VStack(spacing: 0) {
            MeshConsentCards()
            TabView {
                NavigationSplitView {
                    MeshChatListView(selection: $selectedChat)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
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
        .task {
            mesh.attachVoice(model.onDeviceVoice)
        }
        .onDisappear { mesh.detachVoice(model.onDeviceVoice) }
    }
}
