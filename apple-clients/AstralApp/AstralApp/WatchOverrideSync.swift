// Owns the iPhone's one WatchConnectivity delegate for endpoint preferences, ephemeral paired-Watch voice and the companion relay packets.
// Interactive PCM stays out of application context and background transfer queues, and relay packets are carried verbatim for PhoneCompanionRelay.

#if os(iOS)
    import AstralCore
    import Foundation
    import WatchConnectivity

    @MainActor
    final class WatchOverrideSync: NSObject, WCSessionDelegate, CompanionVoiceChannel, CompanionRelayChannel {
        static let shared = WatchOverrideSync()
        var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
        var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
        var onRelayRequest: (@MainActor @Sendable (Data) async -> Void)?
        var onRelayReady: (@MainActor @Sendable () -> Void)?
        private var context: [String: Any] = [:]
        private var contextDirty = false
        static let companionContextKeys = ["chats": "companion.chats", "phone": "companion.phone"]

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
            context[AstralConfig.serverOverrideDefaultsKey] = endpoint
            contextDirty = true
            flush()
        }

        func publish(_ update: Data, latestState: Bool) {
            guard WCSession.isSupported() else { return }
            let object = try? JSONSerialization.jsonObject(with: update) as? [String: Any]
            if latestState, let kind = object?["kind"] as? String, let key = Self.companionContextKeys[kind] {
                context[key] = update
                contextDirty = true
                flush()
            }
            guard reachable else { return }
            WCSession.default.sendMessageData(update, replyHandler: nil, errorHandler: nil)
        }

        private func flush() {
            guard WCSession.isSupported(), contextDirty else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            do {
                try session.updateApplicationContext(context)
                contextDirty = false
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
                Task { @MainActor [weak self] in
                    if let self, self.reachable, let handler = self.onRelayRequest { await handler(data) }
                    response.send(Data())
                }
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
                if self.reachable { self.onRelayReady?() }
            }
        }

        nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onReachabilityChanged?(self.reachable)
                if self.reachable { self.onRelayReady?() }
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
