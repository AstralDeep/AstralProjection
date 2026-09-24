// Best-effort push of the backend endpoint override to a paired watch over WatchConnectivity; iOS-only, since
// the file compiles to nothing on macOS. Read by AppModel and the watch's own WatchModel/WatchOverrideSync.

#if os(iOS)
    import Foundation
    import WatchConnectivity
    import AstralCore

    final class WatchOverrideSync: NSObject, WCSessionDelegate {
        static let shared = WatchOverrideSync()

        private var pending: String?

        func activate() {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        func push(_ rawEndpoint: String?) {
            guard let endpoint = AstralConfig.usableEndpoint(rawEndpoint) else { return }
            pending = endpoint
            flush()
        }

        private func flush() {
            guard WCSession.isSupported(), let endpoint = pending else { return }
            let session = WCSession.default
            guard session.activationState == .activated,
                session.isPaired,
                session.isWatchAppInstalled
            else { return }
            try? session.updateApplicationContext([AstralConfig.serverOverrideDefaultsKey: endpoint])
            pending = nil
        }

        func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {
            guard error == nil, activationState == .activated else { return }
            flush()
        }

        func sessionDidBecomeInactive(_ session: WCSession) {}

        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
    }
#endif
