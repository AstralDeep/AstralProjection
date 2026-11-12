// Fakes for the on-device voice tests: a manual clock, scripted audio, transcriber, kernel link and model.
// They let pipeline, barge-in and fast-path logic run deterministically with no microphone, speaker or system model.

import AVFoundation
import Foundation
import XCTest

@testable import AstralDeep

final class ManualVoiceClock: VoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100

    var now: TimeInterval { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@MainActor
final class FakeDuplexAudio: VoiceDuplexAudio {
    var onEvent: ((VoiceSpeechEvent) -> Void)?
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var spoken: [(index: Int, text: String)] = []
    var volumes: [Float] = []
    var stopSpeakingCount = 0
    var started = false
    var stopped = false
    var progress: VoiceSpeechProgress?

    func start() throws { started = true }
    func stop() { stopped = true }
    func speak(index: Int, text: String) { spoken.append((index, text)) }
    func stopSpeaking() { stopSpeakingCount += 1 }
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func playedProgress() -> VoiceSpeechProgress? { progress }
}

final class FakeTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    let kind = VoiceTranscriberKind.onDeviceRecognizer
    private let lock = NSLock()
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var shutdowns = 0

    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void) {}
    func prepare() async throws {}
    func beginSegment() throws { lock.withLock { begun += 1 } }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func endSegment() { lock.withLock { ended += 1 } }
    func cancelSegment() {}
    func shutdown() { lock.withLock { shutdowns += 1 } }
}

final class FakeKernelLink: VoiceKernelLink {
    var turns: [OwnerVoiceTurn] = []
    var cancelledTurns = 0
    var cancelledTools: [String] = []
    var spoken: [VoiceSpokenRecord] = []

    func submit(turn: OwnerVoiceTurn) { turns.append(turn) }
    func cancelTurn() { cancelledTurns += 1 }
    func cancelTool(id: String) { cancelledTools.append(id) }
    func record(spoken record: VoiceSpokenRecord) { spoken.append(record) }
}

final class FakeOnDeviceModel: AstralOnDeviceModel, @unchecked Sendable {
    enum Mode {
        case respond(OnDeviceResponse)
        case hang
    }

    private let lock = NSLock()
    private var isUp: Bool
    private var mode: Mode
    private var requestLog: [OnDeviceRequest] = []
    private var cancellations = 0

    init(available: Bool = true, mode: Mode = .respond(.text("Sure."))) {
        isUp = available
        self.mode = mode
    }

    var requests: [OnDeviceRequest] { lock.withLock { requestLog } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func available() -> Bool { lock.withLock { isUp } }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        let current = lock.withLock { () -> Mode in
            requestLog.append(request)
            return mode
        }
        switch current {
        case .respond(let response):
            return response
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { cancellations += 1 }
            return .failed(.cancelled)
        }
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
