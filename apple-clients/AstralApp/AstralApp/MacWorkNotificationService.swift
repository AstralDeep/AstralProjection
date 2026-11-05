// Delivers privacy-safe macOS work notifications and a pending-approval badge for AppModel.
// All event admission is based on host-authorized model state and injected system capabilities.
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
                appIsActive: { NSApplication.shared.isActive })
        }
    }

    @MainActor
    final class MacWorkNotificationService {
        static let longWorkThreshold: TimeInterval = 30
        private let system: MacWorkNotificationSystem
        private var ownerScope: String?
        private var deliveredEvents: Set<String> = []
        private var pendingEvents: Set<String> = []
        private var eventOrder: [String] = []
        private var pendingApprovalCount = 0

        convenience init() {
            self.init(system: .live)
        }

        init(system: MacWorkNotificationSystem) {
            self.system = system
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
            }
            pendingApprovalCount = max(0, count)
            system.setBadge(pendingApprovalCount == 0 ? nil : String(pendingApprovalCount))
        }

        func approvalRequired(eventID: String, ownerScope: String?) async {
            await emit(kind: .approval, eventID: eventID, ownerScope: ownerScope)
        }

        func workFinished(eventID: String, ownerScope: String?, startedAt: Date, now: Date = Date()) async {
            guard now.timeIntervalSince(startedAt) >= Self.longWorkThreshold else { return }
            await emit(kind: .finished, eventID: eventID, ownerScope: ownerScope)
        }

        private enum EventKind: Equatable {
            case approval, finished

            var title: String {
                switch self {
                case .approval: return "Approval needed"
                case .finished: return "Chat turn finished"
                }
            }

            var body: String {
                switch self {
                case .approval: return "Open AstralDeep to review a pending approval."
                case .finished: return "A long-running chat turn finished. Open AstralDeep to view its status."
                }
            }
        }

        private func emit(kind: EventKind, eventID: String, ownerScope: String?) async {
            guard let ownerScope, !ownerScope.isEmpty, !eventID.isEmpty,
                self.ownerScope == ownerScope, !system.appIsActive()
            else { return }
            let key = Self.eventKey(ownerScope: ownerScope, eventID: eventID, kind: kind)
            guard !deliveredEvents.contains(key), pendingEvents.insert(key).inserted else { return }
            guard await system.authorization() == .authorized,
                self.ownerScope == ownerScope, !system.appIsActive()
            else {
                pendingEvents.remove(key)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = kind.title
            content.body = kind.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            do {
                try await system.deliver(request)
                pendingEvents.remove(key)
                deliveredEvents.insert(key)
                eventOrder.append(key)
                if eventOrder.count > 256 { deliveredEvents.remove(eventOrder.removeFirst()) }
            } catch {
                pendingEvents.remove(key)
                return
            }
        }

        private static func eventKey(ownerScope: String, eventID: String, kind: EventKind) -> String {
            let label = kind == .approval ? "approval" : "finished"
            let digest = SHA256.hash(data: Data("\(ownerScope)|\(label)|\(eventID)".utf8))
            return "astraldeep-work-\(digest.map { String(format: "%02x", $0) }.joined())"
        }
    }
#endif
