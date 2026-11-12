// Remembers whether this install runs as a personal mesh or as a thin client of a node, and builds the live MeshRuntime for mesh mode.
// The server path stays the default until someone chooses a mesh, so existing sign-ins and tests keep their current entry screen.

import AstralCore
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

nonisolated enum MeshKernelFactories {
    static let unavailable: MeshKernelFactory = { _, _, _, _, _ in
        throw MeshKernelError.unavailable("This build does not include the mesh runtime yet.")
    }
}

@MainActor
enum MeshRuntimeBuilder {
    static func dataDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
            .appendingPathComponent("mesh", isDirectory: true)
    }

    static func live(
        consent: ConsentCoordinator, makeKernel: @escaping MeshKernelFactory = MeshKernelFactories.unavailable
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
