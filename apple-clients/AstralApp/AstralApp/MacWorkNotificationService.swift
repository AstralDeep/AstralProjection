// Delivers privacy-safe macOS work notifications and a pending-approval badge for AppModel.
// Alerts carry kind-only text plus opaque ids, never approve or deny actions, tool arguments or output.
// All event admission is based on host-authorized model state, persisted owner settings and injected system capabilities.
#if os(macOS)
    import AppKit
    import CryptoKit
    import Foundation
    import UserNotifications

    @MainActor
    struct MacWorkNotificationSystem {
        enum Authorization: Equatable { case authorized, denied, notDetermined }

        var authorization: () async -> Authorization
        var requestAuthorization: () async -> Bool
        var deliver: (UNNotificationRequest) async throws -> Void
        var setBadge: (String?) -> Void
        var removeAllDelivered: () -> Void
        var removeAllPending: () -> Void
        var setDelegate: (UNUserNotificationCenterDelegate?) -> Void
        var appIsActive: () -> Bool

        static var live: Self {
            let center = UNUserNotificationCenter.current()
            return Self(
                authorization: {
                    await withCheckedContinuation { continuation in
                        center.getNotificationSettings { settings in
                            let value: Authorization
                            switch settings.authorizationStatus {
                            case .authorized, .provisional, .ephemeral: value = .authorized
                            case .denied: value = .denied
                            default: value = .notDetermined
                            }
                            continuation.resume(returning: value)
                        }
                    }
                },
                requestAuthorization: {
                    (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
                },
                deliver: { request in try await center.add(request) },
                setBadge: { NSApplication.shared.dockTile.badgeLabel = $0 },
                removeAllDelivered: { center.removeAllDeliveredNotifications() },
                removeAllPending: { center.removeAllPendingNotificationRequests() },
                setDelegate: { center.delegate = $0 },
                appIsActive: { NSApplication.shared.isActive })
        }
    }

    enum MacWorkNotificationKind: String, CaseIterable, Equatable {
        case approval
        case question
        case finished
        case failed

        var title: String {
            switch self {
            case .approval: return "Approval needed"
            case .question: return "AstralDeep has a question"
            case .finished: return "Chat turn finished"
            case .failed: return "Chat turn failed"
            }
        }

        var body: String {
            switch self {
            case .approval: return "Open AstralDeep to review a pending approval."
            case .question: return "Open AstralDeep to read and answer it."
            case .finished: return "Open AstralDeep to view its status."
            case .failed: return "Open AstralDeep to see what happened."
            }
        }
    }

    enum MacWorkNotificationMode: String, CaseIterable, Equatable {
        case never
        case onlyInBackground
        case always
    }

    struct MacWorkNotificationSettings: Equatable {
        var mode: MacWorkNotificationMode = .onlyInBackground
        var enabledKinds: Set<MacWorkNotificationKind> = Set(MacWorkNotificationKind.allCases)
        var includeChatTitle = false

        func isEnabled(_ kind: MacWorkNotificationKind) -> Bool {
            enabledKinds.contains(kind)
        }
    }

    struct MacNotificationReveal: Equatable {
        let requestId: String
        let token: UUID
    }

    @MainActor
    final class MacWorkNotificationService: NSObject, UNUserNotificationCenterDelegate {
        private static let modeKey = "notifications.mode"
        private static let kindsKey = "notifications.enabledKinds"
        private static let chatTitleKey = "notifications.includeChatTitle"
        private static let maximumTrackedEvents = 256

        private let system: MacWorkNotificationSystem
        private let defaults: UserDefaults?
        private(set) var settings = MacWorkNotificationSettings()
        private var ownerScope: String?
        private var deliveredEvents: Set<String> = []
        private var pendingEvents: Set<String> = []
        private var eventOrder: [String] = []
        private var pendingApprovalCount = 0
        var tapHandler: ((String, String?) -> Void)?

        convenience init() {
            self.init(system: .live, defaults: .standard)
        }

        init(system: MacWorkNotificationSystem = .live, defaults: UserDefaults?) {
            self.system = system
            self.defaults = defaults
            if let defaults {
                if let stored = defaults.string(forKey: Self.modeKey),
                    let mode = MacWorkNotificationMode(rawValue: stored)
                {
                    settings.mode = mode
                }
                if let stored = defaults.stringArray(forKey: Self.kindsKey) {
                    settings.enabledKinds = Set(stored.compactMap(MacWorkNotificationKind.init(rawValue:)))
                }
                settings.includeChatTitle = defaults.bool(forKey: Self.chatTitleKey)
            }
            super.init()
            system.setDelegate(self)
        }

        func updateSettings(_ newSettings: MacWorkNotificationSettings) {
            settings = newSettings
            if let defaults {
                defaults.set(newSettings.mode.rawValue, forKey: Self.modeKey)
                defaults.set(
                    MacWorkNotificationKind.allCases.filter { newSettings.isEnabled($0) }.map(\.rawValue),
                    forKey: Self.kindsKey)
                defaults.set(newSettings.includeChatTitle, forKey: Self.chatTitleKey)
            }
        }

        func requestPermission() async -> Bool {
            switch await system.authorization() {
            case .authorized: return true
            case .denied: return false
            case .notDetermined: return await system.requestAuthorization()
            }
        }

        func permissionState() async -> MacWorkNotificationSystem.Authorization {
            await system.authorization()
        }

        func setPendingApprovals(_ count: Int, ownerScope: String?) {
            if self.ownerScope != ownerScope {
                self.ownerScope = ownerScope
                deliveredEvents.removeAll()
                pendingEvents.removeAll()
                eventOrder.removeAll()
                system.removeAllDelivered()
                system.removeAllPending()
            }
            pendingApprovalCount = max(0, count)
            system.setBadge(pendingApprovalCount == 0 ? nil : String(pendingApprovalCount))
        }

        func approvalRequired(
            eventID: String, ownerScope: String?, chatId: String?, chatTitle: String? = nil
        ) async {
            await emit(kind: .approval, eventID: eventID, ownerScope: ownerScope, chatId: chatId, chatTitle: chatTitle)
        }

        func questionRequired(
            eventID: String, ownerScope: String?, chatId: String?, chatTitle: String? = nil
        ) async {
            await emit(kind: .question, eventID: eventID, ownerScope: ownerScope, chatId: chatId, chatTitle: chatTitle)
        }

        func workFinished(eventID: String, ownerScope: String?, chatId: String?, chatTitle: String? = nil) async {
            await emit(kind: .finished, eventID: eventID, ownerScope: ownerScope, chatId: chatId, chatTitle: chatTitle)
        }

        func turnFailed(eventID: String, ownerScope: String?, chatId: String?, chatTitle: String? = nil) async {
            await emit(kind: .failed, eventID: eventID, ownerScope: ownerScope, chatId: chatId, chatTitle: chatTitle)
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
        ) async {
            handleTap(userInfo: response.notification.request.content.userInfo)
        }

        func handleTap(userInfo: [AnyHashable: Any]) {
            guard let chatId = userInfo["chat_id"] as? String, !chatId.isEmpty else { return }
            let requestId = userInfo["request_id"] as? String
            tapHandler?(chatId, requestId)
        }

        private func emit(
            kind: MacWorkNotificationKind, eventID: String, ownerScope: String?, chatId: String?, chatTitle: String?
        ) async {
            guard let ownerScope, !ownerScope.isEmpty, !eventID.isEmpty, self.ownerScope == ownerScope else {
                return
            }
            let key = Self.eventKey(ownerScope: ownerScope, eventID: eventID, kind: kind)
            guard !deliveredEvents.contains(key), pendingEvents.insert(key).inserted else { return }
            defer { pendingEvents.remove(key) }
            guard await system.authorization() == .authorized, self.ownerScope == ownerScope, admits(kind: kind)
            else { return }
            let content = UNMutableNotificationContent()
            content.title = Self.alertTitle(kind: kind, chatTitle: chatTitle, settings: settings)
            content.body = kind.body
            content.sound = .default
            var userInfo: [String: String] = ["kind": kind.rawValue]
            if let chatId, !chatId.isEmpty { userInfo["chat_id"] = chatId }
            if kind == .approval { userInfo["request_id"] = eventID }
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            do {
                try await system.deliver(request)
                deliveredEvents.insert(key)
                eventOrder.append(key)
                if eventOrder.count > Self.maximumTrackedEvents { deliveredEvents.remove(eventOrder.removeFirst()) }
            } catch {
                return
            }
        }

        private func admits(kind: MacWorkNotificationKind) -> Bool {
            guard settings.isEnabled(kind) else { return false }
            switch settings.mode {
            case .never:
                return false
            case .onlyInBackground:
                return !system.appIsActive()
            case .always:
                return kind == .question ? !system.appIsActive() : true
            }
        }

        private static func alertTitle(
            kind: MacWorkNotificationKind, chatTitle: String?, settings: MacWorkNotificationSettings
        ) -> String {
            guard settings.includeChatTitle, let chatTitle, let suffix = sanitizedTitleSuffix(chatTitle) else {
                return kind.title
            }
            return "\(kind.title) — \(suffix)"
        }

        private static func sanitizedTitleSuffix(_ title: String) -> String? {
            let collapsed = title
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
                .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !collapsed.isEmpty else { return nil }
            return String(collapsed.prefix(60))
        }

        private static func eventKey(ownerScope: String, eventID: String, kind: MacWorkNotificationKind) -> String {
            let digest = SHA256.hash(data: Data("\(ownerScope)|\(kind.rawValue)|\(eventID)".utf8))
            return "astraldeep-work-\(digest.map { String(format: "%02x", $0) }.joined())"
        }

        static func stableEventID(chatId: String?, level: String, title: String, body: String) -> String {
            let digest = SHA256.hash(data: Data("\(chatId ?? "")|\(level)|\(title)|\(body)".utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
