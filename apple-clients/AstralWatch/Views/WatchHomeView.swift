// The watch home: the chats the paired iPhone relays, with plain states for an iPhone out of reach or no open mesh.
// Launched from AstralWatchApp and the navigation harness; opening a chat pushes WatchChatView.

import AstralCore
import SwiftUI

struct WatchNavigationView: View {
    var body: some View {
        NavigationStack {
            WatchHomeView()
                .containerBackground(.black, for: .navigation)
        }
    }
}

struct WatchHomeView: View {
    @Environment(WatchModel.self) var model
    @State private var chatVisible = false

    var body: some View {
        Group {
            if !model.phoneReachable {
                WatchStateView(
                    icon: "iphone.slash", title: "Your iPhone is out of reach",
                    detail: "Bring it nearby to continue.", identifier: "watch-state-phone-unreachable")
            } else {
                switch model.link {
                case .waiting: WatchWaitingView()
                case .noMesh: WatchNoMeshView(stopped: false)
                case .stopped: WatchNoMeshView(stopped: true)
                case .ready: chatList
                }
            }
        }
        .navigationTitle("AstralDeep")
        .navigationDestination(isPresented: $chatVisible) { WatchChatView() }
        .onChange(of: chatVisible) { _, visible in if !visible { model.closeChat() } }
    }

    private var chatList: some View {
        List {
            if model.chats.isEmpty {
                Text(model.chatsLoaded ? "No chats yet. Start one on your iPhone." : "Loading your chats…")
                    .font(ConsoleTypography.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-chat-list-empty")
            }
            ForEach(model.chats, id: \.chatId) { chat in
                Button {
                    model.openChat(chat)
                    chatVisible = true
                } label: {
                    WatchHistoryRow(chat: chat)
                }
            }
            if model.omittedChats > 0 {
                Text("\(model.omittedChats) more on your iPhone")
                    .font(ConsoleTypography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .refreshable { model.refreshChats() }
    }
}

struct WatchStateView: View {
    let icon: String
    let title: String
    let detail: String
    let identifier: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(ConsoleTypography.title2)
            Text(title).font(ConsoleTypography.headline).multilineTextAlignment(.center)
            Text(detail).font(ConsoleTypography.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct WatchWaitingView: View {
    var body: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("Waiting for your iPhone…").font(ConsoleTypography.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch-state-waiting")
    }
}

struct WatchNoMeshView: View {
    let stopped: Bool

    var body: some View {
        WatchStateView(
            icon: "iphone.gen3",
            title: stopped ? "Your mesh is stopped" : "Open your mesh on your iPhone",
            detail: stopped ? "Start it on your iPhone to continue." : "Then your chats appear here.",
            identifier: "watch-state-no-mesh")
    }
}

struct WatchHistoryRow: View {
    let chat: CompanionChatSummary

    var body: some View {
        Text(verbatim: chat.title)
            .font(ConsoleTypography.footnote)
            .lineLimit(2)
            .accessibilityElement(children: .combine)
    }
}
