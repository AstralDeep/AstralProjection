// Exercises macOS work notification privacy, permission, deduplication, focus suppression, and badge behavior.
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

            func system() -> MacWorkNotificationSystem {
                MacWorkNotificationSystem(
                    authorization: { self.authorization },
                    requestAuthorization: { self.promptResult },
                    deliver: {
                        if self.deliveryFails { throw URLError(.cannotConnectToHost) }
                        self.requests.append($0)
                    },
                    setBadge: { self.badges.append($0) },
                    appIsActive: { self.active })
            }
        }

        func testApprovalUsesGenericCopyAndDeduplicatesWithinOwner() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system())
            service.setPendingApprovals(1, ownerScope: "owner-a")

            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a")
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a")

            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Approval needed")
            XCTAssertEqual(recorder.requests[0].content.body, "Open AstralDeep to review a pending approval.")
            XCTAssertFalse(recorder.requests[0].content.body.contains("approval-1"))
            XCTAssertEqual(recorder.badges.last!, "1")
        }

        func testSuppressesActiveAppAndRequiresAuthorization() async {
            let recorder = Recorder()
            recorder.active = true
            let service = MacWorkNotificationService(system: recorder.system())
            service.setPendingApprovals(1, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a")
            XCTAssertTrue(recorder.requests.isEmpty)

            recorder.active = false
            recorder.authorization = .denied
            await service.approvalRequired(eventID: "approval-1", ownerScope: "owner-a")
            XCTAssertTrue(recorder.requests.isEmpty)
        }

        func testDedupeScopeChangesWithOwnerAndBadgeClampsAtZero() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system())
            service.setPendingApprovals(4, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "same-id", ownerScope: "owner-a")
            service.setPendingApprovals(-3, ownerScope: "owner-b")
            await service.approvalRequired(eventID: "same-id", ownerScope: "owner-b")

            XCTAssertEqual(recorder.requests.count, 2)
            XCTAssertNotEqual(recorder.requests[0].identifier, recorder.requests[1].identifier)
            XCTAssertEqual(recorder.badges.last!, nil)
        }

        func testOnlyNotifiesForLongRunningWork() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system())
            service.setPendingApprovals(0, ownerScope: "owner-a")
            let start = Date(timeIntervalSince1970: 100)

            await service.workFinished(
                eventID: "short", ownerScope: "owner-a", startedAt: start,
                now: start.addingTimeInterval(MacWorkNotificationService.longWorkThreshold - 1))
            await service.workFinished(
                eventID: "long", ownerScope: "owner-a", startedAt: start,
                now: start.addingTimeInterval(MacWorkNotificationService.longWorkThreshold))

            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn finished")
            XCTAssertEqual(
                recorder.requests[0].content.body,
                "A long-running chat turn finished. Open AstralDeep to view its status.")
        }

        func testDeliveryFailureCanRetryWithoutLeakingEventContent() async {
            let recorder = Recorder()
            recorder.deliveryFails = true
            let service = MacWorkNotificationService(system: recorder.system())
            service.setPendingApprovals(1, ownerScope: "owner-a")
            await service.approvalRequired(eventID: "private-request-id", ownerScope: "owner-a")
            XCTAssertTrue(recorder.requests.isEmpty)

            recorder.deliveryFails = false
            await service.approvalRequired(eventID: "private-request-id", ownerScope: "owner-a")
            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertFalse(recorder.requests[0].identifier.contains("private-request-id"))
        }

        func testPermissionRequestOnlyOccursWhenUndetermined() async {
            let recorder = Recorder()
            let service = MacWorkNotificationService(system: recorder.system())
            recorder.authorization = .notDetermined
            let granted = await service.requestPermission()
            XCTAssertTrue(granted)

            recorder.authorization = .denied
            let denied = await service.requestPermission()
            XCTAssertFalse(denied)
        }
    }
#endif
