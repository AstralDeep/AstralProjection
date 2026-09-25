// SwiftUI app entry point for the shared iOS/macOS AstralDeep client; selects a deterministic UI-test fixture
// model over the real AppModel when running under XCTest.

import AVFoundation
import AstralCore
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

@main
struct AstralApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let unitTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        #if DEBUG
            _model = State(initialValue: FirstLoginUITestFixture.workspaceActionsModel() ?? AppModel())
        #else
            _model = State(initialValue: AppModel())
        #endif
        NoStoreHTTP.prepareForLaunch()
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .font(ConsoleTypography.body)
                .environment(model.themeStore)
                .tint(model.themeStore.palette.primary)
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        guard let destination = InlineMarkdown.safeLink(url, relativeTo: model.serverBase) else {
                            return .discarded
                        }
                        return .systemAction(destination)
                    }
                )
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                        if let scenario = FirstLoginUITestFixture.requestedScenario() {
                            FirstLoginUITestFixture.install(scenario, on: model)
                            return
                        }
                    #endif
                    // Skips real bootstrap in unit tests — avoids blocking on a Keychain prompt
                    if !unitTestHost { await model.bootstrap() }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.voiceSceneBecameActive()
                    case .inactive, .background: model.voiceSceneBecameInactive()
                    @unknown default: model.voiceSceneBecameInactive()
                    }
                }
                #if os(iOS)
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: AVAudioSession.interruptionNotification)
                    ) { notification in
                        guard
                            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                                as? UInt,
                            let type = AVAudioSession.InterruptionType(rawValue: raw)
                        else { return }
                        if type == .began {
                            model.voiceAudioSessionInterrupted()
                        } else {
                            model.voiceAudioSessionInterruptionEnded()
                        }
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: AVAudioSession.routeChangeNotification)
                    ) { _ in
                        model.voiceAudioRouteChanged()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.protectedDataWillBecomeUnavailableNotification)
                    ) { _ in
                        model.voiceSessionLocked()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.protectedDataDidBecomeAvailableNotification)
                    ) { _ in
                        model.voiceSessionUnlocked()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.willTerminateNotification)
                    ) { _ in
                        model.voiceApplicationWillTerminate()
                    }
                #else
                    .onReceive(
                        NSWorkspace.shared.notificationCenter.publisher(
                            for: NSWorkspace.sessionDidResignActiveNotification)
                    ) { _ in
                        model.voiceSessionLocked()
                    }
                    .onReceive(
                        NSWorkspace.shared.notificationCenter.publisher(
                            for: NSWorkspace.sessionDidBecomeActiveNotification)
                    ) { _ in
                        model.voiceSessionUnlocked()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: .AVAudioEngineConfigurationChange)
                    ) { _ in
                        model.voiceAudioEngineConfigurationChanged()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSApplication.willTerminateNotification)
                    ) { _ in
                        model.voiceApplicationWillTerminate()
                    }
                #endif
                #if os(macOS)
                    .frame(minWidth: 320, minHeight: 480)
                #endif
        }
        #if os(macOS)
            .windowStyle(.titleBar)
            .defaultSize(width: 1280, height: 820)
        #endif
    }
}
