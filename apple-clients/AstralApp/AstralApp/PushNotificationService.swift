// iOS binding for the push destination runtime: maps UserNotifications authorization and APNs
// registration facts into the AstralCore destination machine, performs enrollment, acknowledgment
// and revocation through PushRest, suppresses foreground system banners in favor of the in-app
// slot, and acknowledges authentication-gated taps. macOS keeps the in-app banner only.

#if os(iOS)
    import AstralCore
    import Foundation
    import UIKit
    import UserNotifications

    @MainActor
    final class PushNotificationService: NSObject, UNUserNotificationCenterDelegate {
        private let machine: PushDestinationMachine
        private let rest: PushRest
        private let tokenProvider: @Sendable () async -> String?
        private let identity: PushIdentity
        private var inAppPresent: ((PushPayload) -> Void)?
        private var started = false
        private var permissionRequestAttempted = false

        static weak var active: PushNotificationService?

        init(
            identity: PushIdentity,
            machine: PushDestinationMachine,
            rest: PushRest,
            tokenProvider: @escaping @Sendable () async -> String?
        ) {
            self.identity = identity
            self.machine = machine
            self.rest = rest
            self.tokenProvider = tokenProvider
            super.init()
            Self.active = self
            UNUserNotificationCenter.current().delegate = self
        }

        func start() {
            if started { return }
            started = true
            execute(machine.onAvailability(supported: true, reason: nil))
            seedDeliveredNotifications()
            refreshAuthorization()
        }

        func setInAppPresent(_ listener: ((PushPayload) -> Void)?) {
            inAppPresent = listener
        }

        func ownerAuthenticated() {
            machine.onLifecycle(.foreground)
            refreshAuthorization()
            execute(machine.retryRegistration())
        }

        func ownerSessionEnded(access: String?) {
            permissionRequestAttempted = false
            Task { [rest, deviceId = identity.deviceId] in
                let outcome = await rest.revoke(token: access, deviceId: deviceId)
                NSLog("push destination revoke on session end: \(outcome)")
            }
            for notificationId in machine.accepted {
                machine.onDismissed(notificationId)
            }
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }

        func shouldOfferPermissionRequest() -> Bool {
            return machine.permission == .notDetermined
        }

        func requestAuthorizationIfNeeded() {
            if permissionRequestAttempted { return }
            permissionRequestAttempted = true
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refreshAuthorization()
                }
            }
        }

        func refreshAuthorization() {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let granted: Bool
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral: granted = true
                    default: granted = false
                    }
                    let effects = self.machine.onPermissionReport(granted: granted, notificationsAuthorized: granted)
                    self.execute(effects)
                    if granted {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
        }

        func handleRegisteredDeviceToken(_ deviceToken: Data) {
            let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
            execute(machine.onDeviceToken(hex))
        }

        func handleRegistrationFailure() {
            execute(machine.onTokenRequestFailed(transient: true, code: "registration_failed"))
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            machine.onLifecycle(.foreground)
            let data = Self.flattened(notification.request.content.userInfo)
            let receipt = machine.onForegroundDelivery(data)
            apply(receipt)
            return []
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            machine.onLifecycle(.background)
            let data = Self.flattened(response.notification.request.content.userInfo)
            let receipt = machine.onSystemDelivery(data)
            apply(receipt)
        }

        private func seedDeliveredNotifications() {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { [weak self] notifications in
                let ids = notifications.compactMap { $0.request.content.userInfo["notification_id"] as? String }
                DispatchQueue.main.async {
                    self?.machine.seedAccepted(ids)
                }
            }
        }

        private func apply(_ receipt: PushMessageReceipt) {
            switch receipt {
            case .accepted(let payload, let effects, _):
                self.inAppPresent?(payload)
                execute(effects)
            case .duplicate, .malformed, .notPermitted, .unsupported:
                break
            }
        }

        private func execute(_ effects: [PushEffect]) {
            for effect in effects {
                switch effect {
                case .requestToken:
                    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                case .enrollDestination(let deviceId, let platform, let token, let label, _):
                    Task { [rest, tokenProvider] in
                        let outcome = await rest.enroll(
                            token: await tokenProvider(), deviceId: deviceId, platform: platform,
                            pushToken: token, label: label)
                        switch outcome {
                        case .accepted:
                            _ = machine.onEnrollmentAccepted()
                        case .rejected(let transient, let code):
                            _ = machine.onEnrollmentRejected(transient: transient, code: code)
                        case .unauthenticated:
                            _ = machine.onEnrollmentRejected(transient: true, code: "unauthenticated")
                        }
                    }
                case .acknowledge(let deviceId, let notificationId):
                    Task { [rest, tokenProvider] in
                        let outcome = await rest.acknowledge(
                            token: await tokenProvider(), deviceId: deviceId, notificationId: notificationId)
                        NSLog("push delivery acknowledge: \(outcome)")
                    }
                case .cancelPresented:
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                }
            }
        }

        static func flattened(_ userInfo: [AnyHashable: Any]) -> [String: String] {
            var output: [String: String] = [:]
            for key in ["notification_id", "title", "body", "level", "chat_id"] {
                if let value = userInfo[key] as? String { output[key] = value }
            }
            if let aps = userInfo["aps"] as? [String: Any] {
                if let alert = aps["alert"] as? [String: Any] {
                    if output["title"] == nil, let title = alert["title"] as? String { output["title"] = title }
                    if output["body"] == nil, let body = alert["body"] as? String { output["body"] = body }
                } else if output["body"] == nil, let alert = aps["alert"] as? String {
                    output["body"] = alert
                }
            }
            return output
        }
    }

    @MainActor
    final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            PushNotificationService.active?.handleRegisteredDeviceToken(deviceToken)
        }

        func application(
            _ application: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {
            PushNotificationService.active?.handleRegistrationFailure()
        }
    }
#endif
