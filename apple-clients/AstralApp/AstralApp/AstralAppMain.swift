// SwiftUI app entry point for the shared iOS/macOS AstralDeep client; selects a deterministic UI-test fixture
// model over the real AppModel when running under XCTest.
// On macOS it also starts the Sparkle updater, gates connecting on the signed minimum build, and hosts Settings,
// a menu bar companion and the Quick Entry and Scheduled Work windows; MacAppLifecycle handles wake, lock and quit.

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
    @State private var modeStore = AppModeStore()
    @State private var consent: ConsentCoordinator
    @State private var mesh: MeshRuntime
    #if os(macOS)
        @StateObject private var updates: UpdateCoordinator
        @State private var nodeHost = MacNodeHostStore()
        @State private var updateRequirement: UpdateRequirement?
        private let lifecycle: MacAppLifecycle
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
        let coordinator = ConsentCoordinator()
        _consent = State(initialValue: coordinator)
        #if DEBUG
            if let scenario = MeshUITestFixture.requestedScenario() {
                let fixture = MeshUITestFixture.install(scenario, consent: coordinator)
                _modeStore = State(initialValue: fixture.mode)
                _mesh = State(initialValue: fixture.runtime)
            } else {
                _mesh = State(initialValue: MeshRuntimeBuilder.live(consent: coordinator))
            }
        #else
            _mesh = State(initialValue: MeshRuntimeBuilder.live(consent: coordinator))
        #endif
        #if os(macOS)
            lifecycle = MacAppLifecycle(handlers: .live(launchModel))
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
        if modeStore.usesMesh {
            MeshRootView()
        } else {
            nodeRoot
        }
    }

    @ViewBuilder private var nodeRoot: some View {
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
        WindowGroup("AstralDeep", id: "main") {
            gatedRoot
                .environment(model)
                .environment(modeStore)
                .environment(consent)
                .environment(mesh)
                #if os(macOS)
                    .environment(nodeHost)
                #endif
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
                    await model.onDeviceVoice.store?.attach()
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
                    if !unitTestHost, !modeStore.usesMesh { await model.bootstrap() }
                }
                .onChange(of: modeStore.mode) { _, mode in
                    #if os(macOS)
                        guard updateRequirement == nil else { return }
                    #endif
                    if mode == .node, !unitTestHost { Task { await model.bootstrap() } }
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
                #endif
                #if os(macOS)
                    .modifier(MacSettingsRouter(updates: updates))
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
        #if os(macOS)
            MenuBarExtra("AstralDeep", systemImage: "sparkles") {
                MacMenuBarContent(model: model, updateRequired: updateRequirement != nil)
            }
            .menuBarExtraStyle(.menu)
            Window("Quick Entry", id: "quick-entry") {
                MacQuickEntryView(model: model, updateRequired: updateRequirement != nil)
                    .environment(model.themeStore)
                    .font(ConsoleTypography.body)
                    .tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)
            }
            .defaultSize(width: 480, height: 260)
            Window("Scheduled Work", id: "scheduled-work") {
                MacScheduledWorkCenter(model: model, updateRequired: updateRequirement != nil)
                    .environment(model)
                    .environment(model.themeStore)
                    .font(ConsoleTypography.body)
                    .tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)
            }
            .defaultSize(width: 900, height: 600)
            Settings {
                MacSettingsView(updates: updates)
                    .environment(model)
                    .environment(model.themeStore)
                    .font(ConsoleTypography.body)
                    .tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)
            }
        #endif
    }
}
