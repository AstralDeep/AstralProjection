// Registers an exact native mesh device with the configured publisher and returns only an attenuated empty-wake route.
// Normal owner authentication, strict response bounds and revision-fenced revocation stay separate from ordinary push sessions.

import CoreFoundation
import Foundation

public struct MeshWakeRoute: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let publisher: String
    public let capability: String
    public let expiresAtMS: Int64

    public init(publisher: String, capability: String, expiresAtMS: Int64) {
        self.publisher = publisher
        self.capability = capability
        self.expiresAtMS = expiresAtMS
    }

    public var description: String {
        "MeshWakeRoute(publisher: \(publisher), capability: <redacted>, expiresAtMS: \(expiresAtMS))"
    }
    public var debugDescription: String { description }

    public func isValid(at now: Int64) -> Bool {
        now >= 0 && publisher == "astral" && !capability.isEmpty && capability.utf8.count <= 2048
            && capability.range(of: "^[A-Za-z0-9_-]+={0,2}\\z", options: .regularExpression) != nil
            && expiresAtMS > now && expiresAtMS <= 9_007_199_254_740_991
            && expiresAtMS - now <= 86_400_000
    }
}

public struct MeshDeviceWakeRoute: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let meshId: String
    public let deviceId: String
    public let route: MeshWakeRoute

    public init(meshId: String, deviceId: String, route: MeshWakeRoute) {
        self.meshId = meshId
        self.deviceId = deviceId
        self.route = route
    }
    public var description: String { "MeshDeviceWakeRoute(meshId: \(meshId), deviceId: \(deviceId), route: \(route))" }
    public var debugDescription: String { description }
}

public struct MeshPushRegistration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let target: MeshDeviceWakeRoute
    public let revision: Int64
    public var route: MeshWakeRoute { target.route }
    public init(target: MeshDeviceWakeRoute, revision: Int64) {
        self.target = target
        self.revision = revision
    }
    public var description: String { "MeshPushRegistration(target: \(target), revision: \(revision))" }
    public var debugDescription: String { description }
}

public enum MeshPushRegisterOutcome: Equatable, Sendable {
    case registered(MeshPushRegistration)
    case signInRequired
    case conflict
    case unavailable(String)
}
public enum MeshPushStatusOutcome: Equatable, Sendable {
    case current(revision: Int64, active: Bool, expiresAtMS: Int64)
    case absent
    case signInRequired
    case unavailable
}
public enum MeshPushRevokeOutcome: Equatable, Sendable { case revoked, conflict, signInRequired, unavailable }

public struct MeshPushRest: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)
    public let publisherURL: URL
    private let transport: Transport
    private let now: @Sendable () -> Int64

    public init?(
        publisherURL: URL, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        transport: Transport? = nil
    ) {
        guard let parts = URLComponents(url: publisherURL, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.host?.isEmpty == false,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            ["", "/"].contains(parts.path), !publisherURL.absoluteString.contains("\\")
        else { return nil }
        self.publisherURL = publisherURL
        self.now = now
        self.transport =
            transport ?? { request in try await WorkspaceRequestPolicy.response(request, session: NoStoreHTTP.session) }
    }

    public static func validID(_ value: String) -> Bool {
        value.utf8.count == 71 && value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    public func register(access: String?, meshId: String, deviceId: String, pushToken: String, expectedRevision: Int64)
        async -> MeshPushRegisterOutcome
    {
        guard let access, !access.isEmpty else { return .signInRequired }
        guard Self.validID(meshId), Self.validID(deviceId), (0...9_007_199_254_740_991).contains(expectedRevision),
            !pushToken.isEmpty, pushToken.utf8.count <= 4096, pushToken.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }),
            let request = request(
                access: access, method: "POST", meshId: meshId, deviceId: deviceId,
                extra: ["token": pushToken, "expected_revision": expectedRevision])
        else { return .unavailable("target_invalid") }
        let (status, row) = await outcome(request)
        switch status {
        case 200:
            guard let row, Set(row.keys) == ["mesh_id", "device_id", "revision", "route"],
                row["mesh_id"] as? String == meshId, row["device_id"] as? String == deviceId,
                let revision = Self.integer(row["revision"]), revision > expectedRevision,
                let routeRow = row["route"] as? [String: Any],
                Set(routeRow.keys) == ["publisher", "capability", "expires_at_ms"],
                let publisher = routeRow["publisher"] as? String, let capability = routeRow["capability"] as? String,
                let expiry = Self.integer(routeRow["expires_at_ms"])
            else { return .unavailable("publisher_response_invalid") }
            let route = MeshWakeRoute(publisher: publisher, capability: capability, expiresAtMS: expiry)
            guard route.isValid(at: now()) else { return .unavailable("publisher_response_invalid") }
            return .registered(
                .init(target: .init(meshId: meshId, deviceId: deviceId, route: route), revision: revision))
        case 401: return .signInRequired
        case 409: return .conflict
        default: return .unavailable("publisher_unavailable")
        }
    }

    public func status(access: String?, meshId: String, deviceId: String) async -> MeshPushStatusOutcome {
        guard let access, !access.isEmpty else { return .signInRequired }
        guard let request = request(access: access, method: "GET", meshId: meshId, deviceId: deviceId) else {
            return .unavailable
        }
        let (status, row) = await outcome(request)
        if status == 404 { return .absent }
        if status == 401 { return .signInRequired }
        guard status == 200, let row, Set(row.keys) == ["mesh_id", "device_id", "revision", "state", "expires_at_ms"],
            row["mesh_id"] as? String == meshId, row["device_id"] as? String == deviceId,
            let revision = Self.integer(row["revision"]), revision > 0,
            let expiry = Self.integer(row["expires_at_ms"]), let state = row["state"] as? String,
            (state == "active" && expiry > 0) || (state == "revoked" && expiry == 0)
        else { return .unavailable }
        return .current(revision: revision, active: state == "active" && expiry > now(), expiresAtMS: expiry)
    }

    public func revoke(access: String?, meshId: String, deviceId: String, revision: Int64) async
        -> MeshPushRevokeOutcome
    {
        guard let access, !access.isEmpty else { return .signInRequired }
        guard (1...9_007_199_254_740_991).contains(revision),
            let request = request(
                access: access, method: "DELETE", meshId: meshId, deviceId: deviceId,
                extra: ["expected_revision": revision])
        else { return .unavailable }
        switch await outcome(request).0 {
        case 200, 404: return .revoked
        case 409: return .conflict
        case 401: return .signInRequired
        default: return .unavailable
        }
    }

    private func request(access: String, method: String, meshId: String, deviceId: String, extra: [String: Any] = [:])
        -> URLRequest?
    {
        guard Self.validID(meshId), Self.validID(deviceId) else { return nil }
        let url = ["api", "push", "mesh", "destinations"].reduce(publisherURL) { $0.appendingPathComponent($1) }
        var request = NoStoreHTTP.request(url: url)
        request.timeoutInterval = 8
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if method == "GET" {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "mesh_id", value: meshId), .init(name: "device_id", value: deviceId)]
            request.url = parts.url
        } else {
            var body = extra
            body["mesh_id"] = meshId
            body["device_id"] = deviceId
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let data = request.httpBody, data.count <= 8192 else { return nil }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func outcome(_ request: URLRequest) async -> (Int, [String: Any]?) {
        guard let (status, data) = try? await transport(request), data.count <= 8192 else { return (0, nil) }
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            !["d", "f"].contains(String(cString: value.objCType)), let result = Int64(value.stringValue),
            (0...9_007_199_254_740_991).contains(result)
        else { return nil }
        return result
    }
}
