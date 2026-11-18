// The watch's model: a companion that holds no credential and reaches nothing except its paired iPhone.
// Phone packets arrive through WatchOverrideSync, requests leave through one injected sink, and voice runs through the paired phone's bridge; it drives WatchHomeView and WatchChatView.

import AstralCore
import Foundation
import SwiftUI

@MainActor
@Observable
final class WatchModel {
    enum Link: Equatable {
        case waiting, ready, noMesh, stopped
    }

    let theme = ThemeStore()
    let speaker = Speaker()

    private(set) var link = Link.waiting
    private(set) var companionOwner: CompanionVoiceOwner?
    private(set) var chats: [CompanionChatSummary] = []
    private(set) var omittedChats = 0
    private(set) var chatsLoaded = false
    private(set) var activeChatId: String?
    private(set) var activeChatTitle = ""
    private(set) var chatComponents: [AstralComponent] = []
    private(set) var runState = CompanionRunState.idle
    var phoneReachable = false {
        didSet {
            if phoneReachable && !oldValue { refreshChats() }
            armResponseWatch()
        }
    }
    private(set) var phoneNotResponding = false
    var pendingDictation = ""
    var statusText: String?
    var errorBanner: String?

    var voiceState: WatchVoiceState = .off
    var voiceReason = "ready"
    var voiceMessage: String?
    var voicePartialTranscript: String?
    var voiceActivationBusy = false
    @ObservationIgnored var voiceBridge: WatchVoiceBridgeControlling = WatchVoiceBridge()
    @ObservationIgnored var requestSink: (@MainActor (Data) async -> Bool)?
    @ObservationIgnored private var companionVoiceAttempt = UUID()
    @ObservationIgnored private var voiceForegroundActive = true
    @ObservationIgnored private var responseWatch: Task<Void, Never>?
    @ObservationIgnored var responseTimeout = Duration.seconds(10)

    var connected: Bool { phoneReachable && link == .ready }
    var companionVoiceActive: Bool { voiceBridge.companionActive || voiceActivationBusy }
    var runActive: Bool { runState == .running || runState == .stopping }

    init() {
        speaker.onSpeak = { [weak self] text in self?.beginPairedVoice(mode: .playback, text: text) }
        speaker.onStop = { [weak self] in self?.voiceBridge.interruptPlayback() }
    }

    var voiceStatusLabel: String {
        if let voiceMessage, !voiceMessage.isEmpty { return voiceMessage }
        switch voiceState {
        case .off: return "Voice conversation off"
        case .unavailable: return "Voice conversation unavailable"
        case .connecting: return "Connecting voice conversation"
        case .greeting: return "Greeting"
        case .listening: return "Listening"
        case .speechDetected: return "Speech detected"
        case .transcribing: return "Transcribing"
        case .acknowledging: return "On it"
        case .processing: return "Working"
        case .waitingOnUser: return "Waiting for you"
        case .speakingProgress: return "Speaking progress"
        case .speakingResult: return "Speaking result"
        case .muted: return "Assistant speech muted"
        case .suspended: return "Voice conversation suspended"
        case .reconnecting: return "Reconnecting voice conversation"
        case .error: return "Voice conversation error"
        case .ended: return "Voice conversation ended"
        }
    }

    func attach(_ sync: WatchOverrideSync) {
        requestSink = { await sync.sendRelay($0) }
        sync.onRelay = { [weak self] in self?.receiveRelay($0) }
        sync.onContext = { [weak self] phone, chats in self?.receivePhoneContext(phone: phone, chats: chats) }
        sync.onRelayReachability = { [weak self] in self?.phoneReachable = $0 }
        sync.activate()
        phoneReachable = sync.reachable
    }

    func bindCompanionOwner(_ owner: CompanionVoiceOwner?) {
        guard companionOwner != owner else { return }
        stopPairedVoice()
        speaker.clear()
        companionOwner = owner
        resetChats()
    }

    func receivePhoneContext(phone: Data?, chats: Data?) {
        if let phone, let update = try? CompanionPhoneUpdate(data: phone) { apply(update) }
        if let chats, let update = try? CompanionPhoneUpdate(data: chats) {
            apply(update)
        } else if chats == nil {
            clearChatList()
        }
    }

    func receiveRelay(_ data: Data) {
        guard let update = try? CompanionPhoneUpdate(data: data) else { return }
        apply(update)
    }

