// Captures and plays ephemeral PCM through the paired iPhone's on-device voice pipeline.
// Session, sequence and playback fences prevent retired audio from reaching another conversation; there is no hosted or system-speech fallback.

import AVFoundation
import AstralCore
import Foundation
import Observation

enum WatchVoiceBridgeState: Equatable, Sendable {
    case idle, connecting, ready, reconnecting
    case failed(String)
    case ended
}

enum WatchVoiceAudioEvent: Equatable, Sendable {
    case interrupted(String)
    case recovered
}

@MainActor
protocol WatchVoiceBridgeControlling: AnyObject {
    var state: WatchVoiceBridgeState { get }
    var microphonePermission: WatchVoicePermission { get }
    var companionActive: Bool { get }
    var companionConversation: CompanionVoiceConversation? { get }
    func requestMicrophonePermission() async -> WatchVoicePermission
    func startCompanion(
        _ activation: CompanionVoiceActivation,
        onState: @escaping @MainActor (WatchVoiceBridgeState) -> Void,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onSpeaking: @escaping @MainActor (Bool) -> Void) async throws
    func setForeground(_ foreground: Bool)
    func setCaptureEnabled(_ enabled: Bool)
    func interruptPlayback()
    func disconnect(reason: String)
}

extension WatchVoiceBridgeControlling {
    var companionActive: Bool { false }
    var companionConversation: CompanionVoiceConversation? { nil }
    func setForeground(_ foreground: Bool) { if !foreground { disconnect(reason: "background") } }
    func startCompanion(
        _ activation: CompanionVoiceActivation,
        onState: @escaping @MainActor (WatchVoiceBridgeState) -> Void,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onSpeaking: @escaping @MainActor (Bool) -> Void
    ) async throws {
        throw CompanionVoiceError.notReachable
    }
}

@MainActor
protocol WatchVoiceAudioIO: AnyObject {
    var microphonePermission: WatchVoicePermission { get }
    func requestMicrophonePermission() async -> WatchVoicePermission
    func setEventHandler(_ handler: @escaping @MainActor (WatchVoiceAudioEvent) -> Void)
    func prepare(capture: Bool) throws
    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws
    func stopCapture()
    func enqueuePlayback(
        _ pcm: Data, startsAnnouncement: Bool, endsAnnouncement: Bool,
        onStarted: @escaping @MainActor () -> Void, onFinished: @escaping @MainActor () -> Void) throws
    func setVolume(_ volume: Float)
    func stopPlayback()
    func stop()
}

private nonisolated final class WatchVoiceCaptureMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    private var scheduled = false
    private var retired = false
    private let receive: @MainActor (Data, Bool) -> Void

    init(receive: @escaping @MainActor (Data, Bool) -> Void) { self.receive = receive }

    func append(_ next: Data) {
        let schedule = lock.withLock { () -> Bool in
            guard !retired else { return false }
            if next.count > 12_800 - bytes.count { overflow = true } else if !overflow { bytes.append(next) }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pending = self.lock.withLock { () -> (Data, Bool) in
                    self.scheduled = false
                    let result = (self.bytes, self.overflow || self.retired)
                    self.bytes.removeAll()
                    return result
                }
                self.receive(pending.0, pending.1)
            }
        }
    }

    func retire() {
        lock.withLock {
            retired = true
            bytes.removeAll()
        }
    }
}

@MainActor
@Observable
final class WatchVoiceBridge: WatchVoiceBridgeControlling {
    private let audio: any WatchVoiceAudioIO
    private let channel: any CompanionVoiceChannel
    private var session: UUID?
    private var gate: CompanionVoiceSequenceGate?
    private var sender: CompanionVoiceSender?
    private var mode = CompanionVoiceActivation.Mode.conversation
    private var foreground = true
    private var generation = 0
    private var captureEnabled = false
    private var mailbox: WatchVoiceCaptureMailbox?
    private var captureEpoch = UUID()
    private var captureRemainder = Data()
    private var captureQueue: [Data] = []
    private var captureSending: Task<Void, Never>?
    private var preparing: Task<Void, Never>?
    private var lifetime: Task<Void, Never>?
    private var speech: CompanionVoiceSpeech?
    private var speechBytes = 0
    private var stateHandler: (@MainActor (WatchVoiceBridgeState) -> Void)?
    private var transcriptHandler: (@MainActor (String, Bool) -> Void)?
    private var speakingHandler: (@MainActor (Bool) -> Void)?
    private(set) var state = WatchVoiceBridgeState.idle
    private(set) var companionConversation: CompanionVoiceConversation?
    var companionActive: Bool { session != nil }
    var microphonePermission: WatchVoicePermission { audio.microphonePermission }

