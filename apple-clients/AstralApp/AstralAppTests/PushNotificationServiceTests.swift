// Exercises iOS owner lifetimes, delivery/source admission, permission recovery and conditional cleanup using the production service and isolated OS/HTTP seams.
#if os(iOS)
    import AstralCore
    import Foundation
    import UserNotifications
    import UIKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class PushNotificationServiceTests: XCTestCase {
        private let entry = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
        private let device = "device-0001-aa"
        private var service: PushNotificationService?
        private var status: UNAuthorizationStatus = .authorized
        private var registered = 0
        private var unregistered = 0
        private var requested = 0
        private var removed = [String]()
        private var removeAll = 0
        private var delivered = [PushDeliveredNotification]()
        private var access = ""
        private var incarnation: String? = String(repeating: "c", count: 64)
        private var state = HTTPState()
        private var custody = InMemoryMeshKeyStorage()

        override func tearDown() {
            service?.ownerSessionEnded(access: access)
            service = nil
            super.tearDown()
        }

        private func make() -> PushNotificationService {
            access = token("owner-A")
            let rest = PushRest(
                serverBase: URL(string: "https://example.test")!,
                sessionHeaders: { _ in ["Cookie": "astral_session=synthetic", "Origin": "https://example.test"] },
                transport: { [state] request in await state.respond(request) }
            )
            let system = PushNotificationSystem(
                settings: { $0(self.status) },
                request: {
                    self.requested += 1
                    $0()
                },
                register: {
                    self.registered += 1
                    self.service?.handleRegisteredDeviceToken(Data([1, 2, 3]))
                },
                unregister: { self.unregistered += 1 }, delivered: { $0(self.delivered) },
                remove: { self.removed += $0 }, removeAll: { self.removeAll += 1 })
            let result = PushNotificationService(
                identity: PushIdentity(deviceId: device), rest: rest,
                tokenProvider: { [weak self] in await MainActor.run { self?.access } },
                incarnationProvider: { [weak self] _ in self?.incarnation }, system: system, custody: custody
            )
            service = result
            return result
        }

        func testForegroundAdmissionDedupAndCurrentAuthorizedTap() async throws {
            let service = make()
            service.start()
            service.ownerAuthenticated(access: access)
            await wait { service.currentBinding != nil }
            var banners = 0
            service.setInAppPresent { payload in
                banners += 1
                XCTAssertEqual(payload.notificationId, self.entry)
                XCTAssertEqual(payload.title, "AstralDeep")
            }
            service.sceneChanged(active: true, connectionGeneration: "connection-A")
            await service.admitForeground(entry)
            await service.admitForeground(entry)
            await wait { await self.state.count("/api/push/ack") == 1 }
            XCTAssertEqual(banners, 1)
            var opened: PushSource?
            service.setSourceOpen {
                opened = $0
                return true
            }
            service.receiveTap(entry)
            await wait { opened != nil }
            XCTAssertEqual(opened?.chatId, "authorized-chat")
            XCTAssertEqual(opened?.notificationId, entry)
            service.sceneChanged(active: false, connectionGeneration: "connection-A")
            await wait { await self.state.count("/api/notifications/presence") >= 2 }
            let presence = await state.bodies("/api/notifications/presence")
            XCTAssertTrue(presence.contains { $0["foreground"] as? Bool == true })
            XCTAssertTrue(presence.contains { $0["foreground"] as? Bool == false })
        }

        func testForeignSourceAndLateOwnerResultsCannotPresentOrOpen() async {
            let service = make()
            service.ownerAuthenticated(access: access)
            await wait { service.currentBinding != nil }
            await state.denySource()
            var shown = 0
            service.setInAppPresent { _ in shown += 1 }
            await service.admitForeground(entry)
            XCTAssertEqual(shown, 0)
            let acknowledgments = await state.count("/api/push/ack")
            XCTAssertEqual(acknowledgments, 0)
            service.sceneChanged(active: true, connectionGeneration: "connection-A")
            service.setSourceOpen { _ in
                shown += 1
                return true
            }
            service.receiveTap(entry)
            await wait { service.failure == "push_source_unavailable" }
            XCTAssertEqual(shown, 0)
            await state.allowSource()
            access = token("owner-B")
            await service.admitForeground(entry)
            XCTAssertEqual(shown, 0)
            service.ownerSessionEnded(access: token("owner-A"))
            XCTAssertNil(service.currentBinding)
            await wait { await self.state.deletes() > 0 }
            let queries = await state.deleteQueries()
            XCTAssertTrue(queries.allSatisfy { $0 == "expected_token_generation=42&expected_destination_revision=99" })
            XCTAssertEqual(unregistered, 1)
            XCTAssertEqual(removeAll, 1)
        }

        func testPermissionRevocationAfterRestartUsesProtectedCapturedGeneration() async throws {
            let first = make()
            first.ownerAuthenticated(access: access)
            await wait { first.currentBinding != nil }
            XCTAssertNotNil(try custody.load("binding"))
            status = .denied
            let replacement = make()
            replacement.ownerAuthenticated(access: access)
            await wait { await self.state.deletes() > 0 }
            XCTAssertNil(replacement.currentBinding)
            XCTAssertFalse(replacement.shouldOfferPermissionRequest())
            XCTAssertNil(try custody.load("binding"))
            XCTAssertEqual(requested, 0)
        }

        func testColdOwnerReattachesTheCurrentBindingWithoutAnotherClaim() async {
            let first = make()
            first.ownerAuthenticated(access: access)
            await wait { first.currentBinding != nil }
            let captured = first.currentBinding
            let replacement = make()
            replacement.ownerAuthenticated(access: access)
            await wait { replacement.currentBinding != nil }
            XCTAssertEqual(replacement.currentBinding?.serverDestinationRevision, captured?.serverDestinationRevision)
            let enrollments = await state.count("/api/push/destinations")
            XCTAssertEqual(enrollments, 1)
            var opened = [String]()
            replacement.setSourceOpen {
                opened.append($0.notificationId)
                return true
            }
            replacement.sceneChanged(active: true, connectionGeneration: "cold-connection")
            for id in [entry, "58873d61-2e9b-4f38-bc36-bbfa81d78580"] {
                replacement.receiveTap(id)
                await wait { opened.contains(id) }
            }
            XCTAssertEqual(opened.count, 2)
        }

        func testMalformedProtectedCustodyNeverReattachesAnOldClaim() async throws {
            let first = make()
            first.ownerAuthenticated(access: access)
            await wait { first.currentBinding != nil }
            var row = try JSONSerialization.jsonObject(with: try XCTUnwrap(custody.load("binding"))) as! [String: Any]
            row["destination_revision"] = true
            try custody.save(JSONSerialization.data(withJSONObject: row), key: "binding")
            let replacement = make()
            replacement.ownerAuthenticated(access: access)
            await wait { replacement.currentBinding != nil }
            let claims = await state.count("/api/push/destinations")
            XCTAssertEqual(claims, 2)
            XCTAssertEqual(replacement.currentBinding?.serverDestinationRevision, 100)
        }

        func testFreshSameSubjectSessionCannotReuseOldCustodyAndLegacyCannotRegister() async {
            let first = make()
            first.ownerAuthenticated(access: access)
            await wait { first.currentBinding != nil }
            let captured = first.currentBinding
            incarnation = String(repeating: "d", count: 64)
            let replacement = make()
            replacement.ownerAuthenticated(access: access)
            await wait { replacement.currentBinding != nil }
            XCTAssertNotEqual(captured?.ownerSessionId, replacement.currentBinding?.ownerSessionId)
            XCTAssertEqual(replacement.currentBinding?.serverDestinationRevision, 100)
            let claims = await state.count("/api/push/destinations")
            XCTAssertEqual(claims, 2)
            incarnation = nil
            replacement.ownerAuthenticated(access: access)
            XCTAssertNil(replacement.currentBinding)
            XCTAssertEqual(replacement.failure, "push_session_custody_required")
        }

        func testInitialPermissionAndTokenFailureDoNotCreateSuccess() async {
            status = .notDetermined
            let service = make()
            service.ownerAuthenticated(access: access)
            await wait { self.requested > 0 }
            XCTAssertNil(service.currentBinding)
            status = .denied
            service.refreshAuthorization()
            await wait { !service.shouldOfferPermissionRequest() }
            service.handleRegistrationFailure()
            XCTAssertNil(service.currentBinding)
            let enrollments = await state.count("/api/push/destinations")
            XCTAssertEqual(enrollments, 0)
            service.receiveTap("bad")
        }

        func testEnrollmentAndPresenceFailuresRemainVisibleWithoutAValidBinding() async {
            for code in [401, 409, 503] {
                state = HTTPState()
                await state.configure(enrollStatus: code)
                let service = make()
                service.ownerAuthenticated(access: access)
                await wait { service.failure != nil }
                XCTAssertNil(service.currentBinding)
                service.ownerSessionEnded(access: access)
            }
            state = HTTPState()
            await state.configure(snapshotStatus: 503)
            let unavailable = make()
            unavailable.ownerAuthenticated(access: access)
            await wait { unavailable.failure == "push_destination_unavailable" }
            XCTAssertNil(unavailable.currentBinding)
            unavailable.ownerSessionEnded(access: access)
            state = HTTPState()
            let active = make()
            active.ownerAuthenticated(access: access)
            await wait { active.currentBinding != nil }
            await state.configure(ackStatus: 503, presenceStatus: 503)
            active.setInAppPresent { _ in }
            active.sceneChanged(active: true, connectionGeneration: "failure-connection")
            await active.admitForeground(entry)
            await wait { active.failure != nil }
            XCTAssertTrue(["push_ack_unconfirmed", "push_presence_unconfirmed"].contains(active.failure!))
        }

        func testLogoutDuringEnrollmentConditionallyCleansTheLateServerClaim() async {
            await state.holdEnrollment()
            let service = make()
            service.ownerAuthenticated(access: access)
            await wait { await self.state.count("/api/push/destinations") == 1 }
            service.ownerSessionEnded(access: access)
            XCTAssertNil(service.currentBinding)
            await state.configure(revokeStatus: 503)
            await state.releaseEnrollment()
            await wait { service.failure == "push_revoke_unconfirmed" }
            let queries = await state.deleteQueries()
            XCTAssertEqual(queries, ["expected_token_generation=42&expected_destination_revision=99"])
        }

        func testDeliveredSeedCancellationAndBlockedTapUseCurrentOSIdentifiers() async {
            delivered = [PushDeliveredNotification(identifier: "os-request-A", notificationId: entry)]
            let service = make()
            service.ownerAuthenticated(access: access)
            await wait { service.currentBinding != nil }
            await wait { await self.state.count("/api/notifications/inbox/" + self.entry) > 0 }
            var opened = 0
            service.setSourceOpen { _ in
                opened += 1
                return false
            }
            service.sceneChanged(active: true, connectionGeneration: "blocked-connection")
            service.receiveTap(entry)
            await wait { opened == 1 }
            service.setSourceOpen { _ in
                opened += 1
                return true
            }
            service.sceneChanged(active: true, connectionGeneration: "blocked-connection")
            await wait { opened == 2 }
            status = .denied
            service.refreshAuthorization()
            await wait { self.removed.contains("os-request-A") }
            XCTAssertNil(service.currentBinding)
            let delegate = PushNotificationAppDelegate()
            delegate.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: Data([4, 5]))
            delegate.application(
                UIApplication.shared, didFailToRegisterForRemoteNotificationsWithError: CocoaError(.coderInvalidValue))
        }

        private func wait(_ predicate: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line)
            async
        {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await predicate()) {
                if ContinuousClock.now >= deadline {
                    XCTFail("Expected state did not arrive", file: file, line: line)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        private func token(_ subject: String) -> String {
            let claims = try! JSONSerialization.data(withJSONObject: [
                "iss": "https://issuer.test", "sub": subject, "exp": 4_102_444_800,
            ])
            let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
                of: "/", with: "_"
            ).replacingOccurrences(of: "=", with: "")
            return "e30.\(encoded).test"
        }

        private actor HTTPState {
            private var requests = [URLRequest]()
            private var sourceAllowed = true
            private var revision: Int64 = 98
            private var enrollStatus = 200
            private var snapshotStatus = 200
            private var ackStatus = 204
            private var presenceStatus = 200
            private var revokeStatus = 204
            private var hold = false
            private var held: CheckedContinuation<Void, Never>?
            func configure(
                enrollStatus: Int? = nil, snapshotStatus: Int? = nil, ackStatus: Int? = nil, presenceStatus: Int? = nil,
                revokeStatus: Int? = nil
            ) {
                if let enrollStatus { self.enrollStatus = enrollStatus }
                if let snapshotStatus { self.snapshotStatus = snapshotStatus }
                if let ackStatus { self.ackStatus = ackStatus }
                if let presenceStatus { self.presenceStatus = presenceStatus }
                if let revokeStatus { self.revokeStatus = revokeStatus }
            }
            func holdEnrollment() { hold = true }
            func releaseEnrollment() {
                hold = false
                held?.resume()
                held = nil
            }
            func denySource() { sourceAllowed = false }
            func allowSource() { sourceAllowed = true }
            func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
            func deletes() -> Int { requests.filter { $0.httpMethod == "DELETE" }.count }
            func deleteQueries() -> [String] {
                requests.filter { $0.httpMethod == "DELETE" }.compactMap { $0.url?.query }
            }
            func bodies(_ path: String) -> [[String: Any]] {
                requests.filter { $0.url?.path == path }.compactMap {
                    try? JSONSerialization.jsonObject(with: $0.httpBody!) as? [String: Any]
                }
            }
            func respond(_ request: URLRequest) async -> (Int, Data) {
                requests.append(request)
                let path = request.url!.path
                if request.httpMethod == "DELETE" { return (revokeStatus, Data()) }
                var object: Any = [:]
                if path == "/api/push/destinations" {
                    if hold { await withCheckedContinuation { held = $0 } }
                    if enrollStatus != 200 { return (enrollStatus, Data()) }
                    revision += 1
                    object = [
                        "device_id": "device-0001-aa", "platform": "ios", "status": "active", "token_generation": 42,
                        "updated_at": revision,
                    ]
                } else if path.hasPrefix("/api/push/destinations/") {
                    if snapshotStatus != 200 { return (snapshotStatus, Data()) }
                    object = [
                        "device_id": "device-0001-aa", "status": "active", "token_generation": 42,
                        "updated_at": revision,
                        "destination_revision": revision,
                    ]
                } else if path.hasPrefix("/api/push/deliveries/") {
                    object = [
                        [
                            "action": "push.delivery.queued", "device_id": "device-0001-aa", "token_generation": 42,
                            "updated_at": revision, "destination_revision": revision,
                        ]
                    ]
                } else if path.hasPrefix("/api/notifications/inbox/") {
                    if !sourceAllowed { return (404, Data()) }
                    object = [
                        "entry_id": request.url!.lastPathComponent, "revision": 0, "deleted_at": NSNull(),
                        "content": ["chat_id": "authorized-chat"],
                    ]
                } else if path == "/api/notifications/presence" {
                    if presenceStatus != 200 { return (presenceStatus, Data()) }
                    let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    object = [
                        "accepted_sequence": body["sequence"]!,
                        "expires_in_seconds": body["foreground"] as? Bool == true ? 45 : 0,
                    ]
                } else if path == "/api/push/ack" {
                    return (ackStatus, Data())
                }
                return (200, try! JSONSerialization.data(withJSONObject: object))
            }
        }
    }
#endif
