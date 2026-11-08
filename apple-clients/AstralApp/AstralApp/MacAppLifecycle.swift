// Subscribes to app-wide Mac events for the life of the process. The app keeps running after its main
// window closes, so quit cleanup and lock handling cannot live in the window's view tree.

#if os(macOS)
    import AVFoundation
    import AppKit

    @MainActor
    final class MacAppLifecycle {
        struct Handlers {
            let sessionLocked: @MainActor () -> Void
            let screensSlept: @MainActor () -> Void
            let sessionUnlocked: @MainActor () -> Void
            let connectionMayHaveChanged: @MainActor () -> Void
            let audioConfigurationChanged: @MainActor () -> Void
            let willTerminate: @MainActor () -> Void

            static func live(_ model: AppModel) -> Handlers {
                Handlers(
                    sessionLocked: {
                        model.voiceSessionLocked()
                        model.macComputerHost.sessionLocked()
                    },
                    screensSlept: { model.macComputerHost.sessionLocked() },
                    sessionUnlocked: { model.voiceSessionUnlocked() },
                    connectionMayHaveChanged: { model.verifyConnection() },
                    audioConfigurationChanged: { model.voiceAudioEngineConfigurationChanged() },
                    willTerminate: {
                        model.voiceApplicationWillTerminate()
                        model.computerApplicationWillTerminate()
                    })
            }
        }

        private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

        init(
            handlers: Handlers,
            appCenter: NotificationCenter = .default,
            workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        ) {
            func observe(
                _ center: NotificationCenter, _ name: Notification.Name, queue: OperationQueue? = .main,
                _ handler: @escaping @MainActor () -> Void
            ) {
                let token = center.addObserver(forName: name, object: nil, queue: queue) { _ in
                    MainActor.assumeIsolated { handler() }
                }
                observers.append((center, token))
            }
            observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, handlers.sessionLocked)
            observe(workspaceCenter, NSWorkspace.screensDidSleepNotification, handlers.screensSlept)
            observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, handlers.sessionUnlocked)
            observe(workspaceCenter, NSWorkspace.didWakeNotification, handlers.connectionMayHaveChanged)
            observe(appCenter, NSApplication.didBecomeActiveNotification, handlers.connectionMayHaveChanged)
            observe(appCenter, .AVAudioEngineConfigurationChange, handlers.audioConfigurationChanged)
            // Runs on the posting main thread so cleanup finishes before the process exits.
            observe(appCenter, NSApplication.willTerminateNotification, queue: nil, handlers.willTerminate)
        }

        deinit {
            for observer in observers { observer.center.removeObserver(observer.token) }
        }
    }
#endif
