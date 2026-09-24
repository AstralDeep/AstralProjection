// Watch-side client for the backend's device-login broker: the watch never talks to the identity provider
// directly, only start/poll/refresh against the orchestrator. Used by WatchModel and TokenStore's broker
// refresh strategy.

import Foundation

public struct DeviceLoginStart: Sendable, Equatable {
    public let handle: String
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String
    public let expiresIn: TimeInterval
    public let interval: TimeInterval
    public let qrPNG: Data?

    public init?(json: JSONValue) {
        guard let handle = json["handle"]?.stringValue,
            let code = json["user_code"]?.stringValue
        else { return nil }
        self.handle = handle
        self.userCode = code
        self.verificationURI = json["verification_uri"]?.stringValue ?? ""
        self.verificationURIComplete = json["verification_uri_complete"]?.stringValue ?? ""
        self.expiresIn = json["expires_in"]?.numberValue ?? 600
        self.interval = max(json["interval"]?.numberValue ?? 5, 1)
        self.qrPNG = json["qr_png_base64"]?.stringValue.flatMap { Data(base64Encoded: $0) }
    }
}

public enum DeviceLoginPoll: Sendable, Equatable {
    case pending(interval: TimeInterval)
    case slowDown(interval: TimeInterval)
    case approved(TokenSet)
    case denied(reason: String)
    case expired

    public init?(json: JSONValue) {
        switch json["status"]?.stringValue {
        case "pending":
            self = .pending(interval: json["interval"]?.numberValue ?? 5)
        case "slow_down":
            self = .slowDown(interval: json["interval"]?.numberValue ?? 10)
        case "approved":
            guard let tokens = json["tokens"].flatMap({ TokenSet(json: $0) }) else { return nil }
            self = .approved(tokens)
        case "denied":
            self = .denied(reason: json["reason"]?.stringValue ?? "access_denied")
        case "expired":
            self = .expired
        default:
            return nil
        }
    }
}

public enum DeviceLoginError: Error, Equatable {
    case unavailable(String)
    case invalidHandle
    case rejected(String)
    case rateLimited
    case transport(String)
}

public struct DeviceLoginClient: Sendable {
    public typealias Transport = @Sendable (URL, Data) async throws -> (Int, Data)

    public let serverBase: URL
    public let clientId: String
    private let transport: Transport

    public init(
        serverBase: URL, clientId: String = AstralConfig.watchClientId,
        transport: Transport? = nil
    ) {
        self.serverBase = serverBase
        self.clientId = clientId
        self.transport = transport ?? Self.urlSessionTransport
    }

    public static let urlSessionTransport: Transport = { url, body in
        let request = brokerRequest(url: url, body: body)
        let (data, response) = try await NoStoreHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    static func brokerRequest(url: URL, body: Data) -> URLRequest {
        NoStoreHTTP.request(
            url: url,
            method: "POST",
            body: body,
            contentType: "application/json")
    }

    func post(_ path: String, _ payload: JSONValue) async throws -> (Int, JSONValue) {
        let url = serverBase.appendingPathComponent(path)
        do {
            let (status, data) = try await transport(url, try payload.encoded())
            let json = (try? JSONValue.parse(data)) ?? .object([:])
            return (status, json)
        } catch let error as DeviceLoginError {
            throw error
        } catch {
            throw DeviceLoginError.transport(error.localizedDescription)
        }
    }

    static func brokerError(status: Int, body: JSONValue) -> DeviceLoginError {
        let detail =
            body["detail"]?["detail"]?.stringValue
            ?? body["detail"]?.stringValue ?? "device login failed"
        switch status {
        case 429: return .rateLimited
        case 400: return .invalidHandle
        case 401: return .rejected(detail)
        default: return .unavailable(detail)
        }
    }

    public func start() async throws -> DeviceLoginStart {
        let (status, body) = try await post(
            "api/auth/device/start",
            .object(["client": .string(clientId)]))
        guard status == 200, let out = DeviceLoginStart(json: body) else {
            throw Self.brokerError(status: status, body: body)
        }
        return out
    }

    public func poll(handle: String) async throws -> DeviceLoginPoll {
        let (status, body) = try await post(
            "api/auth/device/poll",
            .object(["handle": .string(handle)]))
        guard status == 200, let out = DeviceLoginPoll(json: body) else {
            throw Self.brokerError(status: status, body: body)
        }
        return out
    }

    public func refresh(refreshToken: String) async throws -> TokenSet {
        let (status, body) = try await post(
            "api/auth/device/refresh",
            .object([
                "client": .string(clientId),
                "refresh_token": .string(refreshToken),
            ]))
        guard status == 200, let tokens = TokenSet(json: body) else {
            throw Self.brokerError(status: status, body: body)
        }
        return tokens
    }

    public func waitForApproval(
        start: DeviceLoginStart,
        onTick: (@Sendable (TimeInterval) -> Void)? = nil,
        sleeper: (@Sendable (TimeInterval) async -> Void)? = nil
    ) async throws -> DeviceLoginPoll {
        var interval = start.interval
        let sleep =
            sleeper ?? { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        while true {
            try Task.checkCancellation()
            onTick?(interval)
            await sleep(interval)
            let result = try await poll(handle: start.handle)
            switch result {
            case .pending(let next):
                interval = max(next, 1)
            case .slowDown(let next):
                interval = max(next, interval)
            case .approved, .denied, .expired:
                return result
            }
        }
    }
}
