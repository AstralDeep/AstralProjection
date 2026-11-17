// Test-only navigation harness app, compiled by no shipped target, that drives WatchHomeView and WatchChatView UI tests against a scripted phone instead of WatchConnectivity.
// It feeds WatchModel the same packets the iPhone relay sends and records the requests the watch makes.

import AstralCore
import Observation
import SwiftUI

@main
struct WatchNavigationHarnessApp: App {
    @State private var session = WatchNavigationSession()

    init() {
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            WatchNavigationView()
                .environment(session.model)
                .font(ConsoleTypography.body)
                .tint(session.model.theme.palette.primary)
                .foregroundStyle(session.model.theme.palette.text)
                .background(session.model.theme.palette.bg)
                .task { session.run() }
        }
    }
}

@MainActor
private final class WatchNavigationSession {
    static let meshId = "sha256:" + String(repeating: "ab", count: 32)
    let model = WatchModel()
    private let owner = CompanionVoiceOwner(meshId: meshId)!

    func run() {
        let scenario = ProcessInfo.processInfo.environment["ASTRAL_WATCH_NAVIGATION_SCENARIO"] ?? "ready"
        model.requestSink = { [weak self] data in
            self?.answer(data)
            return true
        }
        model.phoneReachable = scenario != "unreachable"
        switch scenario {
        case "no_mesh":
            deliver(.phone(owner: owner, state: .noMesh))
        case "unreachable":
            deliver(.phone(owner: owner, state: .ready))
        default:
            deliver(.phone(owner: owner, state: .ready))
            deliver(
                .chatList(
                    owner: owner,
                    chats: [
                        CompanionChatSummary(chatId: "chat-one", title: "Morning plan"),
                        CompanionChatSummary(chatId: "chat-two", title: "Lab results"),
                    ]))
        }
    }

    private func answer(_ data: Data) {
        guard let request = try? CompanionWatchRequest(data: data) else { return }
        switch request {
        case .openChat(_, let chatId):
            deliver(
                .chat(owner: owner, chatId: chatId, title: "Morning plan", view: "You: hello\nAstral: good morning"))
        case .sendMessage(_, let chatId, let text):
            deliver(.chat(owner: owner, chatId: chatId, title: "Morning plan", view: "You: \(text)\nAstral: on it"))
        case .listChats, .stopRun:
            break
        }
    }

    private func deliver(_ update: CompanionPhoneUpdate) {
        guard let data = try? update.encoded() else { return }
        model.receiveRelay(data)
    }
}
