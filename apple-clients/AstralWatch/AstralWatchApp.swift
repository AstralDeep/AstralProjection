// watchOS app entry point wiring WatchModel to the paired iPhone through WatchOverrideSync and into the navigation shell
// with the shared AstralDeep tint.

import AstralCore
import SwiftUI

@main
struct AstralWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchModel()

    init() {
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            WatchNavigationView()
                .environment(model)
                .font(ConsoleTypography.body)
                .environment(\.openURL, OpenURLAction { _ in .discarded })
                .tint(model.theme.palette.primary)
                .foregroundStyle(model.theme.palette.text)
                .background(model.theme.palette.bg, ignoresSafeAreaEdges: [])
                .preferredColorScheme(model.theme.colorScheme)
                .task { model.attach(.shared) }
                .onChange(of: scenePhase) { _, phase in
                    model.handleVoiceScenePhase(phase)
                    if phase == .active { model.refreshChats() }
                }
        }
    }
}