    convenience init() { self.init(audio: WatchVoiceAudioEngine(), channel: WatchOverrideSync.shared) }

    init(audio: any WatchVoiceAudioIO, channel: any CompanionVoiceChannel) {
        self.audio = audio
        self.channel = channel
        audio.setEventHandler { [weak self] event in
            if case .interrupted = event { self?.end(.failed("audio_interrupted")) }
        }
        channel.onPacket = { [weak self] packet in
            guard let self else { throw CompanionVoiceError.notReachable }
            do { try self.receive(packet) } catch {
                if packet.session == self.session { self.end(.failed("invalid_audio")) }
                throw error
            }
        }
        channel.onReachabilityChanged = { [weak self] reachable in
            if !reachable { self?.end(.failed("phone_unreachable")) }
        }
    }

    func requestMicrophonePermission() async -> WatchVoicePermission { await audio.requestMicrophonePermission() }

    func startCompanion(
        _ activation: CompanionVoiceActivation,
        onState: @escaping @MainActor (WatchVoiceBridgeState) -> Void,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onSpeaking: @escaping @MainActor (Bool) -> Void
    ) async throws {
        disconnect(reason: "replacement")
        stateHandler = onState
        transcriptHandler = onTranscript
        speakingHandler = onSpeaking
        let token = generation
        guard foreground, channel.reachable else {
            end(.failed("phone_unreachable"))
            throw CompanionVoiceError.notReachable
        }
        setState(.connecting)
        if activation.mode == .conversation {
            let permission = await audio.requestMicrophonePermission()
            guard permission == .authorized else {
                end(.failed("permission_denied"))
                throw CompanionVoiceError.rejected
            }
        }
        guard generation == token, foreground, channel.reachable else { throw CompanionVoiceError.notReachable }
        let session = UUID()
        self.session = session
        self.mode = activation.mode
        gate = CompanionVoiceSequenceGate(session: session)
        let sender = CompanionVoiceSender(channel: channel, session: session)
        self.sender = sender
        preparing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self, self.session == session, self.state == .connecting else { return }
            self.end(.failed("phone_voice_unavailable"))
        }
        do { try await sender.send(.start, payload: activation.encoded()) } catch {
            end(.failed((error as? CompanionVoiceError) == .rejected ? "phone_owner_unavailable" : "phone_unreachable"))
            throw error
        }
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        if !foreground { end(.ended) }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        stopCapture()
        captureEnabled = enabled && state == .ready && mode == .conversation && foreground
        guard captureEnabled, speech == nil else { return }
        let epoch = UUID()
        captureEpoch = epoch
        let mailbox = WatchVoiceCaptureMailbox { [weak self] bytes, overflow in
            guard let self, self.captureEpoch == epoch, self.captureEnabled else { return }
            if overflow {
                self.end(.failed("audio_backpressure"))
                return
            }
            self.queueCapture(bytes, epoch: epoch)
        }
        self.mailbox = mailbox
        do { try audio.startCapture { mailbox.append($0) } } catch { end(.failed("audio_interrupted")) }
    }

    private func stopCapture() {
        captureEnabled = false
        captureEpoch = UUID()
        mailbox?.retire()
        mailbox = nil
        audio.stopCapture()
        captureRemainder.removeAll()
        captureQueue.removeAll()
        captureSending?.cancel()
        captureSending = nil
    }

    private func queueCapture(_ bytes: Data, epoch: UUID) {
        guard bytes.count.isMultiple(of: 2), bytes.count <= 12_800 else {
            end(.failed("invalid_audio"))
            return
        }
        captureRemainder.append(bytes)
        while captureRemainder.count >= 3_200 {
            guard captureQueue.count < 4 else {
                end(.failed("audio_backpressure"))
                return
            }
            captureQueue.append(Data(captureRemainder.prefix(3_200)))
            captureRemainder.removeFirst(3_200)
        }
        guard captureSending == nil, let sender else { return }
        captureSending = Task { [weak self] in
            guard let self else { return }
            defer { if self.captureEpoch == epoch { self.captureSending = nil } }
            do {
                while self.captureEnabled, self.captureEpoch == epoch, !self.captureQueue.isEmpty {
                    try Task.checkCancellation()
                    let pcm = self.captureQueue.removeFirst()
                    try await sender.send(.capture, payload: pcm)
                }
            } catch is CancellationError {
            } catch { if self.captureEpoch == epoch { self.end(.failed("phone_unreachable")) } }
        }
    }

    private func receive(_ packet: CompanionVoicePacket) throws {
        guard packet.session == session else { throw CompanionVoiceError.rejected }
        guard gate?.accept(packet) == true else {
            end(.failed("invalid_sequence"))
            throw CompanionVoiceError.invalidSequence
        }
        switch packet.kind {
        case .ready:
            guard state == .connecting, let conversation = CompanionVoiceConversation(data: packet.payload) else {
                throw CompanionVoiceError.invalidPacket
            }
            companionConversation = conversation
            preparing?.cancel()
            preparing = nil
            let session = packet.session
            lifetime = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                if self?.session == session { self?.end(.ended) }
            }
            try audio.prepare(capture: mode == .conversation)
            setState(.ready)
            setCaptureEnabled(mode == .conversation)
        case .speechStart:
            guard state == .ready, speech == nil, let speech = CompanionVoiceSpeech(data: packet.payload) else {
                throw CompanionVoiceError.invalidPacket
            }
            stopCapture()
            self.speech = speech
            speechBytes = 0
            audio.setVolume(1)
        case .speechPCM:
            guard let speech, speechBytes + packet.payload.count <= speech.frames * 2 else {
                throw CompanionVoiceError.invalidPacket
            }
            let starts = speechBytes == 0
            speechBytes += packet.payload.count
            let ends = speechBytes == speech.frames * 2
            try audio.enqueuePlayback(
                packet.payload, startsAnnouncement: starts, endsAnnouncement: ends,
                onStarted: { [weak self] in self?.playbackStarted(speech) },
                onFinished: { [weak self] in self?.playbackFinished(speech) })
        case .partialTranscript, .finalTranscript:
            guard state == .ready, mode == .conversation, let text = String(data: packet.payload, encoding: .utf8)
            else { throw CompanionVoiceError.invalidPacket }
            transcriptHandler?(text, packet.kind == .finalTranscript)
        case .stopSpeech:
            if speech?.id == UUID(uuidString: String(decoding: packet.payload, as: UTF8.self)) {
                stopPlayback(notify: false)
            }
        case .volume:
            if speech?.id == UUID(uuidString: String(decoding: packet.payload.prefix(36), as: UTF8.self)),
                let value = packet.payload.last
            {
                audio.setVolume(Float(value) / 100)
            }
        case .stop: end(.ended, notify: false)
        case .failure:
            let reason = String(data: packet.payload, encoding: .utf8) ?? "phone_voice_unavailable"
            end(.failed(reason), notify: false)
        default: throw CompanionVoiceError.invalidPacket
        }
    }

    private func playbackStarted(_ speech: CompanionVoiceSpeech) {
        guard self.speech?.id == speech.id else { return }
        speakingHandler?(true)
        let sender = sender
        Task { try? await sender?.send(.playbackStarted, payload: Data(speech.id.uuidString.utf8)) }
    }

    private func playbackFinished(_ speech: CompanionVoiceSpeech) {
        guard self.speech?.id == speech.id, speechBytes == speech.frames * 2 else { return }
        self.speech = nil
        speechBytes = 0
        speakingHandler?(false)
        let sender = sender
        Task { try? await sender?.send(.playbackFinished, payload: Data(speech.id.uuidString.utf8)) }
        setCaptureEnabled(mode == .conversation)
    }

    func interruptPlayback() { stopPlayback(notify: true) }

    private func stopPlayback(notify: Bool) {
        let previous = speech
        audio.stopPlayback()
        speech = nil
        speechBytes = 0
        speakingHandler?(false)
        let sender = sender
        if notify, let previous {
            Task { try? await sender?.send(.stopSpeech, payload: Data(previous.id.uuidString.utf8)) }
        } else if notify, mode == .playback {
            end(.ended)
            return
        }
        if state == .ready { setCaptureEnabled(mode == .conversation) }
    }

    func disconnect(reason: String) { end(.ended) }

    private func end(_ state: WatchVoiceBridgeState, notify: Bool = true) {
        let previous = sender
        generation &+= 1
        session = nil
        sender = nil
        gate = nil
        preparing?.cancel()
        preparing = nil
        lifetime?.cancel()
        lifetime = nil
        stopCapture()
        audio.stop()
        speech = nil
        speechBytes = 0
        companionConversation = nil
        speakingHandler?(false)
        setState(state)
        Task {
            if notify { try? await previous?.send(.stop) }
            previous?.retire()
        }
    }

    private func setState(_ next: WatchVoiceBridgeState) {
        state = next
        stateHandler?(next)
    }
}

