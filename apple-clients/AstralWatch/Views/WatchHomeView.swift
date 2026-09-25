// Signed-in watch home: one-tap new conversation, bounded recent history (WatchHistoryRow), visible account
// identity, and sign-out; launched from AstralWatchApp and the navigation harness.

import AstralCore
import SwiftUI

struct WatchNavigationView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack { WatchHomeView() }
            .alert(
                model.consoleLabel("brand", fallback: "AstralDeep"),
                isPresented: Binding(
                    get: { model.handoffMessage != nil }, set: { if !$0 { model.handoffMessage = nil } }
                )
            ) {
            } message: {
                Text(verbatim: model.handoffMessage ?? "")
            }
    }
}

struct WatchOwnerSurfaceNavigation: ViewModifier {
    @Environment(WatchModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .navigationDestination(isPresented: $model.workVisible) { WatchWorkSurfaceView() }
            .navigationDestination(
                isPresented: Binding(
                    get: { model.guidanceVisible },
                    set: { if !$0 { model.closeGuidance() } }
                )
            ) { WatchGuidanceSurfaceView() }
    }
}

struct WatchHomeView: View {
    @Environment(WatchModel.self) var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.console != nil {
                WatchConsoleHome()
            } else {
                legacyHome
                    .modifier(WatchOwnerSurfaceNavigation())
            }
        }
        .navigationDestination(isPresented: $model.consoleChatVisible) { WatchChatView() }
        .task { await model.refreshRecents() }
        .overlay(alignment: .bottom) {
            if !model.connected {
                Text("Reconnecting…").font(ConsoleTypography.footnote).padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var legacyHome: some View {
        List {
            Section {
                NavigationLink {
                    WatchChatView()
                        .onAppear { model.newConversation() }
                } label: {
                    Label("New conversation", systemImage: "plus.bubble.fill")
                        .font(ConsoleTypography.headline)
                }
            }

            ForEach(model.ownerSurfaceControls) { control in
                Button {
                    if control.action?.surface == "work" {
                        model.openWork(control)
                    } else {
                        model.openGuidance(control)
                    }
                } label: {
                    Label(control.label ?? control.key, systemImage: control.icon ?? "square.grid.2x2")
                        .font(ConsoleTypography.headline)
                }
                .disabled(!model.connected)
            }

            if model.recentsLoading || !model.recents.isEmpty {
                Section {
                    if model.recentsLoading && model.recents.isEmpty {
                        ProgressView("Loading your chats…")
                            .font(ConsoleTypography.footnote)
                    }
                    ForEach(model.recents) { chat in
                        NavigationLink {
                            WatchChatView()
                                .onAppear { model.openChat(chat) }
                        } label: {
                            WatchHistoryRow(chat: chat)
                        }
                    }
                } header: {
                    Text(verbatim: model.recentsTitle)
                }
            }

            if let status = model.rootStatusText {
                let accessibility = WatchAccessibility060.rootStatus(status)
                Section("Live status") {
                    Label {
                        Text(status).lineLimit(3)
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .font(ConsoleTypography.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(accessibility.identifier)
                    .accessibilityLabel(accessibility.name)
                    .accessibilityValue(accessibility.state)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Section {
                Label(
                    model.accountName.isEmpty ? "Signed in" : model.accountName,
                    systemImage: "person.crop.circle"
                )
                .font(ConsoleTypography.footnote)
                .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await model.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("AstralDeep")

    }
}

struct WatchWorkSurfaceView: View {
    @Environment(WatchModel.self) var model
    @State private var timedOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let update = model.workUpdate {
                    Text(verbatim: update.title).font(ConsoleTypography.headline)
                    ForEach(Array(update.components.enumerated()), id: \.offset) { _, component in
                        WatchComponentView(component: component, workRead: true)
                    }
                } else if timedOut || model.workReadFailed || !model.connected {
                    Text("This view is unavailable. Reconnect and retry.")
                        .font(ConsoleTypography.footnote)
                    Button("Retry") { model.retryWorkRead() }.disabled(!model.connected)
                } else {
                    ProgressView("Loading…")
                }
            }.padding(6)
        }
        .task(id: model.workReadState.generation) {
            timedOut = false
            guard let generation = model.workReadState.generation else { return }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard !Task.isCancelled, model.workUpdate == nil else { return }
            model.failWorkRead(generation: generation)
            timedOut = true
        }
        .onDisappear { model.closeWorkRead() }
    }
}

struct WatchHistoryRow: View {
    @Environment(WatchModel.self) private var model
    let chat: ChatSummary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !chat.icon.isEmpty {
                Text(verbatim: chat.icon)
                    .font(ConsoleTypography.footnote)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chat.displayTitle)
                    .font(ConsoleTypography.footnote)
                    .lineLimit(2)
                let time = chat.relativeTime()
                if !time.isEmpty {
                    Text(verbatim: time)
                        .font(ConsoleTypography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if chat.hasSavedComponents {
                Image(systemName: "star.fill")
                    .font(ConsoleTypography.caption2)
                    .foregroundStyle(model.theme.palette.warning)
                    .accessibilityLabel("Has saved components")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
