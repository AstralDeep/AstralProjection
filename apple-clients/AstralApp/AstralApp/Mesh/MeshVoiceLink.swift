// Connects the on-device voice pipeline to MeshRuntime: a final owner transcript becomes a message and a turn, and spoken text flows back as the turn streams.
// Transcripts that did not come from the device microphone in an owner-started session are refused, and nothing here can approve an action.

import Foundation

@MainActor
final class MeshVoiceLink: VoiceKernelLink {
    private weak var runtime: MeshRuntime?

    init(runtime: MeshRuntime) {
        self.runtime = runtime
    }

    func submit(turn: OwnerVoiceTurn) {
        guard let runtime else { return }
        Task { await runtime.submitVoice(turn) }
    }

    func cancelTurn() {
        guard let runtime else { return }
        Task { await runtime.interruptVoice() }
    }

    func cancelTool(id: String) {
        guard let runtime else { return }
        Task { await runtime.cancelVoiceTool(id: id) }
    }

    func record(spoken: VoiceSpokenRecord) {
        guard let runtime else { return }
        Task { await runtime.recordSpoken(spoken) }
    }
}

extension MeshRuntime {
    func attachVoice(_ controller: OnDeviceVoiceController) {
        speechSink = controller
        controller.connect(link: MeshVoiceLink(runtime: self))
    }

    func detachVoice(_ controller: OnDeviceVoiceController) {
        controller.disconnect()
        speechSink = nil
    }

    func interruptVoice() async {
        guard let chatId = voiceChatId ?? currentChatId else { return }
        await interrupt(chatId: chatId)
    }
}
