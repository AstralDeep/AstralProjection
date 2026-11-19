// Exercises the iOS local-notice OS adapter through fake notification-center and registrar seams: success, denial,
// revocation, token rotation, registration errors and recovery, malformed/duplicate payloads, and lifecycle changes.
#if os(iOS)
    import AstralCore
    import Foundation
    import UIKit
    import UserNotifications
    import XCTest

    @testable import AstralDeep

    @MainActor
    private final class FakeCenter: LocalNoticeCenter {
        var status: LocalNoticePermission.Reported = .notDetermined
        var grantOnRequest: LocalNoticePermission.Reported = .authorized
        var requests = 0
        var categories: Set<UNNotificationCategory> = []
        var added: [UNNotificationRequest] = []
        var delivered: [String] = []
        var removed: [String] = []
        var addError: Error?

        func authorizationStatus() async -> LocalNoticePermission.Reported { status }
        func requestAuthorization() async {
            requests += 1
            status = grantOnRequest
        }
        func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
        func add(_ request: UNNotificationRequest) async throws {
            if let addError { throw addError }
            added.append(request)
            delivered.append(request.identifier)
        }
        func deliveredIdentifiers() async -> [String] { delivered }
        func removeDelivered(_ identifiers: [String]) {
            removed += identifiers
            delivered.removeAll { identifiers.contains($0) }
        }
    }

    @MainActor
    private final class FakeRegistrar: RemoteNotificationRegistrar {
        var registrations = 0
        func register() { registrations += 1 }
    }

    @MainActor
    final class IOSNotificationAdapterTests: XCTestCase {
        private var center = FakeCenter()
        private var registrar = FakeRegistrar()
        private var retries: [(seconds: Int, work: @MainActor () -> Void)] = []
        private var tokens: [String] = []
        private var permissions: [LocalNoticePermission] = []
        private var routes: [IOSNotificationAdapter.Route] = []
        private var routeReady = true

        private let refA = LocalNoticeRef("mn-aaaaaaaaaaaa")!
        private let refB = LocalNoticeRef("mn-bbbbbbbbbbbb")!
        private let refC = LocalNoticeRef("mn-cccccccccccc")!
        private let tokenA = Data([0x01, 0x02, 0x03, 0x04])
        private let tokenB = Data([0x0a, 0x0b, 0x0c, 0x0d])

        private func make(
            enabled: Bool = true, policy: LocalNoticeRetryPolicy = LocalNoticeRetryPolicy(maxAttempts: 2)
        ) -> IOSNotificationAdapter {
            let adapter = IOSNotificationAdapter(
                isEnabled: enabled, center: center, registrar: registrar, retryPolicy: policy, ledgerCapacity: 8,
                scheduleRetry: { [unowned self] seconds, work in retries.append((seconds, work)) })
            adapter.onToken = { [unowned self] in tokens.append($0) }
            adapter.onPermissionChange = { [unowned self] in permissions.append($0) }
            adapter.onRoute = { [unowned self] route in
                guard routeReady else { return false }
                routes.append(route)
                return true
            }
            return adapter
        }

        private func info(_ ref: LocalNoticeRef) -> [AnyHashable: Any] { LocalNoticePayload.userInfo(ref) }

        private func tap(_ adapter: IOSNotificationAdapter, _ ref: LocalNoticeRef) {
            adapter.didReceive(
                identifier: LocalNoticePayload.identifier(ref), userInfo: info(ref),
                action: UNNotificationDefaultActionIdentifier)
        }

        // MARK: Success

        func testGrantRegisterTokenPresentTapAndRouteEndToEnd() async {
            let adapter = make()
            await adapter.start()

            XCTAssertEqual(center.requests, 1, "a first launch asks once")
            XCTAssertEqual(adapter.permission, .authorized)
            XCTAssertEqual(permissions, [.notDetermined, .authorized])
            XCTAssertEqual(center.categories.map(\.identifier), [IOSNotificationAdapter.categoryIdentifier])
            XCTAssertTrue(center.categories.first!.options.contains(.customDismissAction), "dismissals are reported")
            XCTAssertEqual(registrar.registrations, 1)
            XCTAssertEqual(adapter.registration, .requested)

            adapter.didRegister(deviceToken: tokenA)
            XCTAssertEqual(tokens, ["01020304"])
            XCTAssertEqual(adapter.registration, .registered(fingerprint: pushTokenFingerprint("01020304")))

            let result = await adapter.post(refA, chatId: "chat-1")
            XCTAssertEqual(result, .posted)
            let request = center.added.first!
            XCTAssertEqual(request.identifier, "astral-mesh-mn-aaaaaaaaaaaa")
            XCTAssertNil(request.trigger)
            XCTAssertEqual(request.content.title, IOSNotificationAdapter.title)
            XCTAssertEqual(request.content.body, IOSNotificationAdapter.body)
            XCTAssertEqual(request.content.userInfo as? [String: String], ["astral_local_ref": "mn-aaaaaaaaaaaa"])
            XCTAssertFalse(request.content.body.contains("chat-1"), "no source or content reaches the OS")
            XCTAssertEqual(request.content.categoryIdentifier, IOSNotificationAdapter.categoryIdentifier)

            XCTAssertEqual(adapter.willPresent(userInfo: request.content.userInfo), [.banner, .list])

            await adapter.sceneDidBecomeActive()
            tap(adapter, refA)
            XCTAssertEqual(routes, [IOSNotificationAdapter.Route(ref: refA, chatId: "chat-1")])
            XCTAssertEqual(center.removed, [request.identifier], "a handled notice leaves Notification Center")
            XCTAssertNil(adapter.pendingRoute)
        }

        func testProvisionalPermissionPostsWithoutAPrompt() async {
            center.status = .provisional
            let adapter = make()
            await adapter.start()
            XCTAssertEqual(center.requests, 0)
            XCTAssertEqual(adapter.permission, .provisional)
            let result = await adapter.post(refA)
            XCTAssertEqual(result, .posted)
        }

        // MARK: Flag

        func testDisabledAdapterIsInertAndTheShippedFlagIsOff() async {
            XCTAssertFalse(IOSNotificationAdapter.enabled(), "the product must not advertise push before #52")
            let adapter = make(enabled: false)
            await adapter.start()
            await adapter.requestAuthorizationIfNeeded()
            await adapter.refreshPermission()
            adapter.requestRegistration()
            adapter.didRegister(deviceToken: tokenA)
            adapter.didFailToRegister()
            await adapter.sceneDidBecomeActive()
            let posted = await adapter.post(refA)
            XCTAssertEqual(posted, .disabled)
            XCTAssertEqual(adapter.willPresent(userInfo: info(refA)), [])
            tap(adapter, refA)
            XCTAssertEqual(center.requests, 0)
            XCTAssertEqual(registrar.registrations, 0)
            XCTAssertTrue(center.added.isEmpty && center.categories.isEmpty && tokens.isEmpty && routes.isEmpty)
            XCTAssertNil(adapter.permission)
            XCTAssertTrue(retries.isEmpty)
        }

        // MARK: Denial and revocation

        func testDenialNeverPromptsAgainOrPosts() async {
            center.status = .denied
            let adapter = make()
            await adapter.start()
            await adapter.requestAuthorizationIfNeeded()
            XCTAssertEqual(center.requests, 0)
            XCTAssertEqual(adapter.permission, .denied)
            let result = await adapter.post(refA)
            XCTAssertEqual(result, .notPermitted)
            XCTAssertTrue(center.added.isEmpty)
            XCTAssertEqual(registrar.registrations, 1, "content-free mesh wakes do not need alert permission")
        }

        func testUserDeclinesThePrompt() async {
            center.grantOnRequest = .denied
            let adapter = make()
            await adapter.start()
            XCTAssertEqual(center.requests, 1)
            XCTAssertEqual(adapter.permission, .denied)
            let result = await adapter.post(refA)
            XCTAssertEqual(result, .notPermitted)
        }

        func testRevocationInSettingsClearsOwnNoticesAndRegrantRecovers() async {
            center.status = .authorized
            center.delivered = ["server-notice-1"]
            let adapter = make()
            await adapter.start()
            _ = await adapter.post(refA, chatId: "chat-1")
            _ = await adapter.post(refC)
            tap(adapter, refA)
            XCTAssertNotNil(adapter.pendingRoute, "background tap waits for foreground")
            XCTAssertEqual(center.delivered, ["server-notice-1", LocalNoticePayload.identifier(refC)])

            center.status = .denied
            await adapter.sceneDidBecomeActive()
            XCTAssertEqual(adapter.permission, .revoked)
            XCTAssertEqual(permissions.last, .revoked)
            XCTAssertEqual(center.delivered, ["server-notice-1"], "only this adapter's notices are withdrawn")
            XCTAssertNil(adapter.pendingRoute)
            XCTAssertTrue(routes.isEmpty)
            adapter.sceneDidEnterBackground()
            let blocked = await adapter.post(refB)
            XCTAssertEqual(blocked, .notPermitted)

            center.status = .authorized
            await adapter.sceneDidBecomeActive()
            XCTAssertEqual(adapter.permission, .authorized)
            adapter.sceneDidEnterBackground()
            let recovered = await adapter.post(refB)
            XCTAssertEqual(recovered, .posted)
        }

        // MARK: Token rotation and registration errors

        func testTokenRotationReportsOnlyChangesAndKeepsOnlyAFingerprint() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            adapter.didRegister(deviceToken: tokenA)
            adapter.didRegister(deviceToken: tokenA)
            XCTAssertEqual(tokens, ["01020304"], "an unchanged token is not reported again")
            adapter.didRegister(deviceToken: tokenB)
            XCTAssertEqual(tokens, ["01020304", "0a0b0c0d"])
            guard case .registered(let fingerprint) = adapter.registration else { return XCTFail("registered") }
            XCTAssertEqual(fingerprint, pushTokenFingerprint("0a0b0c0d"))
            XCTAssertNotEqual(fingerprint, "0a0b0c0d")
        }

        func testRegistrationErrorsRetryWithBackoffExhaustAndRecoverOnForeground() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            XCTAssertEqual(registrar.registrations, 1)

            adapter.didFailToRegister()
            XCTAssertEqual(adapter.registration, .retrying(attempt: 1))
            XCTAssertEqual(retries.map(\.seconds), [5])
            retries[0].work()
            XCTAssertEqual(registrar.registrations, 2)

            adapter.didRegister(deviceToken: Data())
            XCTAssertEqual(adapter.registration, .retrying(attempt: 2), "an empty token counts as a failure")
            XCTAssertEqual(retries.map(\.seconds), [5, 10])
            retries[1].work()
            XCTAssertEqual(registrar.registrations, 3)

            adapter.didFailToRegister()
            XCTAssertEqual(adapter.registration, .exhausted)
            XCTAssertEqual(retries.count, 2, "no unbounded retry loop")

            await adapter.sceneDidBecomeActive()
            XCTAssertEqual(registrar.registrations, 4, "returning to the app retries an exhausted registration")
            adapter.didRegister(deviceToken: tokenA)
            XCTAssertEqual(tokens, ["01020304"])
            XCTAssertEqual(adapter.registration, .registered(fingerprint: pushTokenFingerprint("01020304")))

            adapter.didFailToRegister()
            adapter.didRegister(deviceToken: tokenA)
            retries.last!.work()
            XCTAssertEqual(registrar.registrations, 4, "a stale retry cannot re-register after success")
        }

        func testDuplicateRegistrationRequestsAreCoalesced() async {
            let adapter = make()
            adapter.requestRegistration()
            adapter.requestRegistration()
            XCTAssertEqual(registrar.registrations, 1)
        }

        // MARK: Malformed and duplicate payloads

        func testMalformedPayloadsAreRejectedSafely() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            await adapter.sceneDidBecomeActive()

            let contentful: [AnyHashable: Any] = ["astral_local_ref": refA.value, "body": "lab result"]
            XCTAssertEqual(adapter.willPresent(userInfo: contentful), [])
            XCTAssertEqual(adapter.lastRejection, .malformed("unexpected_fields"))
            adapter.didReceive(
                identifier: "astral-mesh-x", userInfo: ["astral_local_ref": "../bad"],
                action: UNNotificationDefaultActionIdentifier)
            XCTAssertEqual(adapter.lastRejection, .malformed("reference_format"))
            adapter.didReceive(
                identifier: "astral-mesh-x", userInfo: ["astral_local_ref": 42],
                action: UNNotificationDefaultActionIdentifier)
            XCTAssertEqual(adapter.lastRejection, .malformed("reference_type"))
            XCTAssertTrue(routes.isEmpty)
            XCTAssertTrue(center.removed.isEmpty)
        }

        func testDuplicatePostsAreDroppedAndFailedPostsCanRetry() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            let first = await adapter.post(refA)
            let second = await adapter.post(refA)
            XCTAssertEqual([first, second], [.posted, .duplicate])
            XCTAssertEqual(center.added.count, 1)

            center.addError = CocoaError(.featureUnsupported)
            let failed = await adapter.post(refB)
            XCTAssertEqual(failed, .failed)
            center.addError = nil
            let retried = await adapter.post(refB)
            XCTAssertEqual(retried, .posted, "a failed post does not poison duplicate suppression")
        }

        func testUnknownActionsAreIgnored() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            await adapter.sceneDidBecomeActive()
            adapter.didReceive(
                identifier: LocalNoticePayload.identifier(refA), userInfo: info(refA), action: "custom.action")
            XCTAssertTrue(routes.isEmpty && center.removed.isEmpty)
        }

        // MARK: Dismissal and handling

        func testDismissalRemovesTheNoticeAndForgetsItsSource() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            _ = await adapter.post(refA, chatId: "chat-1")
            adapter.didReceive(
                identifier: LocalNoticePayload.identifier(refA), userInfo: info(refA),
                action: UNNotificationDismissActionIdentifier)
            XCTAssertEqual(center.removed, [LocalNoticePayload.identifier(refA)])
            await adapter.sceneDidBecomeActive()
            tap(adapter, refA)
            XCTAssertEqual(routes, [IOSNotificationAdapter.Route(ref: refA, chatId: nil)])
        }

        func testMarkHandledWithdrawsTheNoticeAndPendingRoute() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            _ = await adapter.post(refA, chatId: "chat-1")
            tap(adapter, refA)
            XCTAssertNotNil(adapter.pendingRoute)
            adapter.markHandled(refA)
            XCTAssertNil(adapter.pendingRoute)
            XCTAssertTrue(center.delivered.isEmpty)
            await adapter.sceneDidBecomeActive()
            XCTAssertTrue(routes.isEmpty)
        }

        // MARK: Lifecycle

        func testForegroundSuppressesOSNoticesAndBackgroundAllowsThem() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            await adapter.sceneDidBecomeActive()
            let foreground = await adapter.post(refA)
            XCTAssertEqual(foreground, .foreground, "the in-app UI already shows synced changes")
            adapter.sceneDidEnterBackground()
            let background = await adapter.post(refA)
            XCTAssertEqual(background, .posted)
        }

        func testColdLaunchTapWaitsForForegroundAndSourceReadiness() async {
            center.status = .authorized
            center.delivered = [LocalNoticePayload.identifier(refA), "server-notice-1", "astral-mesh-bad ref"]
            routeReady = false
            let adapter = make()
            await adapter.start()
            let reposted = await adapter.post(refA)
            XCTAssertEqual(reposted, .duplicate, "relaunch rebuilds duplicate suppression from the OS")

            tap(adapter, refA)
            XCTAssertEqual(adapter.pendingRoute, IOSNotificationAdapter.Route(ref: refA, chatId: nil))
            await adapter.sceneDidBecomeActive()
            XCTAssertNotNil(adapter.pendingRoute, "the mesh is not open yet")
            routeReady = true
            adapter.resolvePendingRoute()
            XCTAssertEqual(routes, [IOSNotificationAdapter.Route(ref: refA, chatId: nil)])
            XCTAssertNil(adapter.pendingRoute)
        }

        func testRouteHookAttachedLateResolvesThePendingTap() async {
            center.status = .authorized
            let adapter = IOSNotificationAdapter(isEnabled: true, center: center, registrar: registrar)
            await adapter.start()
            await adapter.sceneDidBecomeActive()
            tap(adapter, refA)
            XCTAssertNotNil(adapter.pendingRoute)
            adapter.onRoute = { [unowned self] in
                routes.append($0)
                return true
            }
            XCTAssertEqual(routes.count, 1)
        }

        func testTerminationDropsInMemoryRouting() async {
            center.status = .authorized
            let adapter = make()
            await adapter.start()
            _ = await adapter.post(refA, chatId: "chat-1")
            tap(adapter, refA)
            adapter.applicationWillTerminate()
            XCTAssertNil(adapter.pendingRoute)
            XCTAssertFalse(adapter.foreground)
            await adapter.sceneDidBecomeActive()
            tap(adapter, refA)
            XCTAssertEqual(routes, [IOSNotificationAdapter.Route(ref: refA, chatId: nil)])
        }

        func testAppDelegateForwardsTokenFailureTapAndTerminationToTheActiveAdapter() async {
            let previous = IOSNotificationAdapter.active
            defer { IOSNotificationAdapter.active = previous }
            let adapter = make()
            await adapter.start()
            IOSNotificationAdapter.active = adapter
            let delegate = PushNotificationAppDelegate()

            delegate.application(.shared, didRegisterForRemoteNotificationsWithDeviceToken: tokenA)
            XCTAssertEqual(tokens, [LocalNoticeTokenTracker.hex(tokenA)])
            delegate.application(
                .shared, didFailToRegisterForRemoteNotificationsWithError: CocoaError(.featureUnsupported))
            XCTAssertEqual(adapter.registration, .retrying(attempt: 1))

            adapter.sceneDidEnterBackground()
            let posted = await adapter.post(refA, chatId: "chat-a")
            XCTAssertEqual(posted, .posted)
            XCTAssertEqual(PushNotificationAppDelegate.presentation(info(refA)), [.banner, .list])
            await adapter.sceneDidBecomeActive()
            PushNotificationAppDelegate.respond(
                identifier: LocalNoticePayload.identifier(refA), userInfo: info(refA),
                action: UNNotificationDefaultActionIdentifier)
            XCTAssertEqual(routes, [IOSNotificationAdapter.Route(ref: refA, chatId: "chat-a")])

            routeReady = false
            adapter.sceneDidEnterBackground()
            let second = await adapter.post(refB, chatId: "chat-b")
            XCTAssertEqual(second, .posted)
            PushNotificationAppDelegate.respond(
                identifier: LocalNoticePayload.identifier(refB), userInfo: info(refB),
                action: UNNotificationDefaultActionIdentifier)
            XCTAssertNotNil(adapter.pendingRoute)
            delegate.applicationWillTerminate(.shared)
            XCTAssertNil(adapter.pendingRoute)
        }

        func testAppDelegateIgnoresForeignPayloadsAndAMissingAdapter() async {
            let previous = IOSNotificationAdapter.active
            defer { IOSNotificationAdapter.active = previous }
            let adapter = make()
            await adapter.start()
            IOSNotificationAdapter.active = adapter
            let foreign: [AnyHashable: Any] = ["aps": ["alert": "content"], "notification_id": "other"]

            XCTAssertEqual(PushNotificationAppDelegate.presentation(foreign), [])
            PushNotificationAppDelegate.respond(
                identifier: "other", userInfo: foreign, action: UNNotificationDefaultActionIdentifier)
            XCTAssertNil(adapter.lastRejection, "a payload without the local reference never reaches the adapter")
            XCTAssertTrue(routes.isEmpty)
            XCTAssertTrue(center.removed.isEmpty)

            IOSNotificationAdapter.active = nil
            XCTAssertEqual(PushNotificationAppDelegate.presentation(info(refA)), [])
            PushNotificationAppDelegate.respond(
                identifier: LocalNoticePayload.identifier(refA), userInfo: info(refA),
                action: UNNotificationDefaultActionIdentifier)
            let delegate = PushNotificationAppDelegate()
            delegate.application(.shared, didRegisterForRemoteNotificationsWithDeviceToken: tokenA)
            delegate.application(
                .shared, didFailToRegisterForRemoteNotificationsWithError: CocoaError(.featureUnsupported))
            XCTAssertTrue(tokens.isEmpty)
            XCTAssertTrue(routes.isEmpty)
        }

        func testAppDelegateLeavesTheNotificationCenterAloneWhileTheShippedFlagIsOff() {
            XCTAssertFalse(IOSNotificationAdapter.enabled())
            let delegate = PushNotificationAppDelegate()
            XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: nil))
            XCTAssertFalse(UNUserNotificationCenter.current().delegate === delegate)
        }

        func testLiveFactoryReadsTheBundleFlag() {
            let adapter = IOSNotificationAdapter.live()
            XCTAssertFalse(adapter.isEnabled)
        }

        func testDefaultRetrySchedulerRunsTheRetryAfterItsDelay() async {
            let done = expectation(description: "retry ran")
            IOSNotificationAdapter.sleepThen(0) { done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
        }

        // MARK: OS seam (app host only: the OS center needs an application bundle)

        func testSystemCenterReadsTheOSWithoutPrompting() async {
            let system = SystemLocalNoticeCenter()
            let status = await system.authorizationStatus()
            XCTAssertTrue([.notDetermined, .provisional, .authorized, .ephemeral, .denied].contains(status))
            system.setCategories([])
            system.removeDelivered(["astral-mesh-absent-ref"])
            let delivered = await system.deliveredIdentifiers()
            XCTAssertFalse(delivered.contains("astral-mesh-absent-ref"))
        }

        // MARK: Mesh wake reference

        func testMeshWakeNoticeIsOpaqueAndChangesWithEachSyncedChange() async throws {
            let h = MeshRuntimeHarness()
            defer { h.cleanUp() }
            XCTAssertNil(h.runtime.wakeNotice(), "no reference before the mesh is open")
            await h.runtime.open()
            let before = try XCTUnwrap(h.runtime.wakeNotice())
            XCTAssertNil(before.chatId)
            var chat = ""
            let changed = try await h.runtime.synchronizeAfterWake(waitForChange: {
                chat = try h.kernel.createChat(title: "Synced")
                await h.runtime.settle()
            })
            XCTAssertTrue(changed)
            let after = try XCTUnwrap(h.runtime.wakeNotice())
            XCTAssertNotEqual(after.ref, before.ref)
            XCTAssertEqual(after.chatId, chat)
            XCTAssertFalse(after.ref.value.contains(chat))
            XCTAssertEqual(h.runtime.wakeNotice()?.ref, after.ref, "stable until the next change")
        }
    }
#endif
