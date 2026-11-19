// Routes iOS application-delegate callbacks into the mesh background wake, the local notice adapter and the voice
// model background session. AstralAppMain installs it through UIApplicationDelegateAdaptor, and it becomes the
// notification-center delegate only while local notices are enabled.

#if os(iOS)
    import AstralCore
    import UIKit
    import UserNotifications

    @MainActor
    final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            if IOSNotificationAdapter.enabled() { UNUserNotificationCenter.current().delegate = self }
            return true
        }

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
            IOSNotificationAdapter.active?.applicationWillTerminate()
        }

        func application(
            _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) { IOSNotificationAdapter.active?.didRegister(deviceToken: deviceToken) }

        func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
            IOSNotificationAdapter.active?.didFailToRegister()
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions
        {
            Self.presentation(notification.request.content.userInfo)
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse)
            async
        {
            let request = response.notification.request
            Self.respond(
                identifier: request.identifier, userInfo: request.content.userInfo, action: response.actionIdentifier)
        }

        static func presentation(_ userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
            guard LocalNoticePayload.claims(userInfo) else { return [] }
            return IOSNotificationAdapter.active?.willPresent(userInfo: userInfo) ?? []
        }

        static func respond(identifier: String, userInfo: [AnyHashable: Any], action: String) {
            guard LocalNoticePayload.claims(userInfo) else { return }
            IOSNotificationAdapter.active?.didReceive(identifier: identifier, userInfo: userInfo, action: action)
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
