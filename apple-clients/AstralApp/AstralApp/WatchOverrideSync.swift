// Owns the iPhone's one WatchConnectivity delegate for endpoint preferences and ephemeral paired-Watch voice.
// Interactive PCM stays out of application context and background transfer queues.

#if os(iOS)
    import AstralCore
    import Foundation
    import WatchConnectivity

    @MainActor
    final class WatchOverrideSync: NSObject, WCSessionDelegate, CompanionVoiceChannel {
        static let shared = WatchOverrideSync()
        var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
        var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
        private var pending: String?

        var reachable: Bool {
            guard WCSession.isSupported() else { return false }
            let session = WCSession.default
            return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
                && session.isReachable
        }

        func activate() {
            guard WCSession.isSupported() else { return }
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        func push(_ rawEndpoint: String?) {
            guard let endpoint = AstralConfig.usableEndpoint(rawEndpoint) else { return }
            pending = endpoint
            flush()
        }

        private func flush() {
            guard WCSession.isSupported(), let endpoint = pending else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            do {
                try session.updateApplicationContext([AstralConfig.serverOverrideDefaultsKey: endpoint])
                pending = nil
            } catch {}
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
                self.flush()
                self.onReachabilityChanged?(self.reachable)
            }
        }

        nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onReachabilityChanged?(self.reachable)
            }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
            Task { @MainActor [weak self] in self?.onReachabilityChanged?(false) }
        }

        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
    }
#endif