    private func apply(_ update: CompanionPhoneUpdate) {
        switch update {
        case .phone(let owner, let state):
            bindCompanionOwner(owner)
            applyPhone(state)
        case .chats(let owner, let rows, let omitted):
            guard owner == companionOwner else { return }
            chats = rows
            omittedChats = omitted
            chatsLoaded = true
        case .chat(let owner, let chatId, let title, let view):
            guard owner == companionOwner, chatId == activeChatId else { return }
            activeChatTitle = title
            chatComponents = Self.components(for: view)
        case .run(let owner, let chatId, let state):
            guard owner == companionOwner, chatId == activeChatId else { return }
            runState = state
            if state == .failed { errorBanner = "Your iPhone couldn't run that. Try again." }
        }
    }

    private func applyPhone(_ state: CompanionPhoneState) {
        let next: Link
        switch state {
        case .ready: next = .ready
        case .noMesh: next = .noMesh
        case .stopped: next = .stopped
        }
        let becameReady = next == .ready && link != .ready
        link = next
        armResponseWatch()
        if next != .ready {
            clearChatList()
            clearOpenChat()
        } else if becameReady {
            refreshChats()
        }
    }

    private func clearChatList() {
        chats = []
        omittedChats = 0
        chatsLoaded = false
    }

    private func clearOpenChat() {
        activeChatId = nil
        activeChatTitle = ""
        chatComponents = []
        runState = .idle
        statusText = nil
        errorBanner = nil
        pendingDictation = ""
    }

    private func resetChats() {
        link = .waiting
        clearChatList()
        clearOpenChat()
        armResponseWatch()
    }

    func retryPhone() {
        armResponseWatch()
        refreshChats()
    }

