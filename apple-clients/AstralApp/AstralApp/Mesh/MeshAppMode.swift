// Remembers whether this install runs as a personal mesh or as a thin client of a node, and builds the live MeshRuntime for mesh mode.
// The server path stays the default until someone chooses a mesh, so existing sign-ins and tests keep their current entry screen.

import AstralCore
import AstralKernel
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
@Observable
final class AppModeStore {
    enum Mode: String, Equatable {
        case mesh
        case node
    }

    private(set) var mode: Mode?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "astral.app-mode.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(Mode.init(rawValue:))
    }

    var usesMesh: Bool { mode == .mesh }

    func choose(_ mode: Mode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

nonisolated struct MeshIssuerSource: Sendable {
    let issuer: String
    let clientId: String
    let keysURL: URL
    let fetch: @Sendable (URLRequest) async throws -> Data

    static func keycloak(
        config: OIDCConfig = EnrollmentSignIn.defaultConfig(),
        fetch: @escaping @Sendable (URLRequest) async throws -> Data = { request in
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    ) -> MeshIssuerSource {
        MeshIssuerSource(
            issuer: config.authority.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            clientId: config.clientId,
            keysURL: config.authority.appendingPathComponent("protocol/openid-connect/certs"), fetch: fetch)
    }

    func issuers(cacheIn directory: URL) async -> [IssuerConfig] {
        let cache = directory.appendingPathComponent("issuer-keys.json")
        var request = URLRequest(url: keysURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let data = try? await fetch(request), Self.hasKeys(data) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return [config(data)]
        }
        if let data = try? Data(contentsOf: cache), Self.hasKeys(data) { return [config(data)] }
        return []
    }

    private func config(_ data: Data) -> IssuerConfig {
        IssuerConfig(issuer: issuer, clientId: clientId, jwksJson: String(decoding: data, as: UTF8.self))
    }

    private static func hasKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let keys = object["keys"] as? [Any]
        else { return false }
        return !keys.isEmpty
    }
}

nonisolated enum MeshKernelFactories {
    static func live(issuerSource: MeshIssuerSource = .keycloak(), network: NetworkConfig = NetworkConfig(
        relay: .default, localDiscovery: true, internetLookup: true, loopbackOnly: false, syncIntervalMs: 30_000,
        mailbox: nil)
    ) -> MeshKernelFactory {
        { config, signer, model, tools, listener in
            let issuers = await issuerSource.issuers(cacheIn: config.dataDirectory)
            return try await RealMeshKernel.open(
                config: config, issuers: issuers, network: network, signer: signer, model: model, tools: tools,
                listener: listener)
        }
    }
}

@MainActor
enum MeshRuntimeBuilder {
    static func dataDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
            .appendingPathComponent("mesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    static func live(
        consent: ConsentCoordinator, makeKernel: @escaping MeshKernelFactory = MeshKernelFactories.live()
    ) -> MeshRuntime {
        #if os(macOS)
            let kind = MeshDeviceKind.desktop
            let label = Host.current().localizedName ?? "Mac"
        #else
            let kind = MeshDeviceKind.pocket
            let label = UIDevice.current.name
        #endif
        return MeshRuntime(
            makeKernel: makeKernel, makeKeys: { try DeviceKeys() }, consent: consent,
            onDeviceModel: FoundationModelsOnDeviceModel(), tools: DeviceLocalTools(),
            dataDirectory: dataDirectory(), deviceLabel: label, deviceKind: kind,
            enrollment: { nonce in
                let web = await MainActor.run { SystemEnrollmentWebAuthenticator() }
                return try await EnrollmentSignIn(web: web).signIn(nonce: nonce)
            })
    }
}
