// Remembers that this install runs as a personal mesh, and builds the live MeshRuntime for it.
// A stored value from an older build that named a server connection reads as no choice and is left in place.

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
    }

    private(set) var mode: Mode?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "astral.app-mode.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(Mode.init(rawValue:))
    }

    func choose(_ mode: Mode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

nonisolated enum MeshKernelFactories {
    static func live(
        network: NetworkConfig = NetworkConfig(
            relay: .default, localDiscovery: true, internetLookup: true, loopbackOnly: false, syncIntervalMs: 30_000,
            mailbox: nil),
        phiPrompt: any MeshPhiPrompting = MeshTreatAsPhiPrompt()
    ) -> MeshKernelFactory {
        { config, signer, model, tools, listener in
            var network = network
            network.mailbox = config.mailbox
            return try await RealMeshKernel.open(
                config: config, network: network, signer: signer, model: model, tools: tools,
                listener: listener, phiPrompt: phiPrompt)
        }
    }
}

nonisolated enum MeshStoreRetirement {
    static func retire(_ directory: URL, now: Date, fileManager: FileManager = .default) throws -> URL? {
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = directory.lastPathComponent + ".retired-" + formatter.string(from: now)
        let parent = directory.deletingLastPathComponent()
        var target = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 1
        while fileManager.fileExists(atPath: target.path) {
            suffix += 1
            target = parent.appendingPathComponent(base + "-\(suffix)", isDirectory: true)
        }
        try fileManager.moveItem(at: directory, to: target)
        var fresh = directory
        try fileManager.createDirectory(at: fresh, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fresh.setResourceValues(values)
        return target
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

    static func live(consent: ConsentCoordinator, makeKernel: MeshKernelFactory? = nil) -> MeshRuntime {
        let center = MeshPhiPromptCenter()
        let factory: MeshKernelFactory =
            makeKernel ?? MeshKernelFactories.live(phiPrompt: MeshPhiPromptHost(center: center))
        #if os(macOS)
            let kind = MeshDeviceKind.desktop
            let label = Host.current().localizedName ?? "Mac"
        #else
            let kind = MeshDeviceKind.pocket
            let label = UIDevice.current.name
        #endif
        return MeshRuntime(
            makeKernel: factory, makeKeys: { try DeviceKeys() }, consent: consent,
            onDeviceModel: PreferredOnDeviceModel(), tools: DeviceLocalTools(),
            dataDirectory: dataDirectory(), deviceLabel: label, deviceKind: kind, phiPrompts: center)
    }
}
