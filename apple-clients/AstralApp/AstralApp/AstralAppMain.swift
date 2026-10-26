// SwiftUI app entry point for the shared iOS/macOS AstralDeep client; selects a deterministic UI-test fixture
// model over the real AppModel when running under XCTest.
// On macOS it also starts the Sparkle updater and gates connecting on the signed minimum build.

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
    #if os(macOS)
        @StateObject private var updates: UpdateCoordinator
        @State private var updateRequirement: UpdateRequirement?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
        @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    #endif
    private let unitTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        #if DEBUG
            let launchModel = FirstLoginUITestFixture.workspaceActionsModel() ?? AppModel()
        #else
            let launchModel = AppModel()
        #endif
        _model = State(initialValue: launchModel)
        #if os(macOS)
            let busy: @MainActor () -> Bool = { [launchModel] in
                UpdateCoordinator.isTaskActive(
                    turnActive: launchModel.turnActive, session: launchModel.macComputerHost.session)
            }
            _updates = StateObject(
                wrappedValue: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    ? UpdateCoordinator(isBusy: busy) : UpdateCoordinator.live(isBusy: busy))
        #endif
        NoStoreHTTP.prepareForLaunch()
        ConsoleTypography.registerFonts()
    }

    @ViewBuilder private var gatedRoot: some View {
        #if os(macOS)
            if let updateRequirement {
                UpdateRequiredView(requirement: updateRequirement, coordinator: updates)
            } else {
                RootView().environment(\.astralUpdateCoordinator, updates)
            }
        #else
            RootView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            gatedRoot
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
                .preferredColorScheme(model.themeStore.colorScheme)
                .task {
                    #if DEBUG
                        if let scenario = FirstLoginUITestFixture.requestedScenario() {
                            FirstLoginUITestFixture.install(scenario, on: model)
                            return
                        }
                    #endif
                    #if os(macOS)
                        if !unitTestHost, let requirement = await updates.enforce(UpdatePolicyGate()) {
                            updateRequirement = requirement
                            return
                        }
                    #endif
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
                        model.macComputerHost.sessionLocked()
                    }
                    .onReceive(
                        NSWorkspace.shared.notificationCenter.publisher(
                            for: NSWorkspace.screensDidSleepNotification)
                    ) { _ in
                        model.macComputerHost.sessionLocked()
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
                        model.macComputerHost.applicationWillTerminate()
                    }
                #endif
                #if os(macOS)
                    .sheet(isPresented: $updates.settingsPresented) {
                        UpdateSettingsSheet(coordinator: updates)
                            .environment(model.themeStore)
                            .tint(model.themeStore.palette.primary)
                    }
                    .frame(minWidth: 320, minHeight: 480)
                #endif
        }
        #if os(macOS)
            .windowStyle(.titleBar)
            .defaultSize(width: 1280, height: 820)
            .commands {
                MacWorkbenchCommands()
                CommandGroup(after: .appInfo) { UpdateMenuItems(coordinator: updates) }
            }
        #endif
    }
}
