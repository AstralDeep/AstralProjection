// Holds the shared device-side services of the app: theme, on-device voice and its lifecycle, the paired-watch relays
// and, on macOS, the computer host. MeshRootView and the mesh screens read it from the environment.

import AVFoundation
import AstralCore
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

@MainActor
@Observable
final class AppModel: NSObject {
    struct ChatTurn: Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
        let components: [AstralComponent]
        let branch: ConversationMessageBranch?

        init(
            id: String,
            role: String,
            text: String,
            components: [AstralComponent] = [],
            branch: ConversationMessageBranch? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.components = components
            self.branch = branch
        }
    }

    #if os(macOS)
        typealias LocalComputerHost = MacComputerHost
        let macComputerHost: MacComputerHost
        let macBrowser: MacBrowserDriver
    #endif
    let themeStore = ThemeStore()
    @ObservationIgnored let voice: AppleVoiceSessionController
    @ObservationIgnored let onDeviceVoice: OnDeviceVoiceController
    #if os(iOS)
        @ObservationIgnored let watchVoice: PairedWatchVoiceRelay
        @ObservationIgnored let watchRelay: PhoneCompanionRelay
        @ObservationIgnored let meshPush: MeshPushCoordinator
    #endif

    #if os(macOS)
        init(
            defaults: UserDefaults = .standard,
            voiceController: AppleVoiceSessionController? = nil,
            onDeviceVoiceController: OnDeviceVoiceController? = nil,
            computerHost: LocalComputerHost? = nil
        ) {
            let host = computerHost ?? MacComputerHost()
            macComputerHost = host
            macBrowser = MacBrowserDriver(host: host, defaults: defaults)
            voice = voiceController ?? AppleVoiceSessionController()
            onDeviceVoice = onDeviceVoiceController ?? OnDeviceVoiceController()
            super.init()
        }
    #else
        init(
            voiceController: AppleVoiceSessionController? = nil,
            onDeviceVoiceController: OnDeviceVoiceController? = nil
        ) {
            voice = voiceController ?? AppleVoiceSessionController()
            let localVoice = onDeviceVoiceController ?? OnDeviceVoiceController()
            onDeviceVoice = localVoice
            watchVoice = PairedWatchVoiceRelay(controller: localVoice, channel: WatchOverrideSync.shared)
            watchRelay = PhoneCompanionRelay(channel: WatchOverrideSync.shared)
            meshPush = MeshPushCoordinator(
                rest: AstralConfig.meshPushPublisherURL.flatMap { MeshPushRest(publisherURL: $0) })
            super.init()
            WatchOverrideSync.shared.activate()
        }
    #endif

    #if os(macOS)
        func computerApplicationWillTerminate() {
            _ = macComputerHost.releaseBypass()
            macComputerHost.recordRunningJobsAsUncertain()
            macComputerHost.applicationWillTerminate()
        }
    #endif

    func voiceSceneBecameActive() {
        #if os(iOS)
            meshPush.retry()
        #endif
        voice.sceneBecameActive()
        onDeviceVoice.resume()
    }

    func voiceSceneBecameInactive() {
        voice.sceneBecameInactive()
        onDeviceVoice.suspend()
    }

    func voiceAudioSessionInterrupted() {
        voice.audioSessionInterrupted()
        onDeviceVoice.interruptionBegan()
    }

    func voiceAudioSessionInterruptionEnded() {
        voice.audioSessionInterruptionEnded()
        onDeviceVoice.interruptionEnded()
    }

    func voiceAudioRouteChanged() { voice.audioRouteChanged() }

    func voiceAudioEngineConfigurationChanged() { voice.audioEngineConfigurationChanged() }

    func voiceSessionLocked() {
        voice.sessionLocked()
        onDeviceVoice.sessionLocked()
    }

    func voiceSessionUnlocked() {
        voice.sessionUnlocked()
        onDeviceVoice.sessionUnlocked()
    }

    func voiceApplicationWillTerminate() {
        voice.close()
        onDeviceVoice.disconnect()
    }
}
