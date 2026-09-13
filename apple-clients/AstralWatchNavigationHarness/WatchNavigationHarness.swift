// Test-target-only application. No shipped target compiles this file.
import AstralCore
import SwiftUI

@main
struct WatchNavigationHarnessApp: App {
    @State private var session = WatchNavigationSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.ready {
                    NavigationStack { WatchHomeView() }
                        .environment(session.model)
                } else {
                    Text("Connecting test peer")
                }
            }
            .task { await session.run() }
        }
    }
}

@MainActor
@Observable
private final class WatchNavigationSession {
    let model: WatchModel
    var ready = false
    private let socket: WSClient
    private let defaults: UserDefaults
    private let suite: String

    init() {
        // This target accepts only its ephemeral loopback peer. It never calls
        // WatchModel.bootstrap, device login, refresh, voice or a token store.
        let raw = ProcessInfo.processInfo.environment["ASTRAL_WATCH_NAVIGATION_PEER"] ?? ""
        guard let url = URL(string: raw), url.scheme == "ws", url.host == "127.0.0.1",
            let port = url.port, (1...65535).contains(port), url.path == "/watch-navigation",
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { fatalError("A test-owned loopback peer is required") }
        suite = "WatchNavigationHarness.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        socket = WSClient(url: url)
        model = WatchModel(conversationResumeStore: ConversationResumeStore(defaults: defaults), webSocket: socket)
        model.serverBase = URL(string: "http://127.0.0.1:\(port)")!
        model.phase = .signedIn
        model.accountName = "Synthetic local account"
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
    }

    func run() async {
        let events = await socket.events()
        let lifetime = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await socket.stop()
        }
        defer {
            lifetime.cancel()
            defaults.removePersistentDomain(forName: suite)
        }
        await socket.start(onConnect: { [model] in
            await model.registrationFrame(token: "synthetic-loopback-only", resumed: false)
        })
        for await event in events {
            if Task.isCancelled { break }
            await model.handle(event)
            // The real history frame suppresses REST fallback before the real
            // Home List mounts. Menu and all Work responses arrive over WS.
            if case .frame(let frame) = event,
                case .content = WatchHistoryUpdate(frame: frame), !model.workControls.isEmpty
            {
                ready = true
            }
        }
        await socket.stop()
    }
}
