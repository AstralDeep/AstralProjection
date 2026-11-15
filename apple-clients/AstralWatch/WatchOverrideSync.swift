// Owns the Watch's one WatchConnectivity delegate for endpoint preferences and ephemeral voice with its paired phone.
// Audio and transcripts use interactive packets only and never enter persistent application context.

import AstralCore
import Foundation
import WatchConnectivity

@MainActor
final class WatchOverrideSync: NSObject, WCSessionDelegate, CompanionVoiceChannel {
    static let shared = WatchOverrideSync()
    static let didChangeNotification = Notification.Name("AstralWatchServerOverrideDidChange")
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    nonisolated static func resolvedServerBase(defaults: UserDefaults = .standard) -> URL {
        let override = defaults.string(forKey: AstralConfig.serverOverrideDefaultsKey)
        let resolved = AstralConfig.resolvedServerBaseURL(override: override)
        return URL(string: resolved) ?? URL(string: AstralConfig.fallbackServerBaseURL)!
    }

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
        guard let packet = try? CompanionVoicePacket(data: data) else {
            response.send(Data())
            return
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
                self.apply(
                    WCSession.default.receivedApplicationContext[AstralConfig.serverOverrideDefaultsKey] as? String)
            }
            self.onReachabilityChanged?(self.reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let endpoint = context[AstralConfig.serverOverrideDefaultsKey] as? String
        Task { @MainActor [weak self] in self?.apply(endpoint) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onReachabilityChanged?(self.reachable)
        }
    }

    private func apply(_ raw: String?) {
        guard let endpoint = AstralConfig.usableEndpoint(raw),
            endpoint != defaults.string(forKey: AstralConfig.serverOverrideDefaultsKey)
        else { return }
        defaults.set(endpoint, forKey: AstralConfig.serverOverrideDefaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
