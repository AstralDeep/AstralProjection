// Connects the on-device voice pipeline to MeshRuntime: a final owner transcript becomes a message and a turn, and spoken text flows back as the turn streams.
// Transcripts that did not come from the device microphone in an owner-started session are refused, and nothing here can approve an action.

import Foundation

nonisolated struct MeshVoiceScope: Equatable, Sendable {
    let chatId: String
    let session: UUID
}

@MainActor
final class MeshVoiceLink: VoiceKernelLink {
    private weak var runtime: MeshRuntime?
    private var scope: MeshVoiceScope?

    init(runtime: MeshRuntime) {
        self.runtime = runtime
    }

    func prepareForOwnerSession() async throws {
        guard let runtime else { throw MeshKernelError.unavailable("Open your mesh before starting voice.") }
        scope = try await runtime.prepareVoiceSession()
    }

    func submit(turn: OwnerVoiceTurn) {
        guard let runtime else { return }
        let scope = scope
        Task { await runtime.submitVoice(turn, scope: scope) }
    }

    func cancelTurn() {
        guard let runtime else { return }
        let scope = scope
        Task { await runtime.interruptVoice(scope: scope) }
    }

    func cancelTool(id: String) {
        guard let runtime else { return }
        let scope = scope
        Task { await runtime.cancelVoiceTool(id: id, scope: scope) }
    }

    func record(spoken: VoiceSpokenRecord) {
        guard let runtime else { return }
        let scope = scope
        Task { await runtime.recordSpoken(spoken, scope: scope) }
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

}
