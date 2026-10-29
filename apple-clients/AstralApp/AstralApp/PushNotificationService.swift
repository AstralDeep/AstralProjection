// Binds iOS notification permission and APNs callbacks to owner/generation-fenced server admission, opaque source navigation, conditional revocation and UI presence.
#if os(iOS)
    import AstralCore
    import CryptoKit
    import CoreFoundation
    import Foundation
    import UIKit
    import UserNotifications

    struct PushDeliveredNotification {
        let identifier: String
        let notificationId: String?
    }

    @MainActor
    struct PushNotificationSystem {
        var settings: (@escaping (UNAuthorizationStatus) -> Void) -> Void
        var request: (@escaping () -> Void) -> Void
        var register: () -> Void
        var unregister: () -> Void
        var delivered: (@escaping ([PushDeliveredNotification]) -> Void) -> Void
        var remove: ([String]) -> Void
        var removeAll: () -> Void

        static var live: Self {
            let center = UNUserNotificationCenter.current()
            return Self(
                settings: { callback in center.getNotificationSettings { callback($0.authorizationStatus) } },
                request: { callback in center.requestAuthorization(options: [.alert, .badge]) { _, _ in callback() } },
                register: { UIApplication.shared.registerForRemoteNotifications() },
                unregister: { UIApplication.shared.unregisterForRemoteNotifications() },
                delivered: { callback in
                    center.getDeliveredNotifications { notifications in
                        callback(
                            notifications.map {
                                PushDeliveredNotification(
                                    identifier: $0.request.identifier,
                                    notificationId: $0.request.content.userInfo["notification_id"] as? String)
                            })
                    }
                },
                remove: { center.removeDeliveredNotifications(withIdentifiers: $0) },
                removeAll: { center.removeAllDeliveredNotifications() })
        }
    }

    @MainActor
    final class PushNotificationService: NSObject, UNUserNotificationCenterDelegate {
        private var machine: PushDestinationMachine?
        private let rest: PushRest
        private let tokenProvider: @Sendable () async -> String?
        private let identity: PushIdentity
        private let custody: any MeshKeyStorage
        private let system: PushNotificationSystem
        var currentBinding: PushBinding? { machine?.binding }
        private static var destinationTail: Task<Void, Never>?
        private var inAppPresent: ((PushPayload) -> Void)?
        private var sourceOpen: ((PushSource) -> Bool)?
        private var ownerScope: String?
        private var incarnation: String?
        private var bindingScope: String?
        private let incarnationProvider: @MainActor (String) -> String?
        private var lastAccess: String?
        private var epoch = 0
        private var foreground = false
        private var connection: String?
        private var sequence: Int64 = 0
        private var heartbeat: Task<Void, Never>?
        private var pendingTap: String?
        private var permission: UNAuthorizationStatus?
        private var requestAttempted = false
        private(set) var failure: String?
        static weak var active: PushNotificationService?

        init(
            identity: PushIdentity, rest: PushRest, tokenProvider: @escaping @Sendable () async -> String?,
            incarnationProvider: @escaping @MainActor (String) -> String? = { _ in nil },
            system: PushNotificationSystem? = nil,
            custody: any MeshKeyStorage = KeychainMeshKeyStorage(service: "com.personalailabs.astraldeep.push")
        ) {
            self.identity = identity
            self.rest = rest
            self.tokenProvider = tokenProvider
            self.incarnationProvider = incarnationProvider
            self.system = system ?? .live
            self.custody = custody
            super.init()
            Self.active = self
            UNUserNotificationCenter.current().delegate = self
        }

        func start() { refreshAuthorization() }
        func setInAppPresent(_ listener: ((PushPayload) -> Void)?) { inAppPresent = listener }
        func setSourceOpen(_ listener: ((PushSource) -> Bool)?) { sourceOpen = listener }

        func ownerAuthenticated(access: String) {
            guard let scope = pushOwnerScope(serverBase: rest.serverBase, accessToken: access) else { return }
            guard let session = incarnationProvider(access),
                session.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            else {
                if machine != nil { ownerSessionEnded(access: lastAccess) }
                failure = "push_session_custody_required"
                return
            }
            if ownerScope != scope || incarnation != session {
                let initialTap = ownerScope == nil ? pendingTap : nil
                if ownerScope != nil || machine != nil { ownerSessionEnded(access: lastAccess) }
                pendingTap = initialTap
                epoch += 1
                ownerScope = scope
                incarnation = session
                bindingScope = Self.tokenFingerprint(scope + "\u{0}" + session)
                machine = PushDestinationMachine(identity: identity, ownerSessionId: bindingScope!)
                execute(machine!.onAvailability(supported: true))
            }
            lastAccess = access
            machine?.onLifecycle(foreground ? .foreground : .background)
            refreshAuthorization()
            if let machine { execute(machine.retryRegistration()) }
            restartHeartbeat()
            resolvePendingTap()
        }

        func ownerSessionEnded(access: String?) {
            publishPresence(false)
            heartbeat?.cancel()
            heartbeat = nil
            if let machine { execute(machine.endSession(), credential: access ?? lastAccess) }
            clearCustody()
            machine = nil
            ownerScope = nil
            incarnation = nil
            bindingScope = nil
            lastAccess = nil
            pendingTap = nil
            connection = nil
            sequence = 0
            epoch += 1
            system.unregister()
            system.removeAll()
        }

        func sceneChanged(active: Bool, connectionGeneration: String?) {
            foreground = active
            machine?.onLifecycle(active ? .foreground : .background)
            if connection != connectionGeneration {
                publishPresence(false)
                connection = connectionGeneration
                sequence = 0
            }
            if active {
                refreshAuthorization()
                restartHeartbeat()
                resolvePendingTap()
            } else {
                heartbeat?.cancel()
                heartbeat = nil
                publishPresence(false)
            }
        }

        func shouldOfferPermissionRequest() -> Bool {
            ownerScope != nil && permission == .notDetermined && !requestAttempted
        }
        func requestAuthorizationIfNeeded() {
            guard shouldOfferPermissionRequest() else { return }
            requestAttempted = true
            let captured = epoch
            system.request { [weak self] in
                Task { @MainActor in
                    guard let self, self.epoch == captured else { return }
                    self.refreshAuthorization()
                }
            }
        }

        func refreshAuthorization() {
            let captured = epoch
            system.settings { [weak self] status in
                Task { @MainActor in
                    guard let self, self.epoch == captured else { return }
                    self.permission = status
                    guard let machine = self.machine else { return }
                    let granted = [.authorized, .provisional, .ephemeral].contains(status)
                    self.execute(
                        machine.onPermissionReport(
                            granted: granted, notificationsAuthorized: granted,
                            requestCompleted: status != .notDetermined))
                    if status == .denied { self.revokeSavedDestination() }
                    if status == .notDetermined { self.requestAuthorizationIfNeeded() }
                }
            }
        }

        func handleRegisteredDeviceToken(_ deviceToken: Data) {
            guard let machine else { return }
            execute(machine.onDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined()))
        }
        func handleRegistrationFailure() {
            if let machine { execute(machine.onTokenRequestFailed(transient: true, code: "registration_failed")) }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions
        {
            if let id = Self.notificationId(notification.request.content.userInfo) { await admitForeground(id) }
            return []
        }

        func admitForeground(_ id: String) async {
            guard let machine, let binding = machine.binding else { return }
            let captured = epoch
            guard let token = await currentAccess(captured),
                await rest.authorize(
                    token: token, deviceId: binding.deviceId, generation: binding.serverTokenGeneration!,
                    destinationRevision: binding.serverDestinationRevision!,
                    notificationId: id) != nil,
                isCurrent(captured, machine: machine, binding: binding)
            else { return }
            let receipt = machine.onForegroundDelivery(["notification_id": id], binding: binding)
            if case .accepted(_, let effects, _) = receipt {
                if case .decoded(let generic) = decodePushPayload([
                    "notification_id": id, "title": "AstralDeep", "body": "Open Notifications to view an update",
                ]) {
                    inAppPresent?(generic)
                }
                execute(effects, credential: token)
            }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse)
            async
        {
            guard let id = Self.notificationId(response.notification.request.content.userInfo) else { return }
            receiveTap(id)
        }

        func receiveTap(_ id: String) {
            guard id.range(of: "^[A-Za-z0-9._:-]{8,128}$", options: .regularExpression) != nil else { return }
            pendingTap = id
            resolvePendingTap()
        }

        private func currentAccess(_ captured: Int) async -> String? {
            guard captured == epoch, let expected = ownerScope, let token = await tokenProvider(),
                captured == epoch, pushOwnerScope(serverBase: rest.serverBase, accessToken: token) == expected,
                incarnationProvider(token) == incarnation
            else { return nil }
            lastAccess = token
            return token
        }

        private func resolvePendingTap() {
            guard foreground, let connection, let id = pendingTap, let machine, let binding = machine.binding,
                sourceOpen != nil
            else { return }
            let captured = epoch
            pendingTap = nil
            Task {
                guard let token = await currentAccess(captured),
                    let source = await rest.authorize(
                        token: token, deviceId: binding.deviceId, generation: binding.serverTokenGeneration!,
                        destinationRevision: binding.serverDestinationRevision!,
                        notificationId: id),
                    isCurrent(captured, machine: machine, binding: binding)
                else {
                    if epoch == captured { failure = "push_source_unavailable" }
                    return
                }
                guard foreground, self.connection == connection, sourceOpen?(source) == true else {
                    pendingTap = id
                    return
                }
                let result = await rest.acknowledge(token: token, deviceId: binding.deviceId, notificationId: id)
                if isCurrent(captured, machine: machine, binding: binding), result != .acknowledged {
                    failure = "push_ack_unconfirmed"
                }
            }
        }

        private func execute(_ effects: [PushEffect], credential: String? = nil) {
            guard let current = machine else { return }
            let captured = epoch
            let capturedCredential = credential ?? lastAccess
            let capturedIncarnation = incarnation
            for effect in effects {
                switch effect {
                case .requestToken: system.register()
                case .enrollDestination(
                    let deviceId, let platform, let pushToken, let label, let generation, let effectOwner):
                    enqueueDestination { [self] in
                        guard self.epoch == captured, self.machine === current,
                            let token = await self.currentAccess(captured)
                        else { return }
                        guard let snapshot = await self.rest.destinationSnapshot(token: token, deviceId: deviceId)
                        else {
                            if self.epoch == captured { self.failure = "push_destination_unavailable" }
                            _ = current.onEnrollmentRejected(
                                transient: true, code: "destination_unavailable", tokenGeneration: generation)
                            return
                        }
                        let saved = self.savedCustody()
                        let fingerprint = Self.tokenFingerprint(pushToken)
                        let reusable =
                            snapshot.active && saved?["owner_scope"] as? String == effectOwner
                            && saved?["device_id"] as? String == deviceId
                            && saved?["token_generation"] as? Int64 == snapshot.generation
                            && saved?["destination_revision"] as? Int64 == snapshot.revision
                            && saved?["token_fingerprint"] as? String == fingerprint
                            && saved?["session_incarnation"] as? String == capturedIncarnation
                        let outcome: PushEnrollOutcome =
                            reusable
                            ? .accepted(
                                serverTokenGeneration: snapshot.generation, destinationRevision: snapshot.revision)
                            : await self.rest.enroll(
                                token: token, deviceId: deviceId, platform: platform,
                                pushToken: pushToken, label: label, expectedDestinationRevision: snapshot.revision)
                        switch outcome {
                        case .accepted(let serverGeneration, let revision):
                            guard epoch == captured, machine === current, bindingScope == effectOwner,
                                current.tokenGeneration == generation, current.registration == .enrolling
                            else {
                                if Self.active?.machine?.binding?.ownerSessionId == effectOwner,
                                    Self.active?.machine?.binding?.serverTokenGeneration == serverGeneration,
                                    Self.active?.machine?.binding?.serverDestinationRevision == revision
                                {
                                    return
                                }
                                let result = await self.rest.revoke(
                                    token: token, deviceId: deviceId, expectedTokenGeneration: serverGeneration,
                                    expectedDestinationRevision: revision)
                                if result != .revoked && result != .conflict && ownerScope == nil {
                                    failure = "push_revoke_unconfirmed"
                                }
                                return
                            }
                            _ = current.onEnrollmentAccepted(
                                tokenGeneration: generation, serverTokenGeneration: serverGeneration,
                                serverDestinationRevision: revision)
                            guard
                                self.saveCustody(
                                    owner: effectOwner, generation: serverGeneration, revision: revision,
                                    fingerprint: fingerprint, incarnation: capturedIncarnation!)
                            else {
                                self.failure = "push_storage_unavailable"
                                self.ownerSessionEnded(access: token)
                                return
                            }
                            self.seedDelivered(current, binding: current.binding, credential: token, captured: captured)
                            resolvePendingTap()
                        case .rejected(let transient, let code):
                            if epoch == captured && machine === current {
                                _ = current.onEnrollmentRejected(
                                    transient: transient, code: code, tokenGeneration: generation)
                                failure = code
                            }
                        case .unauthenticated:
                            if epoch == captured && machine === current {
                                _ = current.onEnrollmentRejected(
                                    transient: true, code: "unauthenticated", tokenGeneration: generation)
                                failure = "push_authentication_required"
                            }
                        }
                    }
                case .revokeDestination(let binding):
                    if let generation = binding.serverTokenGeneration, let revision = binding.serverDestinationRevision
                    {
                        enqueueDestination { [self] in
                            if Self.active?.machine !== current,
                                Self.active?.machine?.binding?.ownerSessionId == binding.ownerSessionId,
                                Self.active?.machine?.binding?.serverTokenGeneration == generation,
                                Self.active?.machine?.binding?.serverDestinationRevision == revision
                            {
                                return
                            }
                            let result = await self.rest.revoke(
                                token: capturedCredential, deviceId: binding.deviceId,
                                expectedTokenGeneration: generation, expectedDestinationRevision: revision)
                            if result != .revoked && result != .conflict && (epoch == captured || ownerScope == nil) {
                                failure = "push_revoke_unconfirmed"
                            }
                        }
                    }
                case .acknowledge(let deviceId, let id):
                    Task {
                        let result = await rest.acknowledge(
                            token: capturedCredential, deviceId: deviceId, notificationId: id)
                        if epoch == captured && result != .acknowledged { failure = "push_ack_unconfirmed" }
                    }
                case .cancelPresented(let ids):
                    let generation = current.tokenGeneration
                    system.delivered { notifications in
                        let requestIds = notifications.filter { note in
                            note.notificationId.map { ids.contains($0) } == true
                        }.map { $0.identifier }
                        Task { @MainActor in
                            if self.epoch == captured && self.machine === current
                                && current.tokenGeneration == generation
                            {
                                self.system.remove(requestIds)
                            }
                        }
                    }
                }
            }
        }

        private func enqueueDestination(_ operation: @escaping @MainActor () async -> Void) {
            let previous = Self.destinationTail
            Self.destinationTail = Task { @MainActor in
                await previous?.value
                await operation()
            }
        }

        private func saveCustody(
            owner: String, generation: Int64, revision: Int64, fingerprint: String, incarnation: String
        ) -> Bool {
            do {
                let data = try JSONSerialization.data(withJSONObject: [
                    "owner_scope": owner, "device_id": identity.deviceId, "token_generation": generation,
                    "destination_revision": revision, "token_fingerprint": fingerprint,
                    "session_incarnation": incarnation,
                ])
                try custody.save(data, key: "binding")
                return true
            } catch { return false }
        }

        private func savedCustody() -> [String: Any]? {
            guard let data = try? custody.load("binding") else { return nil }
            guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                Set(row.keys)
                    == Set([
                        "owner_scope", "device_id", "token_generation", "destination_revision", "token_fingerprint",
                        "session_incarnation",
                    ]),
                row["device_id"] as? String == identity.deviceId
            else { return nil }
            for key in ["owner_scope", "token_fingerprint", "session_incarnation"] {
                guard let value = row[key] as? String,
                    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                else { return nil }
            }
            for key in ["token_generation", "destination_revision"] {
                guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                    !["f", "d"].contains(String(cString: value.objCType)),
                    (1...9_007_199_254_740_991).contains(value.int64Value)
                else { return nil }
            }
            return row
        }

        private static func tokenFingerprint(_ token: String) -> String {
            SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        private func clearCustody() {
            do { try custody.remove("binding") } catch { failure = "push_storage_unavailable" }
        }

        private func revokeSavedDestination() {
            guard let owner = bindingScope, let token = lastAccess,
                let row = savedCustody(),
                row["owner_scope"] as? String == owner, row["session_incarnation"] as? String == incarnation,
                row["device_id"] as? String == identity.deviceId,
                let generation = row["token_generation"] as? Int64, generation > 0,
                let revision = row["destination_revision"] as? Int64, revision > 0
            else { return }
            clearCustody()
            let captured = epoch
            enqueueDestination { [self] in
                let result = await self.rest.revoke(
                    token: token, deviceId: self.identity.deviceId, expectedTokenGeneration: generation,
                    expectedDestinationRevision: revision)
                if self.epoch == captured && result != .revoked && result != .conflict {
                    self.failure = "push_revoke_unconfirmed"
                }
            }
        }

        private func seedDelivered(
            _ current: PushDestinationMachine, binding: PushBinding?, credential: String, captured: Int
        ) {
            guard let binding, let generation = binding.serverTokenGeneration,
                let revision = binding.serverDestinationRevision
            else { return }
            system.delivered { [weak self] notifications in
                let ids = notifications.prefix(64).compactMap { $0.notificationId }
                Task { @MainActor in
                    guard let self else { return }
                    for id in ids {
                        guard self.isCurrent(captured, machine: current, binding: binding) else { return }
                        if await self.rest.authorize(
                            token: credential, deviceId: binding.deviceId, generation: generation,
                            destinationRevision: revision, notificationId: id)
                            != nil,
                            self.isCurrent(captured, machine: current, binding: binding)
                        {
                            current.seedAccepted([id])
                        }
                    }
                }
            }
        }

        private func isCurrent(_ captured: Int, machine current: PushDestinationMachine, binding: PushBinding) -> Bool {
            epoch == captured && machine === current && current.binding == binding
                && bindingScope == binding.ownerSessionId
                && lastAccess.flatMap { incarnationProvider($0) } == incarnation
        }
        private func restartHeartbeat() {
            heartbeat?.cancel()
            guard foreground, connection != nil, ownerScope != nil else { return }
            heartbeat = Task {
                while !Task.isCancelled && foreground && connection != nil {
                    publishPresence(true)
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
        }
        private func publishPresence(_ active: Bool) {
            guard let connection, let token = lastAccess, sequence < 9_007_199_254_740_991 else { return }
            sequence += 1
            let capturedSequence = sequence
            let captured = epoch
            Task {
                let credential = active ? await currentAccess(captured) : token
                let result = await rest.presence(
                    token: credential, deviceId: identity.deviceId, connectionGeneration: connection,
                    sequence: capturedSequence, foreground: active)
                if epoch == captured && self.connection == connection && result == nil {
                    failure = "push_presence_unconfirmed"
                }
            }
        }
        private static func notificationId(_ userInfo: [AnyHashable: Any]) -> String? {
            guard let id = userInfo["notification_id"] as? String,
                id.range(of: "^[A-Za-z0-9._:-]{8,128}$", options: .regularExpression) != nil
            else { return nil }
            return id
        }
    }

    @MainActor
    final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) { PushNotificationService.active?.handleRegisteredDeviceToken(deviceToken) }
        func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
            PushNotificationService.active?.handleRegistrationFailure()
        }
    }
#endif
