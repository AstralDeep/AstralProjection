// Rejects legacy Watch voice-session requests without credentials, HTTP or media grants.
// Active Watch voice uses the paired phone's installed model through WatchConnectivity.

import AstralCore
import Foundation

struct WatchVoiceRESTClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    init(
        serverBase: URL, deviceId: String, connectionGeneration: String, controlBinding: WatchVoiceControlBinding,
        tokenProvider: @escaping @Sendable () async -> String?, transport: Transport? = nil
    ) {}

    func createSession(chatId: String, activationId: String, permission: WatchVoicePermission) async throws
        -> WatchVoiceSessionGrant
    {
        throw WatchVoiceRESTError.retired
    }
    func takeOverSession(
        sessionId: String, chatId: String, activationId: String, expectedGeneration: UInt64,
        expectedMediaGrantRevision: UInt64, permission: WatchVoicePermission
    ) async throws -> WatchVoiceSessionGrant {
        throw WatchVoiceRESTError.retired
    }
    func updateSession(_ session: WatchVoiceSession, changes: [String: JSONValue]) async throws -> WatchVoiceSession {
        throw WatchVoiceRESTError.retired
    }
    func endSession(_ session: WatchVoiceSession) async throws { throw WatchVoiceRESTError.retired }
    func stopSpeech(_ session: WatchVoiceSession) async throws { throw WatchVoiceRESTError.retired }
    func consentSensitiveRecap(_ session: WatchVoiceSession, resultId: String, turnId: String) async throws {
        throw WatchVoiceRESTError.retired
    }
    func refreshGrant(_ session: WatchVoiceSession, refreshId: String) async throws -> WatchVoiceSessionGrant {
        throw WatchVoiceRESTError.retired
    }
}

enum WatchVoiceRESTError: Error, Equatable, Sendable {
    case invalidRequest, authenticationRequired, network, malformedResponse, retired
    case refused(status: Int, code: String)
}
