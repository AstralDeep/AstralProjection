// watchOS app entry point wiring WatchModel into the signed-in/signed-out navigation shell (DeviceLoginView,
// WatchHomeView) with the shared AstralDeep tint.

import AstralCore
import SwiftUI

@main
struct AstralWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var model = WatchModel()

    init() {
        NoStoreHTTP.prepareForLaunch()
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.phase {
                case .signedOut, .waitingApproval, .loginFailed, .unavailable:
                    DeviceLoginView()
                case .signedIn:
                    WatchNavigationView()
                }
            }
            .environment(model)
            .font(ConsoleTypography.body)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard let destination = InlineMarkdown.safeLink(url, relativeTo: model.serverBase) else {
                        return .discarded
                    }
                    return .systemAction(destination)
                }
            )
            .tint(model.theme.palette.primary)
            .foregroundStyle(model.theme.palette.text)
            .background(model.theme.palette.bg)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { report(geometry.size) }
                        .onChange(of: geometry.size) { _, size in report(size) }
                        .onChange(of: displayScale) { _, _ in report(geometry.size) }
                        .onChange(of: reducedMotion) { _, _ in report(geometry.size) }
                }
            }
            .task {
                model.observeDeviceCapabilities()
                await model.bootstrap()
            }
            .onChange(of: scenePhase) { _, phase in
                model.handleVoiceScenePhase(phase)
                if phase == .active { model.reportDeviceCapabilities() }
            }
        }
    }

    private func report(_ size: CGSize) {
        model.viewportChanged(
            width: Int(size.width), height: Int(size.height), scale: displayScale, reducedMotion: reducedMotion)
    }
}