enum WatchVoiceBridgeError: Error, Equatable, Sendable {
    case expiredGrant, invalidHandshake, invalidControl, invalidAudio, notReady, networkFailure, audioFailure,
        serverFailure
    var safeReason: String { "phone_voice_unavailable" }
}
@MainActor
final class WatchVoiceAudioEngine: WatchVoiceAudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false)!
    private var captureProcessor: WatchVoiceCaptureProcessor?
    private var captureInstalled = false
    private var playbackRunning = false
    private var eventHandler: (@MainActor (WatchVoiceAudioEvent) -> Void)?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                Task { @MainActor [weak self] in
                    self?.eventHandler?(
                        type == .began ? .interrupted("audio_interrupted") : .recovered)
                }
            })
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                    let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
                else { return }
                let event: WatchVoiceAudioEvent?
                switch reason {
                case .oldDeviceUnavailable, .noSuitableRouteForCategory:
                    event = .interrupted("route_unavailable")
                case .newDeviceAvailable:
                    event = .recovered
                default:
                    event = nil
                }
                guard let event else { return }
                Task { @MainActor [weak self] in self?.eventHandler?(event) }
            })
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func setEventHandler(_ handler: @escaping @MainActor (WatchVoiceAudioEvent) -> Void) {
        eventHandler = handler
    }

    var microphonePermission: WatchVoicePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestMicrophonePermission() async -> WatchVoicePermission {
        if microphonePermission != .notDetermined { return microphonePermission }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        return granted ? .authorized : .denied
    }

    func prepare(capture: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            capture ? .playAndRecord : .playback, mode: capture ? .voiceChat : .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        engine.prepare()
        if !engine.isRunning { try engine.start() }
    }

    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws {
        guard microphonePermission == .authorized else { throw WatchVoiceBridgeError.audioFailure }
        if captureInstalled { return }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let processor = WatchVoiceCaptureProcessor(inputFormat: inputFormat)
        else { throw WatchVoiceBridgeError.audioFailure }
        captureProcessor = processor
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { buffer, _ in
            processor.consume(buffer, handler: handler)
        }
        captureInstalled = true
        if !engine.isRunning { try engine.start() }
    }

    func stopCapture() {
        guard captureInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureInstalled = false
        captureProcessor = nil
    }

    func enqueuePlayback(
        _ pcm: Data,
        startsAnnouncement: Bool,
        endsAnnouncement: Bool,
        onStarted: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor () -> Void
    ) throws {
        let frames = pcm.count / 2
        guard !pcm.isEmpty, pcm.count <= 4_800, pcm.count.isMultiple(of: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
            let channel = buffer.int16ChannelData?[0]
        else { throw WatchVoiceBridgeError.audioFailure }
        _ = pcm.copyBytes(to: UnsafeMutableBufferPointer(start: channel, count: frames))
        buffer.frameLength = AVAudioFrameCount(frames)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            guard endsAnnouncement else { return }
            Task { @MainActor in onFinished() }
        }
        if startsAnnouncement {
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying { player.play() }
            playbackRunning = true
            onStarted()
        }
    }

    func setVolume(_ volume: Float) { player.volume = max(0, min(1, volume)) }

    func stopPlayback() {
        if player.isPlaying { player.stop() }
        player.reset()
        playbackRunning = false
    }

    func stop() {
        stopCapture()
        stopPlayback()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation)
    }
}

private final class WatchVoiceCaptureProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var pending = Data()

    init?(inputFormat: AVAudioFormat) {
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        outputFormat = output
        self.converter = converter
    }

    func consume(_ input: AVAudioPCMBuffer, handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let ratio = outputFormat.sampleRate / max(1, input.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error,
            output.frameLength > 0, let samples = output.int16ChannelData?[0]
        else { return }
        pending.append(
            UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        while pending.count >= WatchVoicePCMFrame.capturePayloadLength {
            let frame = Data(pending.prefix(WatchVoicePCMFrame.capturePayloadLength))
            pending.removeFirst(WatchVoicePCMFrame.capturePayloadLength)
            handler(frame)
        }
    }
}