    private func armResponseWatch() {
        responseWatch?.cancel()
        phoneNotResponding = false
        guard phoneReachable, link == .waiting else { return }
        let timeout = responseTimeout
        responseWatch = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.phoneReachable, self.link == .waiting else { return }
            self.phoneNotResponding = true
        }
    }

    func refreshChats() {
        guard let owner = companionOwner, phoneReachable else { return }
        send(.listChats(owner: owner))
    }

    func openChat(_ summary: CompanionChatSummary) {
        guard let owner = companionOwner else { return }
        activeChatId = summary.chatId
        activeChatTitle = summary.title
        chatComponents = []
        runState = .idle
        statusText = nil
        errorBanner = nil
        send(.openChat(owner: owner, chatId: summary.chatId))
    }

    func closeChat() {
        speaker.stop()
        clearOpenChat()
    }

    func sendPending() {
        let text = Self.dictationText(pendingDictation)
        guard !text.isEmpty else { return }
        guard let owner = companionOwner, let chatId = activeChatId, link == .ready else {
            errorBanner = "Open your mesh on your iPhone to send."
            return
        }
        guard text.count <= CompanionRelay.maximumMessageCharacters else {
            errorBanner = "That message is too long for your watch."
            return
        }
        errorBanner = nil
        statusText = "Sending to your iPhone…"
        send(.sendMessage(owner: owner, chatId: chatId, text: text)) { [weak self] delivered in
            guard let self else { return }
            if delivered {
                self.pendingDictation = ""
                self.statusText = "Sent to your iPhone"
            } else {
                self.statusText = nil
                self.errorBanner = "Your iPhone didn't get that. Try again."
            }
        }
    }

    func stopRun() {
        guard let owner = companionOwner, let chatId = activeChatId else { return }
        send(.stopRun(owner: owner, chatId: chatId))
    }

    private func send(_ request: CompanionWatchRequest, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let data = try? request.encoded(), let sink = requestSink else {
            completion?(false)
            return
        }
        Task { [weak self] in
            let delivered = await sink(data)
            guard self != nil else { return }
            completion?(delivered)
        }
    }

    nonisolated static func dictationText(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
        return mapped.joined().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    nonisolated static func components(for view: String) -> [AstralComponent] {
        view.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            var fields: [String: JSONValue] = ["type": .string("text"), "content": .string(String(line))]
            if line == "Open on your iPhone to see this." { fields["variant"] = .string("caption") }
            return AstralComponent(type: "text", raw: .object(fields))
        }
    }

    func performVoiceAction(_ action: String) {
        switch action {
        case "voice_session_start", "voice_session_takeover": beginPairedVoice(mode: .conversation)
        case "voice_session_end", "voice_microphone_set": stopPairedVoice()
        case "voice_speech_stop", "voice_speech_mute_set": voiceBridge.interruptPlayback()
        default: voiceMessage = "Use the paired iPhone for this voice control."
        }
    }

    func performPrimaryVoiceAction() {
        if companionVoiceActive { stopPairedVoice() } else { beginPairedVoice(mode: .conversation) }
    }

    func handleVoiceScenePhase(_ phase: ScenePhase) {
        voiceForegroundActive = phase == .active
        voiceBridge.setForeground(voiceForegroundActive)
        if !voiceForegroundActive { stopPairedVoice() }
    }

    private func beginPairedVoice(mode: CompanionVoiceActivation.Mode, text: String? = nil) {
        guard voiceForegroundActive, let owner = companionOwner else {
            voiceState = .unavailable
            voiceReason = "phone_owner_unavailable"
            voiceMessage = "Open your mesh on your iPhone."
            return
        }
        stopPairedVoice()
        let attempt = UUID()
        companionVoiceAttempt = attempt
        voiceActivationBusy = true
        voiceState = .connecting
        voiceMessage = "Preparing voice on iPhone…"
        let activation = CompanionVoiceActivation(owner: owner, mode: mode, text: text)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voiceBridge.startCompanion(
                    activation,
                    onState: { [weak self] state in
                        guard let self, self.companionVoiceAttempt == attempt, self.companionOwner == owner
                        else { return }
                        self.pairedVoiceStateChanged(state)
                    },
                    onTranscript: { [weak self] text, final in
                        guard let self, self.companionVoiceAttempt == attempt, self.companionOwner == owner
                        else { return }
                        self.voicePartialTranscript = text
                        self.voiceState = final ? .processing : .transcribing
                    },
                    onSpeaking: { [weak self] speaking in
                        guard let self, self.companionVoiceAttempt == attempt, self.companionOwner == owner
                        else { return }
                        self.speaker.playbackChanged(speaking)
                        if speaking {
                            self.voiceState = .speakingResult
                        } else if self.voiceBridge.companionActive {
                            self.voiceState = .listening
                        }
                    })
            } catch {
                guard self.companionVoiceAttempt == attempt, self.companionOwner == owner else { return }
                self.voiceActivationBusy = false
                self.voiceState = .unavailable
                if self.voiceMessage == "Preparing voice on iPhone…" {
                    self.voiceMessage = Self.pairedVoiceMessage("phone_unreachable")
                }
            }
        }
    }

    private func pairedVoiceStateChanged(_ state: WatchVoiceBridgeState) {
        switch state {
        case .connecting:
            voiceState = .connecting
        case .ready:
            voiceActivationBusy = false
            voiceState = .listening
            voiceReason = "ready"
            let title = voiceBridge.companionConversation?.title ?? "Current conversation"
            voiceMessage = "iPhone: \(title)"
        case .failed(let reason):
            voiceActivationBusy = false
            voiceState = .unavailable
            voiceReason = reason
            voiceMessage = Self.pairedVoiceMessage(reason)
        case .ended, .idle:
            voiceActivationBusy = false
            voiceState = .ended
            voiceMessage = nil
            voicePartialTranscript = nil
        case .reconnecting:
            voiceActivationBusy = false
            voiceState = .unavailable
            voiceMessage = Self.pairedVoiceMessage("phone_unreachable")
        }
    }

    private func stopPairedVoice() {
        companionVoiceAttempt = UUID()
        voiceBridge.disconnect(reason: "owner_stopped")
        voiceActivationBusy = false
        voiceState = .ended
        voiceMessage = nil
        voicePartialTranscript = nil
        speaker.playbackChanged(false)
    }

    private static func pairedVoiceMessage(_ reason: String) -> String {
        switch reason {
        case "phone_mesh_binding_unavailable":
            return "Open the mesh this Watch belongs to on your iPhone."
        case "phone_model_required": return "Download the voice model in AstralDeep on your iPhone."
        case "phone_owner_unavailable", "phone_context_unavailable":
            return "Open the mesh this Watch belongs to on your iPhone."
        case "permission_denied": return "Allow microphone access on your Watch to use voice."
        case "audio_interrupted", "audio_backpressure", "invalid_audio", "invalid_sequence":
            return "Watch audio stopped. Start voice again."
        case "phone_voice_unavailable":
            return "On-device voice could not start on your iPhone. Open the app and try again."
        default: return "Open AstralDeep on your paired iPhone, then start voice again."
        }
    }
}
