// Destination boundary for owner-bound mobile push on Apple clients: enrollment, delivery
// acknowledgment, and revocation against Deep's push REST surface, with the same transport
// seam and denial classification the Android runtime uses. PushNotificationService consumes it.

import Foundation

public enum PushEnrollOutcome: Equatable, Sendable {
    case accepted
    case rejected(transient: Bool, code: String)
    case unauthenticated
}

public enum PushAckOutcome: Equatable, Sendable {
    case acknowledged
    case refused
    case destinationRevoked
    case unauthenticated
}

public enum PushRevokeOutcome: Equatable, Sendable {
    case revoked
    case unauthenticated
    case failed
}

public struct PushRest: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    public let serverBase: URL
    private let transport: Transport

    public init(
        serverBase: URL,
        transport: Transport? = nil
    ) {
        self.serverBase = serverBase
        if let transport = transport {
            self.transport = transport
        } else {
            self.transport = { request in
                let (data, response) = try await NoStoreHTTP.session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            }
        }
    }

    public func enroll(
        token: String?,
        deviceId: String,
        platform: String,
        pushToken: String,
        label: String?
    ) async -> PushEnrollOutcome {
        guard let token = token, !token.isEmpty else { return .unauthenticated }
        var body: [String: JSONValue] = [
            "device_id": .string(deviceId),
            "platform": .string(platform),
            "token": .string(pushToken),
        ]
        if let label = label, !label.isEmpty {
            body["label"] = .string(String(label.prefix(64)))
        }
        guard let request = postRequest(path: "api/push/destinations", token: token, body: body) else {
            return .rejected(transient: true, code: Self.codeNetwork)
        }
        let result = await outcome(of: request)
        return classify(result)
    }

    public func acknowledge(
        token: String?,
        deviceId: String,
        notificationId: String
    ) async -> PushAckOutcome {
        guard let token = token, !token.isEmpty else { return .unauthenticated }
        let body: [String: JSONValue] = [
            "device_id": .string(deviceId),
            "notification_id": .string(notificationId),
        ]
        guard let request = postRequest(path: "api/push/ack", token: token, body: body) else {
            return .refused
        }
        let (status, _) = await outcome(of: request)
        switch status {
        case 200...299: return .acknowledged
        case 410: return .destinationRevoked
        default: return .refused
        }
    }

    public func revoke(token: String?, deviceId: String) async -> PushRevokeOutcome {
        guard let token = token, !token.isEmpty else { return .unauthenticated }
        var components = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? ""
        if !path.hasSuffix("/") {
            path += "/"
        }
        path += "api/push/destinations/\(deviceId)"
        components?.percentEncodedPath = path
        guard let url = components?.url else { return .failed }
        var request = NoStoreHTTP.request(url: url, method: "DELETE")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, _) = await outcome(of: request)
        switch status {
        case 200...299, 404: return .revoked
        default: return .failed
        }
    }

    private func postRequest(path: String, token: String, body: [String: JSONValue]) -> URLRequest? {
        guard let encoded = try? JSONValue.object(body).encoded() else { return nil }
        var request = NoStoreHTTP.request(
            url: serverBase.appendingPathComponent(path),
            method: "POST",
            body: encoded,
            contentType: "application/json")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func outcome(of request: URLRequest) async -> (Int, Data) {
        return (try? await transport(request)) ?? (0, Data())
    }

    private func classify(_ result: (Int, Data)) -> PushEnrollOutcome {
        switch result.0 {
        case 200...299: return .accepted
        case 401: return .unauthenticated
        case 400: return .rejected(transient: false, code: "destination_invalid")
        case 403: return .rejected(transient: false, code: "destination_forbidden")
        case 409: return .rejected(transient: false, code: "destination_capacity")
        case 429: return .rejected(transient: true, code: "rate_limited")
        default: return .rejected(transient: true, code: Self.codeProviderUnavailable)
        }
    }

    static let codeNetwork = "enroll_network"
    static let codeProviderUnavailable = "provider_unavailable"
}
