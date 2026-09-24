// Receives the iPhone companion's pushed backend-endpoint override over Watch Connectivity; purely
// opportunistic, since the watch also runs standalone and falls back to AstralConfig's build-time endpoint
// when no companion ever pairs.

import AstralCore
import Foundation
import WatchConnectivity

final class WatchOverrideSync: NSObject, WCSessionDelegate {
    static let shared = WatchOverrideSync()

    static let didChangeNotification = Notification.Name("AstralWatchServerOverrideDidChange")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    static func resolvedServerBase(defaults: UserDefaults = .standard) -> URL {
        let override = defaults.string(forKey: AstralConfig.serverOverrideDefaultsKey)
        let resolved = AstralConfig.resolvedServerBaseURL(override: override)
        // Fallback URL is compiled-in; this force-unwrap can't trap
        return URL(string: resolved) ?? URL(string: AstralConfig.fallbackServerBaseURL)!
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else { return }
        guard session.isCompanionAppInstalled else { return }
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        apply(context)
    }

    private func apply(_ context: [String: Any]) {
        let raw = context[AstralConfig.serverOverrideDefaultsKey] as? String
        guard let endpoint = AstralConfig.usableEndpoint(raw) else { return }
        guard endpoint != defaults.string(forKey: AstralConfig.serverOverrideDefaultsKey) else { return }
        defaults.set(endpoint, forKey: AstralConfig.serverOverrideDefaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
