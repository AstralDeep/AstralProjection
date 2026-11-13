// Builds the Mac app's node host controller once, points it at Application Support, and stops the node when the app quits unless Keep running is on.
// AstralApp owns one instance, MeshSettingsView shows its controls, and the node pack is offered only in the direct-download build.

#if os(macOS)
    import AppKit
    import AstralCore
    import Foundation
    import Observation

    @MainActor
    @Observable
    final class MacNodeHostStore {
        let controller: NodeHostController
        @ObservationIgnored private var quitObserver: NSObjectProtocol?

        init(
            defaults: UserDefaults = .standard, available: Bool = MacNodeHostStore.defaultAvailability(),
            root: URL = MacNodeHostStore.defaultRoot()
        ) {
            let config = EnrollmentSignIn.defaultConfig()
            let bundle = Bundle.main
            let environment = NodeHostEnvironment(
                root: root, available: available,
                issuer: config.authority.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                clientId: config.clientId, meshLabel: (Host.current().localizedName ?? "Mac") + " node",
                defaults: defaults, defaultPackURL: bundle.object(forInfoDictionaryKey: "ASTRALNodePackURL") as? String ?? "",
                pinnedDescriptorSha256: bundle.object(forInfoDictionaryKey: "ASTRALNodePackSHA256") as? String)
            controller = NodeHostController(environment: environment)
            let target = controller
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated { target.applicationWillTerminate() }
            }
            if available { Task { await target.refresh() } }
        }

        nonisolated static func defaultAvailability() -> Bool {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--astral-ui-test-node-row") { return true }
            #endif
            return NodeHostAvailability.current()
        }

        nonisolated static func defaultRoot() -> URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
                .appendingPathComponent("node", isDirectory: true)
        }

        static func ownerToken() async throws -> String {
            let web = await MainActor.run { SystemEnrollmentWebAuthenticator() }
            return try await EnrollmentSignIn(web: web).signIn(nonce: PKCE.makeVerifier())
        }
    }
#endif
