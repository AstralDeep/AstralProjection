// Exercises macOS work notification privacy, permission, mode and kind settings, deduplication, focus
// suppression, badge behavior, opaque tap routing, and removal on owner change.
// The injected notification system keeps these tests independent of user notification settings.
#if os(macOS)
    import Foundation
    import UserNotifications
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacWorkNotificationServiceTests: XCTestCase {
        private final class Recorder {
            var authorization: MacWorkNotificationSystem.Authorization = .authorized
            var promptResult = true
            var active = false
            var deliveryFails = false
            var requests: [UNNotificationRequest] = []
            var badges: [String?] = []
            var removedDelivered = 0
            var removedPending = 0
            var delegate: UNUserNotificationCenterDelegate?

            func system() -> MacWorkNotificationSystem {
                MacWorkNotificationSystem(
                    authorization: { self.authorization },
                    requestAuthorization: { self.promptResult },
                    deliver: {
                        if self.deliveryFails { throw URLError(.cannotConnectToHost) }
                        self.requests.append($0)
                    },
                    setBadge: { self.badges.append($0) },
                    removeAllDelivered: { self.removedDelivered += 1 },
                    removeAllPending: { self.removedPending += 1 },
                    setDelegate: { self.delegate = $0 },
                    appIsActive: { self.active })
            }
        }

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func defaults() throws -> UserDefaults {
            let suite = "MacWorkNotificationServiceTests.\(UUID().uuidString)"
            suites.append(suite)
            return try XCTUnwrap(UserDefaults(suiteName: suite))
        }

        func testApprovalUsesGenericCopyAndDeduplicatesWithinOwner() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(1, ownerScope: "owner-a")

            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: "chat-1")
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: "chat-1")

            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Approval needed")
            XCTAssertEqual(recorder.requests[0].content.body, "Open AstralDeep to review a pending approval.")
            XCTAssertFalse(recorder.requests[0].content.body.contains("approval-1"))
            XCTAssertEqual(recorder.badges.last!, "1")
            XCTAssertEqual(recorder.requests[0].content.userInfo["chat_id"] as? String, "chat-1")
            XCTAssertEqual(recorder.requests[0].content.userInfo["request_id"] as? String, "approval-1")
        }

        func testSuppressesActiveAppAndRequiresAuthorization() async {
            let recorder = Recorder()
            recorder.active = true
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(1, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: nil)
            XCTAssertTrue(recorder.requests.isEmpty)

            recorder.active = false
            recorder.authorization = .denied
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: nil)
            XCTAssertTrue(recorder.requests.isEmpty)
        }

        func testDedupeScopeChangesWithOwnerAndBadgeClampsAtZero() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(4, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "same-id", ownerScope: "owner-a", chatId: nil)
            service.setPendingApprovals(-3, ownerScope: "owner-b")
            await service.approvalRequired(eventID: "same-id", ownerScope: "owner-b", chatId: nil)

            XCTAssertEqual(recorder.requests.count, 2)
            XCTAssertNotEqual(recorder.requests[0].identifier, recorder.requests[1].identifier)
            XCTAssertEqual(recorder.badges.last!, nil)
        }

        func testFinishedAndFailedAlertsUseKindOnlyCopyWithoutADurationGate() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(0, ownerScope: "owner-a")

            await service.workFinished(eventID: "turn-1", ownerScope: "owner-a", chatId: "chat-1")
            await service.turnFailed(eventID: "turn-2", ownerScope: "owner-a", chatId: "chat-1")

            XCTAssertEqual(recorder.requests.count, 2)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn finished")
            XCTAssertEqual(recorder.requests[0].content.body, "Open AstralDeep to view its status.")
            XCTAssertEqual(recorder.requests[1].content.title, "Chat turn failed")
            XCTAssertEqual(recorder.requests[1].content.body, "Open AstralDeep to see what happened.")
            for request in recorder.requests {
                XCTAssertFalse(request.content.title.contains("turn-"))
                XCTAssertFalse(request.content.body.contains("chat-1"))
                XCTAssertEqual(request.content.categoryIdentifier, "")
            }
        }

        func testQuestionAlertsStayBackgroundOnlyEvenInAlwaysMode() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.updateSettings(MacWorkNotificationSettings(mode: .always))
            service.setPendingApprovals(0, ownerScope: "owner-a")
            let eventID = MacWorkNotificationService.stableEventID(
                chatId: "chat-9", level: "info", title: "Which mailbox?", body: "Pick one to continue.")

            recorder.active = true
            await service.questionRequired(eventID: eventID, ownerScope: "owner-a", chatId: "chat-9")
            XCTAssertTrue(recorder.requests.isEmpty)

            recorder.active = false
            await service.questionRequired(eventID: eventID, ownerScope: "owner-a", chatId: "chat-9")
            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertEqual(recorder.requests[0].content.title, "AstralDeep has a question")
            XCTAssertEqual(recorder.requests[0].content.body, "Open AstralDeep to read and answer it.")
            XCTAssertFalse(recorder.requests[0].content.title.contains("mailbox"))
            XCTAssertNil(recorder.requests[0].content.userInfo["request_id"])
        }

        func testAlwaysModeDeliversWorkAlertsWhileTheAppIsActive() async {
            let recorder = Recorder()
            recorder.active = true
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.updateSettings(MacWorkNotificationSettings(mode: .always))
            service.setPendingApprovals(1, ownerScope: "owner-a")

            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: "chat-1")
            await service.workFinished(eventID: "turn-1", ownerScope: "owner-a", chatId: "chat-1")
            await service.turnFailed(eventID: "turn-2", ownerScope: "owner-a", chatId: "chat-1")

            XCTAssertEqual(
                recorder.requests.map { $0.content.userInfo["kind"] as? String },
                ["approval", "finished", "failed"] as [String?])
        }

        func testNeverModeSuppressesEveryKindWhileKeepingTheBadge() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.updateSettings(MacWorkNotificationSettings(mode: .never))
            service.setPendingApprovals(2, ownerScope: "owner-a")

            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: nil)
            await service.questionRequired(eventID: "q-1", ownerScope: "owner-a", chatId: nil)
            await service.workFinished(eventID: "turn-1", ownerScope: "owner-a", chatId: nil)
            await service.turnFailed(eventID: "turn-2", ownerScope: "owner-a", chatId: nil)

            XCTAssertTrue(recorder.requests.isEmpty)
            XCTAssertEqual(recorder.badges.last!, "2")
        }

        func testPerKindTogglesSuppressOnlyTheirKind() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            var settings = MacWorkNotificationSettings()
            settings.enabledKinds.remove(.finished)
            service.updateSettings(settings)
            service.setPendingApprovals(0, ownerScope: "owner-a")

            await service.workFinished(eventID: "turn-1", ownerScope: "owner-a", chatId: nil)
            await service.turnFailed(eventID: "turn-2", ownerScope: "owner-a", chatId: nil)

            XCTAssertEqual(
                recorder.requests.map { $0.content.userInfo["kind"] as? String }, ["failed"] as [String?])
        }

        func testSettingsRoundTripThroughInjectedDefaults() throws {
            let defaults = try defaults()
            let recorder = Recorder()
            var settings = MacWorkNotificationSettings()
            settings.mode = .always
            settings.enabledKinds = [.approval, .failed]
            settings.includeChatTitle = true

            let service = MacWorkNotificationService(system: recorder.system(), defaults: defaults)
            service.updateSettings(settings)
            let reloaded = MacWorkNotificationService(system: recorder.system(), defaults: defaults)

            XCTAssertEqual(reloaded.settings, settings)
            XCTAssertTrue(reloaded.settings.isEnabled(.approval))
            XCTAssertFalse(reloaded.settings.isEnabled(.question))
            XCTAssertFalse(reloaded.settings.isEnabled(.finished))
            XCTAssertTrue(reloaded.settings.isEnabled(.failed))
            XCTAssertTrue(reloaded.settings.includeChatTitle)
        }

        func testDefaultSettingsPreferBackgroundOnlyAlertsWithoutChatTitles() {
            let settings = MacWorkNotificationSettings()
            XCTAssertEqual(settings.mode, .onlyInBackground)
            XCTAssertEqual(settings.enabledKinds, Set(MacWorkNotificationKind.allCases))
            XCTAssertFalse(settings.includeChatTitle)
        }

        func testChatTitleAppearsOnlyWhenOptedInAndIsSanitized() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(0, ownerScope: "owner-a")
            let messyTitle = "  Lab\nresults\tfor\u{7}patient\u{0}  " + String(repeating: "x", count: 80)

            await service.workFinished(
                eventID: "turn-1", ownerScope: "owner-a", chatId: "chat-1", chatTitle: messyTitle)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn finished")

            var settings = service.settings
            settings.includeChatTitle = true
            service.updateSettings(settings)
            await service.workFinished(
                eventID: "turn-2", ownerScope: "owner-a", chatId: "chat-1", chatTitle: messyTitle)
            let expectedSuffix = String(
                messyTitle.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
                    .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(60))
            XCTAssertEqual(recorder.requests[1].content.title, "Chat turn finished — \(expectedSuffix)")
            XCTAssertLessThanOrEqual(recorder.requests[1].content.title.count, 100)
        }

        func testOwnerChangeClearsTrackedEventsAndRemovesDeliveredAndPendingAlerts() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(1, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a", chatId: nil)
            XCTAssertEqual(recorder.requests.count, 1)

            service.setPendingApprovals(0, ownerScope: "owner-b")
            XCTAssertEqual(recorder.removedDelivered, 1)
            XCTAssertEqual(recorder.removedPending, 1)
            XCTAssertEqual(recorder.badges.last!, nil)

            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-b", chatId: nil)
            XCTAssertEqual(recorder.requests.count, 2)

            service.setPendingApprovals(0, ownerScope: nil)
            XCTAssertEqual(recorder.removedDelivered, 2)
            XCTAssertEqual(recorder.removedPending, 2)
        }

        func testTapRoutesOnlyOpaqueIdsToTheHandlerAndRegistersTheDelegate() {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            XCTAssertTrue(recorder.delegate === service)

            var taps: [(chatId: String, requestId: String?)] = []
            service.tapHandler = { taps.append($0) }
            service.handleTap(userInfo: ["chat_id": "chat-1", "request_id": "approval-1"])
            service.handleTap(userInfo: ["chat_id": "chat-2"])
            service.handleTap(userInfo: ["request_id": "approval-1"])
            service.handleTap(userInfo: ["chat_id": ""])

            XCTAssertEqual(taps.count, 2)
            XCTAssertEqual(taps[0].chatId, "chat-1")
            XCTAssertEqual(taps[0].requestId, "approval-1")
            XCTAssertEqual(taps[1].chatId, "chat-2")
            XCTAssertNil(taps[1].requestId)
        }

        func testStableEventIDDistinguishesFramesAndIgnoresNothing() {
            let first = MacWorkNotificationService.stableEventID(
                chatId: "chat-1", level: "info", title: "t", body: "b")
            let repeatFirst = MacWorkNotificationService.stableEventID(
                chatId: "chat-1", level: "info", title: "t", body: "b")
            let otherChat = MacWorkNotificationService.stableEventID(
                chatId: "chat-2", level: "info", title: "t", body: "b")
            let otherLevel = MacWorkNotificationService.stableEventID(
                chatId: "chat-1", level: "error", title: "t", body: "b")
            XCTAssertEqual(first, repeatFirst)
            XCTAssertNotEqual(first, otherChat)
            XCTAssertNotEqual(first, otherLevel)
        }

        func testDeliveryFailureCanRetryWithoutLeakingEventContent() async {
            let recorder = Recorder()
            recorder.deliveryFails = true
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            service.setPendingApprovals(1, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "private-request-id", ownerScope: "owner-a", chatId: nil)
            XCTAssertTrue(recorder.requests.isEmpty)

            recorder.deliveryFails = false
            await service.approvalRequired(eventID: "private-request-id", ownerScope: "owner-a", chatId: nil)
            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertFalse(recorder.requests[0].identifier.contains("private-request-id"))
        }

        func testPermissionRequestOnlyOccursWhenUndetermined() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            recorder.authorization = .notDetermined
            let granted = await service.requestPermission()
            XCTAssertTrue(granted)

            recorder.authorization = .denied
            let denied = await service.requestPermission()
            XCTAssertFalse(denied)
        }
    }
#endif
