// Routes iOS application-delegate callbacks into the mesh background wake and the voice model background session.
// AstralAppMain installs it through UIApplicationDelegateAdaptor.

#if os(iOS)
    import UIKit

    @MainActor
    final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
        ) {
            guard let wake = MeshBackgroundWake.active else {
                completionHandler(.noData)
                return
            }
            wake.receive(userInfo) { result in
                switch result {
                case .newData: completionHandler(.newData)
                case .noData: completionHandler(.noData)
                case .failed: completionHandler(.failed)
                }
            }
        }

        func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
            MeshBackgroundWake.active?.cancel()
        }

        func applicationWillTerminate(_ application: UIApplication) {
            MeshBackgroundWake.active?.cancel()
        }

        func application(
            _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            if identifier == VoiceModelStore.backgroundIdentifier {
                VoiceModelBackgroundEvents.store(completionHandler, for: identifier)
            } else {
                completionHandler()
            }
        }
    }
#endif
