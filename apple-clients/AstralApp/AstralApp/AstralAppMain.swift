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
        @State private var meshWake: MeshBackgroundWake?
        @State private var localNotices: IOSNotificationAdapter?
    #endif
    private let unitTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            LegacyVoiceModelCleanup.runOnce()
        }
        let launchModel = AppModel()
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
        #if os(iOS)
            let wakeRuntime = _mesh.wrappedValue
            let notices = IOSNotificationAdapter.live()
            notices.onToken = { [weak launchModel] in launchModel?.meshPush.receivedToken($0) }
            notices.onRoute = { [weak wakeRuntime] route in
                guard let wakeRuntime, wakeRuntime.isReady, wakeRuntime.hasMesh else { return false }
                if let chat = route.chatId { Task { await wakeRuntime.openChat(chat) } }
                return true
            }
            let wake = MeshBackgroundWake(
                authorized: { [weak wakeRuntime] in
                    wakeRuntime?.isReady == true
                        && wakeRuntime?.hasMesh == true && UIApplication.shared.isProtectedDataAvailable
                },
                synchronize: { [weak wakeRuntime, weak notices] in
                    guard let wakeRuntime else { return false }
                    let changed = try await wakeRuntime.synchronizeAfterWake()
                    if changed, let notices, let notice = wakeRuntime.wakeNotice() {
                        await notices.post(notice.ref, chatId: notice.chatId)
                    }
                    return changed
                })
            _meshWake = State(initialValue: wake)
            _localNotices = State(initialValue: notices)
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                MeshBackgroundWake.active = wake
                IOSNotificationAdapter.active = notices
            }
        #endif
        #if os(macOS)
            lifecycle = MacAppLifecycle(handlers: .live(launchModel))
            let meshRuntime = _mesh.wrappedValue
            let busy: @MainActor () -> Bool = { [launchModel, meshRuntime] in
                UpdateCoordinator.isTaskActive(
                    turnActive: meshRuntime.currentTurn?.running == true,
                    session: launchModel.macComputerHost.session)
            }
            _updates = StateObject(
                wrappedValue: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    ? UpdateCoordinator(isBusy: busy) : UpdateCoordinator.live(isBusy: busy))
        #endif
        NoStoreHTTP.prepareForLaunch()
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup("AstralDeep", id: "main") {
            MeshRootView()
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
                        guard let destination = InlineMarkdown.safeLink(url) else {
                            return .discarded
                        }
                        return .systemAction(destination)
                    }
                )
                .preferredColorScheme(model.themeStore.colorScheme)
                .task {
                    #if os(iOS)
                        if !unitTestHost { await localNotices?.start() }
                    #endif
                    await model.onDeviceVoice.store?.attach()
                    #if os(macOS)
                        if !unitTestHost, let requirement = await updates.enforce(UpdatePolicyGate()) {
                            updateRequirement = requirement
                            return
                        }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.voiceSceneBecameActive()
                    case .inactive, .background: model.voiceSceneBecameInactive()
                    @unknown default: model.voiceSceneBecameInactive()
                    }
                    #if os(iOS)
                        if phase == .active {
                            Task { await localNotices?.sceneDidBecomeActive() }
                        } else if phase == .background {
                            localNotices?.sceneDidEnterBackground()
                        }
                    #endif
                }
                #if os(iOS)
                    .onChange(of: mesh.isReady) { _, _ in localNotices?.resolvePendingRoute() }
                #endif
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
                CommandGroup(after: .appInfo) { UpdateMenuItems(coordinator: updates) }
            }
        #endif
        #if os(macOS)
            MenuBarExtra("AstralDeep", systemImage: "sparkles") {
                MacMenuBarContent(updateRequired: updateRequirement != nil)
            }
            .menuBarExtraStyle(.menu)
            Settings {
                MacSettingsView(updates: updates)
                    .environment(model.themeStore)
                    .font(ConsoleTypography.body)
                    .tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)
            }
        #endif
    }
}
