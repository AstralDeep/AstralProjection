// Runs paired-Watch voice through the phone's installed model and existing scoped kernel link.
// Every activation and packet remains bound to a verified owner and current conversation; companion text can never approve an action.

import AstralCore
import Foundation

@MainActor
final class PairedWatchVoiceRelay {
    typealias Prepare = @MainActor (CompanionVoiceOwner) async throws -> PairedWatchVoiceContext
    typealias IsCurrent = @MainActor (PairedWatchVoiceContext) async -> Bool
    typealias Inference = @Sendable (URL) async throws -> any VoiceModelInference
    private let controller: OnDeviceVoiceController
    private let channel: any CompanionVoiceChannel
    private let inference: Inference
    private var prepare: Prepare?
    private var isCurrent: IsCurrent?
    private var session: UUID?
    private var gate: CompanionVoiceSequenceGate?
    private var sender: CompanionVoiceSender?
    private var context: PairedWatchVoiceContext?
    private var mode = CompanionVoiceActivation.Mode.conversation
    private var preparation: Task<Void, Never>?
    private var audio: PairedWatchVoiceAudio?
    private var inputLink: PairedWatchInputLink?
    private var admission: Task<Void, Never>?
    private var admissionDeadline: Task<Void, Never>?
    private var lifetime: Task<Void, Never>?
    private var activations: [UUID: ContinuousClock.Instant] = [:]
    private var candidate: UUID?
    private var candidateGate: CompanionVoiceSequenceGate?

    init(
        controller: OnDeviceVoiceController, channel: any CompanionVoiceChannel,
        inference: @escaping Inference = { try await VoiceInferenceCache.shared.inference(directory: $0) }
    ) {
        self.controller = controller
        self.channel = channel
        self.inference = inference
        channel.onPacket = { [weak self] packet in
            guard let self else { throw CompanionVoiceError.notReachable }
            do { try await self.receive(packet) } catch {
                if packet.kind != .start, packet.session == self.session { self.stop() }
                throw error
            }
        }
        channel.onReachabilityChanged = { [weak self] reachable in if !reachable { self?.stop() } }
        controller.onSessionStopped = { [weak self] in
            if self?.session != nil { self?.stop() }
        }
    }

    func bind(prepare: @escaping Prepare, isCurrent: @escaping IsCurrent) {
        stop()
        self.prepare = prepare
        self.isCurrent = isCurrent
    }

    func unbind() {
        stop()
        prepare = nil
        isCurrent = nil
    }

    func stop(cancelCandidate: Bool = true) {
        if cancelCandidate {
            candidate = nil
            candidateGate = nil
            admission?.cancel()
            admission = nil
            admissionDeadline?.cancel()
            admissionDeadline = nil
        }
        guard session != nil else { return }
        let previous = sender
        session = nil
        gate = nil
        context = nil
        sender = nil
        preparation?.cancel()
        preparation = nil
        lifetime?.cancel()
        lifetime = nil
        controller.onTranscript = nil
        controller.stop()
        audio = nil
        inputLink = nil
        Task {
            try? await previous?.send(.stop)
            previous?.retire()
        }
    }

