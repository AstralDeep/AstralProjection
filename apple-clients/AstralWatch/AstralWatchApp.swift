// watchOS app entry point wiring WatchModel into the signed-in/signed-out navigation shell (DeviceLoginView,
// WatchHomeView) with the shared AstralDeep tint.

import AstralCore
import SwiftUI

@main
struct AstralWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchModel()

    init() {
        NoStoreHTTP.prepareForLaunch()
        AstralTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.phase {
                case .signedOut, .waitingApproval, .loginFailed, .unavailable:
                    DeviceLoginView()
                case .signedIn:
                    NavigationStack {
                        WatchHomeView()
                    }
                }
            }
            .environment(model)
            .font(AstralTypography.body)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard let destination = InlineMarkdown.safeLink(url, relativeTo: model.serverBase) else {
                        return .discarded
                    }
                    return .systemAction(destination)
                }
            )
            .tint(Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255))
            .task { await model.bootstrap() }
            .onChange(of: scenePhase) { _, phase in
                model.handleVoiceScenePhase(phase)
            }
        }
    }
}
