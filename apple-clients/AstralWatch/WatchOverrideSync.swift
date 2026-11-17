// Owns the Watch's one WatchConnectivity delegate: relay packets and phone state from its paired phone, plus ephemeral voice.
// Audio and transcripts use interactive packets only, and WatchModel and WatchVoiceBridge consume what it classifies.

import AstralCore
import Foundation
import WatchConnectivity

@MainActor
final class WatchOverrideSync: NSObject, WCSessionDelegate, CompanionVoiceChannel {
    static let shared = WatchOverrideSync()
    static let phoneContextKey = "companion.phone"
    static let chatsContextKey = "companion.chats"
    var onRelay: (@MainActor @Sendable (Data) -> Void)?
    var onContext: (@MainActor @Sendable (_ phone: Data?, _ chats: Data?) -> Void)?
    var onRelayReachability: (@MainActor @Sendable (Bool) -> Void)?
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    var reachable: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isCompanionAppInstalled && session.isReachable
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendRelay(_ data: Data) async -> Bool {
        guard reachable else { return false }
        let completion = CompanionVoiceReply()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    WCSession.default.sendMessageData(data) { _ in
                        completion.finish()
                    } errorHandler: {
                        completion.finish($0)
                    }
                }
            } onCancel: {
                completion.finish(CancellationError())
            }
            return true
        } catch { return false }
    }

    func send(_ packet: CompanionVoicePacket) async throws {
        guard reachable else { throw CompanionVoiceError.notReachable }
        let completion = CompanionVoiceReply()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                WCSession.default.sendMessageData(packet.encoded) { data in
                    guard let reply = try? CompanionVoicePacket(data: data), reply.kind == .ack,
                        reply.session == packet.session, reply.sequence == packet.sequence
                    else {
                        completion.finish(CompanionVoiceError.rejected)
                        return
                    }
                    completion.finish()
                } errorHandler: {
                    completion.finish($0)
                }
            }
        } onCancel: {
            completion.finish(CancellationError())
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessageData data: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let response = CompanionVoiceInboundReply(replyHandler)
        let packet: CompanionVoicePacket
        switch WatchInbound.classify(data) {
        case .relay(let relay):
            response.send(Data())
            Task { @MainActor [weak self] in self?.onRelay?(relay) }
            return
        case .voice(let voice):
            packet = voice
        }
        Task { @MainActor [weak self] in
            guard let self, self.reachable, let handler = self.onPacket else {
                response.send(Data())
                return
            }
            do {
                try await handler(packet)
                let receipt = try CompanionVoicePacket(
                    kind: .ack, session: packet.session,
                    sequence: packet.sequence, microseconds: packet.microseconds)
                response.send(receipt.encoded)
            } catch { response.send(Data()) }
        }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if WCSession.default.activationState == .activated {
                self.deliver(WCSession.default.receivedApplicationContext)
            }
            self.notifyReachability()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let phone = context[Self.phoneContextKey] as? Data
        let chats = context[Self.chatsContextKey] as? Data
        Task { @MainActor [weak self] in self?.onContext?(phone, chats) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.notifyReachability() }
    }

    private func notifyReachability() {
        onReachabilityChanged?(reachable)
        onRelayReachability?(reachable)
    }

    private func deliver(_ context: [String: Any]) {
        onContext?(context[Self.phoneContextKey] as? Data, context[Self.chatsContextKey] as? Data)
    }
}

enum WatchInbound {
    case voice(CompanionVoicePacket)
    case relay(Data)

    static func classify(_ data: Data) -> WatchInbound {
        if let packet = try? CompanionVoicePacket(data: data) { return .voice(packet) }
        return .relay(data)
    }
}
