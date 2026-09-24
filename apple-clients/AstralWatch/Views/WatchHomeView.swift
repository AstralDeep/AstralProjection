// Signed-in watch home: one-tap new conversation, bounded recent history (WatchHistoryRow), visible account
// identity, and sign-out; launched from AstralWatchApp and the navigation harness.

import AstralCore
import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchModel.self) var model

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                NavigationLink {
                    WatchChatView()
                        .onAppear { model.newConversation() }
                } label: {
                    Label("New conversation", systemImage: "plus.bubble.fill")
                        .font(AstralTypography.headline)
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
                        .font(AstralTypography.headline)
                }
                .disabled(!model.connected)
            }

            if model.recentsLoading || !model.recents.isEmpty {
                Section {
                    if model.recentsLoading && model.recents.isEmpty {
                        ProgressView("Loading your chats…")
                            .font(AstralTypography.footnote)
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
                    .font(AstralTypography.footnote)
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
                .font(AstralTypography.footnote)
                .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await model.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("AstralDeep")
        .navigationDestination(isPresented: $model.workVisible) { WatchWorkSurfaceView() }
        .navigationDestination(
            isPresented: Binding(
                get: { model.guidanceVisible },
                set: { presented in
                    if !presented { model.closeGuidance() }
                })
        ) { WatchGuidanceSurfaceView() }
        .task { await model.refreshRecents() }
        .overlay(alignment: .bottom) {
            if !model.connected {
                Text("Reconnecting…")
                    .font(AstralTypography.footnote)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

struct WatchWorkSurfaceView: View {
    @Environment(WatchModel.self) var model
    @State private var timedOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let update = model.workUpdate {
                    Text(verbatim: update.title).font(AstralTypography.headline)
                    ForEach(Array(update.components.enumerated()), id: \.offset) { _, component in
                        WatchComponentView(component: component, workRead: true)
                    }
                } else if timedOut || model.workReadFailed || !model.connected {
                    Text("This view is unavailable. Reconnect and retry.")
                        .font(AstralTypography.footnote)
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
    let chat: ChatSummary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !chat.icon.isEmpty {
                Text(verbatim: chat.icon)
                    .font(AstralTypography.footnote)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chat.displayTitle)
                    .font(AstralTypography.footnote)
                    .lineLimit(2)
                let time = chat.relativeTime()
                if !time.isEmpty {
                    Text(verbatim: time)
                        .font(AstralTypography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if chat.hasSavedComponents {
                Image(systemName: "star.fill")
                    .font(AstralTypography.caption2)
                    .foregroundStyle(WatchBrand.warning)
                    .accessibilityLabel("Has saved components")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
