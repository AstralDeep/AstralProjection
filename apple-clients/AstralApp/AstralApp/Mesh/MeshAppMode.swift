// Remembers whether this install runs as a personal mesh or as a thin client of a node, and builds the live MeshRuntime for mesh mode.
// Fresh and legacy installs start with mesh choices; an explicit server connection remains separate.

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
    private static let key = "astral.app-mode.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(Mode.init(rawValue:))
    }

    var usesMesh: Bool { mode != .node }

    func choose(_ mode: Mode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

nonisolated enum MeshKernelFactories {
    static func live(
        network: NetworkConfig = NetworkConfig(
            relay: .default, localDiscovery: true, internetLookup: true, loopbackOnly: false, syncIntervalMs: 30_000,
            mailbox: nil)
    ) -> MeshKernelFactory {
        { config, signer, model, tools, listener in
            var network = network
            network.mailbox = config.mailbox
            return try await RealMeshKernel.open(
                config: config, network: network, signer: signer, model: model, tools: tools,
                listener: listener)
        }
    }
}

@MainActor
enum MeshRuntimeBuilder {
    static func dataDirectory(in root: URL? = nil) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root =
            root ?? support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
        var directory = root.appendingPathComponent("mesh-v2", isDirectory: true)
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
            onDeviceModel: PreferredOnDeviceModel(), tools: DeviceLocalTools(),
            dataDirectory: dataDirectory(), deviceLabel: label, deviceKind: kind)
    }
}
