// iOS OS adapter for content-free local mesh notices: permission, APNs registration and token rotation, minimal
// opaque payloads, foreground presentation, tap routing, dismissal cleanup and lifecycle. Off unless the bundle flag
// is set.
#if os(iOS)
    import AstralCore
    import Foundation
    import OSLog
    import UIKit
    import UserNotifications

    @MainActor
    protocol LocalNoticeCenter: AnyObject {
        func authorizationStatus() async -> LocalNoticePermission.Reported
        func requestAuthorization() async
        func setCategories(_ categories: Set<UNNotificationCategory>)
        func add(_ request: UNNotificationRequest) async throws
        func deliveredIdentifiers() async -> [String]
        func removeDelivered(_ identifiers: [String])
    }

    @MainActor
    protocol RemoteNotificationRegistrar: AnyObject {
        func register()
    }

    @MainActor
    final class SystemLocalNoticeCenter: LocalNoticeCenter {
        private let injected: UNUserNotificationCenter?
        private var center: UNUserNotificationCenter { injected ?? .current() }

        init(center: UNUserNotificationCenter? = nil) { injected = center }

        func authorizationStatus() async -> LocalNoticePermission.Reported {
            switch await center.notificationSettings().authorizationStatus {
            case .authorized: return .authorized
            case .provisional: return .provisional
            case .ephemeral: return .ephemeral
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        }

        func requestAuthorization() async { _ = try? await center.requestAuthorization(options: [.alert, .badge]) }
        func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
        func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
        func deliveredIdentifiers() async -> [String] {
            await center.deliveredNotifications().map { $0.request.identifier }
        }
        func removeDelivered(_ identifiers: [String]) {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    @MainActor
    final class SystemRemoteNotificationRegistrar: RemoteNotificationRegistrar {
        func register() { UIApplication.shared.registerForRemoteNotifications() }
    }

    @MainActor
    final class IOSNotificationAdapter {
        struct Route: Equatable {
            let ref: LocalNoticeRef
            let chatId: String?
        }

        enum PostResult: Equatable {
            case posted, disabled, foreground, notPermitted, duplicate, failed
        }

        enum Registration: Equatable {
            case idle
            case requested
            case registered(fingerprint: String)
            case retrying(attempt: Int)
            case exhausted
        }

        static let infoKey = "ASTRALLocalMeshNotifications"
        static let categoryIdentifier = "astral.mesh.notice"
        static let title = "AstralDeep"
        static let body = "New activity in your mesh. Open AstralDeep to view it."
        static weak var active: IOSNotificationAdapter?

        static func enabled(in bundle: Bundle = .main) -> Bool {
            bundle.object(forInfoDictionaryKey: infoKey) as? Bool == true
        }

        let isEnabled: Bool
        private(set) var permission: LocalNoticePermission?
        private(set) var registration: Registration = .idle
        private(set) var pendingRoute: Route?
        private(set) var foreground = false
        private(set) var lastRejection: LocalNoticeRejection?

        var onToken: ((String) -> Void)?
        var onPermissionChange: ((LocalNoticePermission) -> Void)?
        var onRoute: ((Route) -> Bool)? {
            didSet { resolvePendingRoute() }
        }

        private let center: any LocalNoticeCenter
        private let registrar: any RemoteNotificationRegistrar
        private let retryPolicy: LocalNoticeRetryPolicy
        private let scheduleRetry: @MainActor (Int, @escaping @MainActor () -> Void) -> Void
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AstralDeep", category: "local-notice")
        private var ledger: LocalNoticeLedger
        private var tracker = LocalNoticeTokenTracker()
        private var chats: [LocalNoticeRef: String] = [:]
        private var failures = 0

        init(
            isEnabled: Bool,
            center: any LocalNoticeCenter,
            registrar: any RemoteNotificationRegistrar,
            retryPolicy: LocalNoticeRetryPolicy = LocalNoticeRetryPolicy(),
            ledgerCapacity: Int = 128,
            scheduleRetry: @escaping @MainActor (Int, @escaping @MainActor () -> Void) -> Void =
                IOSNotificationAdapter.sleepThen
        ) {
            self.isEnabled = isEnabled
            self.center = center
            self.registrar = registrar
            self.retryPolicy = retryPolicy
            self.scheduleRetry = scheduleRetry
            self.ledger = LocalNoticeLedger(capacity: ledgerCapacity)
        }

        static func live() -> IOSNotificationAdapter {
            IOSNotificationAdapter(
                isEnabled: enabled(), center: SystemLocalNoticeCenter(), registrar: SystemRemoteNotificationRegistrar())
        }

        nonisolated static func sleepThen(_ seconds: Int, _ work: @escaping @MainActor () -> Void) {
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                work()
            }
        }

        func start() async {
            guard isEnabled else { return }
            let category = UNNotificationCategory(
                identifier: Self.categoryIdentifier, actions: [], intentIdentifiers: [],
                options: [.customDismissAction])
            center.setCategories([category])
            await refreshPermission()
            await requestAuthorizationIfNeeded()
            for identifier in await center.deliveredIdentifiers() {
                if let ref = Self.ref(fromIdentifier: identifier) { ledger.insert(ref) }
            }
            requestRegistration()
        }

        func requestAuthorizationIfNeeded() async {
            guard isEnabled, permission == nil || permission?.canRequest == true else { return }
            if permission == nil { await refreshPermission() }
            guard permission?.canRequest == true else { return }
            await center.requestAuthorization()
            await refreshPermission()
        }

        func refreshPermission() async {
            guard isEnabled else { return }
            let next = LocalNoticePermission.next(previous: permission, reported: await center.authorizationStatus())
            guard next != permission else { return }
            permission = next
            logger.info("local notice permission \(String(describing: next), privacy: .public)")
            if next == .revoked { await clearDelivered() }
            onPermissionChange?(next)
        }

        func requestRegistration() {
            guard isEnabled, registration != .requested else { return }
            registration = .requested
            registrar.register()
        }

        func didRegister(deviceToken: Data) {
            guard isEnabled else { return }
            switch tracker.receive(deviceToken) {
            case .invalid:
                didFailToRegister()
            case .unchanged:
                failures = 0
                registration = .registered(fingerprint: tracker.fingerprint!)
            case .first(let fingerprint):
                accept(deviceToken, fingerprint: fingerprint, rotated: false)
            case .rotated(_, let fingerprint):
                accept(deviceToken, fingerprint: fingerprint, rotated: true)
            }
        }

        private func accept(_ token: Data, fingerprint: String, rotated: Bool) {
            failures = 0
            registration = .registered(fingerprint: fingerprint)
            let label = LocalNoticeTokenTracker.redacted(fingerprint)
            logger.info("APNs token \(rotated ? "rotated" : "registered", privacy: .public) \(label, privacy: .public)")
            onToken?(LocalNoticeTokenTracker.hex(token))
        }

        func didFailToRegister() {
            guard isEnabled else { return }
            failures += 1
            guard let delay = retryPolicy.delay(afterFailure: failures) else {
                registration = .exhausted
                logger.error("APNs registration failed; retries exhausted")
                return
            }
            let attempt = failures
            registration = .retrying(attempt: attempt)
            logger.error("APNs registration failed; retry \(attempt, privacy: .public) in \(delay, privacy: .public)s")
            scheduleRetry(delay) { [weak self] in
                guard let self, self.registration == .retrying(attempt: attempt) else { return }
                self.registration = .idle
                self.requestRegistration()
            }
        }

        @discardableResult
        func post(_ ref: LocalNoticeRef, chatId: String? = nil) async -> PostResult {
            guard isEnabled else { return .disabled }
            guard !foreground else { return .foreground }
            if permission == nil { await refreshPermission() }
            guard permission?.allowsPosting == true else { return .notPermitted }
            guard ledger.insert(ref) else { return .duplicate }
            let content = UNMutableNotificationContent()
            content.title = Self.title
            content.body = Self.body
            content.userInfo = LocalNoticePayload.userInfo(ref)
            content.categoryIdentifier = Self.categoryIdentifier
            content.threadIdentifier = Self.categoryIdentifier
            let request = UNNotificationRequest(
                identifier: LocalNoticePayload.identifier(ref), content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                ledger.remove(ref)
                return .failed
            }
            if let chatId { chats[ref] = chatId }
            chats = chats.filter { ledger.contains($0.key) }
            return .posted
        }

        func willPresent(userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
            guard isEnabled, accept(userInfo) != nil else { return [] }
            return [.banner, .list]
        }

        func didReceive(identifier: String, userInfo: [AnyHashable: Any], action: String) {
            guard isEnabled, let ref = accept(userInfo) else { return }
            switch action {
            case UNNotificationDismissActionIdentifier:
                chats[ref] = nil
                center.removeDelivered([identifier])
            case UNNotificationDefaultActionIdentifier:
                center.removeDelivered([identifier])
                pendingRoute = Route(ref: ref, chatId: chats[ref])
                resolvePendingRoute()
            default:
                break
            }
        }

        func markHandled(_ ref: LocalNoticeRef) {
            chats[ref] = nil
            if pendingRoute?.ref == ref { pendingRoute = nil }
            center.removeDelivered([LocalNoticePayload.identifier(ref)])
        }

        func resolvePendingRoute() {
            guard foreground, let route = pendingRoute, let onRoute, onRoute(route) else { return }
            if pendingRoute == route { pendingRoute = nil }
            chats[route.ref] = nil
        }

        private func accept(_ userInfo: [AnyHashable: Any]) -> LocalNoticeRef? {
            switch LocalNoticePayload.decode(userInfo) {
            case .success(let ref):
                return ref
            case .failure(let rejection):
                lastRejection = rejection
                logger.error("rejected local notice payload \(String(describing: rejection), privacy: .public)")
                return nil
            }
        }

        func sceneDidBecomeActive() async {
            foreground = true
            guard isEnabled else { return }
            await refreshPermission()
            if registration == .exhausted || registration == .idle {
                failures = 0
                registration = .idle
                requestRegistration()
            }
            resolvePendingRoute()
        }

        func sceneDidEnterBackground() { foreground = false }

        func applicationWillTerminate() {
            foreground = false
            pendingRoute = nil
            chats.removeAll()
        }

        private func clearDelivered() async {
            let ours = await center.deliveredIdentifiers().filter { Self.ref(fromIdentifier: $0) != nil }
            if !ours.isEmpty { center.removeDelivered(ours) }
            chats.removeAll()
            pendingRoute = nil
        }

        private static func ref(fromIdentifier identifier: String) -> LocalNoticeRef? {
            guard identifier.hasPrefix(LocalNoticePayload.identifierPrefix) else { return nil }
            return LocalNoticeRef(String(identifier.dropFirst(LocalNoticePayload.identifierPrefix.count)))
        }
    }
#endif