    private func receive(_ packet: CompanionVoicePacket) async throws {
        if packet.kind == .start {
            guard packet.sequence == 0, let activation = CompanionVoiceActivation(data: packet.payload)
            else { throw CompanionVoiceError.invalidPacket }
            let now = ContinuousClock.now
            activations = activations.filter { $0.value.duration(to: now) < .seconds(3_600) }
            guard candidate == nil, activations.count < 128, activations[packet.session] == nil,
                packet.session != session, let prepare
            else { throw CompanionVoiceError.rejected }
            activations[packet.session] = now
            candidate = packet.session
            candidateGate = CompanionVoiceSequenceGate(session: packet.session)
            _ = candidateGate?.accept(packet)
            admissionDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                self?.rejectCandidate(packet.session, reason: "phone_voice_unavailable")
            }
            admission = Task { [weak self] in
                guard let self else { return }
                do {
                    let context = try await prepare(activation.owner)
                    try Task.checkCancellation()
                    guard self.candidate == packet.session, context.owner == activation.owner, self.channel.reachable,
                        await self.current(context), self.candidate == packet.session
                    else {
                        throw CompanionVoiceError.rejected
                    }
                    self.candidate = nil
                    self.candidateGate = nil
                    self.admissionDeadline?.cancel()
                    self.admissionDeadline = nil
                    self.start(packet, activation: activation, context: context)
                } catch {
                    self.rejectCandidate(packet.session, reason: "phone_owner_unavailable")
                }
            }
            return
        }
        if packet.session == candidate {
            guard packet.kind == .stop, candidateGate?.accept(packet) == true else {
                throw CompanionVoiceError.rejected
            }
            candidate = nil
            candidateGate = nil
            admission?.cancel()
            admission = nil
            admissionDeadline?.cancel()
            admissionDeadline = nil
            return
        }
        guard packet.session == session else { throw CompanionVoiceError.rejected }
        guard gate?.accept(packet) == true else {
            stop()
            throw CompanionVoiceError.invalidSequence
        }
        if packet.kind == .stop {
            stop(cancelCandidate: false)
            return
        }
        guard let context, await current(context), packet.session == session, controller.isRunning, let audio
        else {
            await fail("phone_context_unavailable", session: packet.session)
            throw CompanionVoiceError.rejected
        }
        switch packet.kind {
        case .capture:
            guard mode == .conversation else { throw CompanionVoiceError.rejected }
            try audio.receiveCapture(packet.payload)
        case .playbackStarted, .playbackFinished: try audio.receivePlayback(packet)
        case .stopSpeech:
            guard let id = UUID(uuidString: String(decoding: packet.payload, as: UTF8.self)) else {
                throw CompanionVoiceError.invalidPacket
            }
            if audio.stopSpeaking(id: id) { stop() }
        default: throw CompanionVoiceError.invalidPacket
        }
    }

    private func rejectCandidate(_ session: UUID, reason: String) {
        guard candidate == session else { return }
        candidate = nil
        candidateGate = nil
        admission?.cancel()
        admission = nil
        admissionDeadline?.cancel()
        admissionDeadline = nil
        let response = CompanionVoiceSender(channel: channel, session: session)
        Task {
            try? await response.send(.failure, payload: Data(reason.utf8))
            response.retire()
        }
    }

    private func start(
        _ packet: CompanionVoicePacket, activation: CompanionVoiceActivation, context: PairedWatchVoiceContext
    ) {
        stop(cancelCandidate: false)
        controller.stop()
        session = packet.session
        gate = CompanionVoiceSequenceGate(session: packet.session)
        _ = gate?.accept(packet)
        sender = CompanionVoiceSender(channel: channel, session: packet.session)
        mode = activation.mode
        self.context = context
        lifetime = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
            if self?.session == packet.session { self?.stop() }
        }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.prepare != nil, self.channel.reachable else {
                    await self.fail("phone_context_unavailable", session: packet.session)
                    return
                }
                guard self.session == packet.session, context.owner == activation.owner, await self.current(context),
                    self.session == packet.session
                else { throw CompanionVoiceError.rejected }
                try Task.checkCancellation()
                guard self.controller.store?.state == .installed else {
                    await self.fail("phone_model_required", session: packet.session)
                    return
                }
                self.controller.onTranscript = { [weak self] text, final in
                    Task {
                        try? await self?.send(
                            final ? .finalTranscript : .partialTranscript, Data(text.utf8), session: packet.session)
                    }
                }
                await self.controller.activateForPairedWatch { [weak self] directory, base in
                    guard let self, await self.current(context), self.session == packet.session else {
                        throw CompanionVoiceError.rejected
                    }
                    let inference = try await self.inference(directory)
                    try Task.checkCancellation()
                    guard await self.current(context), self.session == packet.session else {
                        throw CompanionVoiceError.rejected
                    }
                    let audio = PairedWatchVoiceAudio(inference: inference) { [weak self] kind, payload in
                        guard let self else { throw CompanionVoiceError.notReachable }
                        try await self.send(kind, payload, session: packet.session)
                    }
                    audio.onPlaybackFinished = { [weak self] in
                        guard let self, self.session == packet.session, self.mode == .playback else { return }
                        self.stop()
                    }
                    let link = PairedWatchInputLink(
                        base: base, context: context,
                        current: { [weak self] in
                            guard let self, self.mode == .conversation, self.session == packet.session else {
                                return false
                            }
                            guard await self.current(context), self.session == packet.session,
                                self.mode == .conversation
                            else { return false }
                            return true
                        },
                        invalidated: { [weak self] in
                            if self?.session == packet.session { self?.stop() }
                        })
                    self.audio = audio
                    self.inputLink = link
                    return VoicePipeline(
                        audio: audio, transcriber: MLXVoiceTranscriber(inference: inference),
                        fastPath: VoiceFastPath(model: MLXVoiceAcknowledgementModel(inference: inference)),
                        link: link, source: .pairedWatchMicrophone)
                }
                try Task.checkCancellation()
                guard self.controller.isRunning, await self.current(context), self.session == packet.session else {
                    await self.fail("phone_voice_unavailable", session: packet.session)
                    return
                }
                try await self.send(
                    .ready, CompanionVoiceConversation(chatId: context.chatId, title: context.title).encoded(),
                    session: packet.session)
                try Task.checkCancellation()
                guard self.session == packet.session else { return }
                if let text = activation.text, activation.mode == .playback { self.audio?.speak(index: 0, text: text) }
            } catch is CancellationError {
            } catch {
                if self.session == packet.session {
                    await self.fail("phone_owner_unavailable", session: packet.session)
                }
            }
        }
    }

    private func current(_ context: PairedWatchVoiceContext) async -> Bool {
        guard let isCurrent else { return false }
        return await isCurrent(context)
    }

    private func send(_ kind: CompanionVoicePacket.Kind, _ payload: Data, session: UUID) async throws {
        guard self.session == session, let context, let sender, await current(context), self.session == session else {
            throw CompanionVoiceError.rejected
        }
        try await sender.send(kind, payload: payload)
    }

    private func fail(_ reason: String, session: UUID) async {
        guard self.session == session else { return }
        let sender = sender
        try? await sender?.send(.failure, payload: Data(reason.utf8))
        if self.session == session { stop() }
    }
}

@MainActor
private final class PairedWatchInputLink: VoiceKernelLink {
    private let base: VoiceKernelLink
    private let current: @MainActor () async -> Bool
    private let invalidated: @MainActor () -> Void

    init(
        base: VoiceKernelLink, context: PairedWatchVoiceContext,
        current: @escaping @MainActor () async -> Bool, invalidated: @escaping @MainActor () -> Void
    ) {
        self.base = base
        self.current = current
        self.invalidated = invalidated
    }

    func prepareForOwnerSession() async throws {
        guard await current() else { throw CompanionVoiceError.rejected }
        try await base.prepareForOwnerSession()
        guard await current() else { throw CompanionVoiceError.rejected }
    }

    func submit(turn: OwnerVoiceTurn) {
        Task {
            guard turn.source == .pairedWatchMicrophone, turn.integrity == .owner, !turn.approvalEligible,
                await current()
            else {
                invalidated()
                return
            }
            base.submit(turn: turn)
        }
    }

    func cancelTurn() { base.cancelTurn() }
    func cancelTool(id: String) { base.cancelTool(id: id) }
    func record(spoken: VoiceSpokenRecord) {
        Task { if await current() { base.record(spoken: spoken) } }
    }
}
