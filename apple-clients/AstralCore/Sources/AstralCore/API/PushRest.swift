// Performs bounded owner-authenticated push enrollment, immutable delivery admission, receipts, conditional revocation and registered UI-presence requests for Apple clients.

import CoreFoundation
import Foundation

public enum PushEnrollOutcome: Equatable, Sendable {
    case accepted(serverTokenGeneration: Int64, destinationRevision: Int64)
    case rejected(transient: Bool, code: String)
    case unauthenticated
}
public enum PushAckOutcome: Equatable, Sendable { case acknowledged, refused, destinationRevoked, unauthenticated }
public enum PushRevokeOutcome: Equatable, Sendable { case revoked, conflict, unauthenticated, failed }
public struct PushSource: Equatable, Sendable {
    public let notificationId: String
    public let chatId: String?
}
public struct PushPresenceOutcome: Equatable, Sendable {
    public let acceptedSequence: Int64
    public let expiresInSeconds: Int
}

public struct PushDestinationSnapshot: Equatable, Sendable {
    public let generation: Int64
    public let revision: Int64
    public let active: Bool
}

public struct PushRest: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)
    public let serverBase: URL
    private let transport: Transport
    private let sessionHeaders: @Sendable (String) async -> [String: String]
    public init(
        serverBase: URL, sessionHeaders: @escaping @Sendable (String) async -> [String: String] = { _ in [:] },
        transport: Transport? = nil
    ) {
        self.serverBase = serverBase
        self.sessionHeaders = sessionHeaders
        self.transport =
            transport ?? { request in try await WorkspaceRequestPolicy.response(request, session: NoStoreHTTP.session) }
    }

    public func enroll(
        token: String?, deviceId: String, platform: String, pushToken: String, label: String?,
        expectedDestinationRevision: Int64
    ) async
        -> PushEnrollOutcome
    {
        guard let token, !token.isEmpty else { return .unauthenticated }
        guard (0...9_007_199_254_740_991).contains(expectedDestinationRevision) else {
            return .rejected(transient: false, code: "destination_invalid")
        }
        var body: [String: JSONValue] = [
            "device_id": .string(deviceId), "platform": .string(platform), "token": .string(pushToken),

        ]
        if let label, !label.isEmpty { body["label"] = .string(String(label.prefix(64))) }
        guard
            let request = request(
                path: ["push", "destinations"], token: token, body: body,
                integerFields: ["expected_destination_revision": expectedDestinationRevision])
        else {
            return .rejected(transient: true, code: Self.codeNetwork)
        }
        let result = await outcome(request)
        if (200...299).contains(result.0) {
            let row = result.1 as? [String: Any]
            if row?["device_id"] as? String == deviceId, row?["platform"] as? String == platform,
                row?["status"] as? String == "active", let generation = Self.integer(row?["token_generation"]),
                (1...9_007_199_254_740_991).contains(generation), let revision = Self.integer(row?["updated_at"]),
                revision > expectedDestinationRevision, revision <= 9_007_199_254_740_991
            {
                return .accepted(serverTokenGeneration: generation, destinationRevision: revision)
            }
            return .rejected(transient: false, code: "destination_response_invalid")
        }
        switch result.0 {
        case 401: return .unauthenticated
        case 400, 422: return .rejected(transient: false, code: "destination_invalid")
        case 403: return .rejected(transient: false, code: "destination_forbidden")
        case 409: return .rejected(transient: true, code: "destination_conflict")
        case 429: return .rejected(transient: true, code: "rate_limited")
        case 0: return .rejected(transient: true, code: Self.codeNetwork)
        default: return .rejected(transient: true, code: Self.codeProviderUnavailable)
        }
    }

    public func destinationSnapshot(token: String?, deviceId: String) async -> PushDestinationSnapshot? {
        guard let token, !token.isEmpty, let request = request(path: ["push", "destinations", deviceId], token: token)
        else { return nil }
        let result = await outcome(request)
        if result.0 == 404 { return PushDestinationSnapshot(generation: 0, revision: 0, active: false) }
        guard result.0 == 200, let row = result.1 as? [String: Any], row["device_id"] as? String == deviceId,
            let generation = Self.integer(row["token_generation"]), (1...9_007_199_254_740_991).contains(generation),
            let revision = Self.integer(row["updated_at"]), (1...9_007_199_254_740_991).contains(revision)
        else { return nil }
        return PushDestinationSnapshot(
            generation: generation, revision: revision, active: row["status"] as? String == "active")
    }

    public func acknowledge(token: String?, deviceId: String, notificationId: String) async -> PushAckOutcome {
        guard let token, !token.isEmpty else { return .unauthenticated }
        guard
            let request = request(
                path: ["push", "ack"], token: token,
                body: ["device_id": .string(deviceId), "notification_id": .string(notificationId)])
        else { return .refused }
        switch await outcome(request).0 {
        case 200...299: return .acknowledged
        case 410: return .destinationRevoked
        default: return .refused
        }
    }

    public func revoke(
        token: String?, deviceId: String, expectedTokenGeneration: Int64, expectedDestinationRevision: Int64
    ) async -> PushRevokeOutcome {
        guard let token, !token.isEmpty else { return .unauthenticated }
        guard (1...9_007_199_254_740_991).contains(expectedTokenGeneration),
            (1...9_007_199_254_740_991).contains(expectedDestinationRevision),
            var request = request(path: ["push", "destinations", deviceId], token: token),
            let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failed }
        components.queryItems = [
            .init(name: "expected_token_generation", value: String(expectedTokenGeneration)),
            .init(name: "expected_destination_revision", value: String(expectedDestinationRevision)),
        ]
        request.url = components.url
        request.httpMethod = "DELETE"
        switch await outcome(request).0 {
        case 200...299, 404: return .revoked
        case 409: return .conflict
        case 401: return .unauthenticated
        default: return .failed
        }
    }

    public func authorize(
        token: String?, deviceId: String, generation: Int64, destinationRevision: Int64, notificationId: String
    ) async
        -> PushSource?
    {
        guard let token, !token.isEmpty, (1...9_007_199_254_740_991).contains(generation),
            (1...9_007_199_254_740_991).contains(destinationRevision),
            let destinationRequest = request(path: ["push", "destinations", deviceId], token: token),
            let deliveryRequest = request(path: ["push", "deliveries", notificationId], token: token)
        else { return nil }
        let destination = await outcome(destinationRequest)
        guard destination.0 == 200, let row = destination.1 as? [String: Any], row["device_id"] as? String == deviceId,
            row["status"] as? String == "active", Self.integer(row["token_generation"]) == generation,
            Self.integer(row["updated_at"]) == destinationRevision
        else { return nil }
        let deliveries = await outcome(deliveryRequest)
        guard deliveries.0 == 200, let events = deliveries.1 as? [[String: Any]],
            events.contains(where: {
                $0["action"] as? String == "push.delivery.queued" && $0["device_id"] as? String == deviceId
                    && Self.integer($0["token_generation"]) == generation
                    && Self.integer($0["destination_revision"]) == destinationRevision
            })
        else { return nil }
        return await source(token: token, notificationId: notificationId)
    }

    public func source(token: String?, notificationId: String) async -> PushSource? {
        guard let token, !token.isEmpty,
            notificationId.range(of: "^[A-Za-z0-9._:-]{8,128}$", options: .regularExpression) != nil,
            let request = request(path: ["notifications", "inbox", notificationId], token: token)
        else { return nil }
        let result = await outcome(request)
        guard result.0 == 200, let entry = result.1 as? [String: Any], entry["entry_id"] as? String == notificationId,
            entry["deleted_at"] is NSNull, let revision = Self.integer(entry["revision"]), revision >= 0,
            let content = entry["content"] as? [String: Any]
        else { return nil }
        let chatId = content["chat_id"] as? String
        if let chatId,
            chatId.isEmpty || chatId.utf8.count > 128
                || chatId.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        {
            return nil
        }
        return PushSource(notificationId: notificationId, chatId: chatId)
    }

    public func presence(
        token: String?, deviceId: String, connectionGeneration: String, sequence: Int64, foreground: Bool
    ) async -> PushPresenceOutcome? {
        guard let token, !token.isEmpty, !connectionGeneration.isEmpty, (1...9_007_199_254_740_991).contains(sequence),
            let request = request(
                path: ["notifications", "presence"], token: token,
                body: [
                    "device_id": .string(deviceId), "connection_generation": .string(connectionGeneration),
                    "sequence": .number(Double(sequence)), "foreground": .bool(foreground),
                ])
        else { return nil }
        let result = await outcome(request)
        guard result.0 == 200, let row = result.1 as? [String: Any], Self.integer(row["accepted_sequence"]) == sequence,
            let expiry = Self.integer(row["expires_in_seconds"]), expiry == (foreground ? 45 : 0)
        else { return nil }
        return PushPresenceOutcome(acceptedSequence: sequence, expiresInSeconds: Int(expiry))
    }

    private func request(
        path: [String], token: String, body: [String: JSONValue]? = nil, integerFields: [String: Int64] = [:]
    ) -> URLRequest? {
        let url = (["api"] + path).reduce(serverBase) { $0.appendingPathComponent($1) }
        var request = NoStoreHTTP.request(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            guard let encoded = try? JSONValue.object(body).encoded() else { return nil }
            request.httpMethod = "POST"
            if integerFields.isEmpty {
                request.httpBody = encoded
            } else {
                guard var values = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
                    return nil
                }
                for (key, value) in integerFields { values[key] = value }
                request.httpBody = try? JSONSerialization.data(withJSONObject: values)
                guard request.httpBody != nil else { return nil }
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func outcome(_ request: URLRequest) async -> (Int, Any?) {
        var authenticated = request
        if let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer ") {
            for (name, value) in await sessionHeaders(String(authorization.dropFirst(7)))
            where ["Cookie", "Origin"].contains(name) {
                authenticated.setValue(value, forHTTPHeaderField: name)
            }
        }
        guard let (status, data) = try? await transport(authenticated), !Task.isCancelled, data.count <= 16 * 1024
        else {
            return (0, nil)
        }
        return (status, try? JSONSerialization.jsonObject(with: data))
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            !["d", "f"].contains(String(cString: value.objCType))
        else { return nil }
        return Int64(value.stringValue)
    }
    static let codeNetwork = "enroll_network"
    static let codeProviderUnavailable = "provider_unavailable"
}
