// Checks content-free wake admission, bounded completion and lifecycle cancellation without an APNs service or wall-clock waits.
// The runtime checks ensure a wake never opens custody or starts work outside an existing enrolled mesh.

@testable import AstralDeep
import XCTest
#if os(iOS)
    import UIKit
#endif

@MainActor
final class MeshBackgroundWakeTests: XCTestCase {
    private let payload: [AnyHashable: Any] = ["aps": ["content-available": 1]]

    func testPayloadAcceptsOnlyContentFreeNumericWakeAndDeliveryMetadata() {
        XCTAssertTrue(MeshBackgroundWake.accepts(payload))
        XCTAssertTrue(MeshBackgroundWake.accepts(["aps": ["content-available": 1], "apns-id": "delivery-id"]))
        for value: Any in [true, false, "1", 0, 2, NSNull()] {
            XCTAssertFalse(MeshBackgroundWake.accepts(["aps": ["content-available": value]]))
        }
        XCTAssertFalse(MeshBackgroundWake.accepts(["aps": ["content-available": 1, "alert": "content"]]))
        XCTAssertFalse(MeshBackgroundWake.accepts(["aps": ["content-available": 1], "message": "content"]))
        XCTAssertFalse(MeshBackgroundWake.accepts(["aps": ["content-available": 1], "apns-id": 7]))
        XCTAssertFalse(MeshBackgroundWake.accepts([:]))
    }

    func testRejectedAndUnauthorizedWakeCompletesWithoutRunningWork() {
        var calls = 0
        let handler = MeshBackgroundWake(authorized: { false }, synchronize: { calls += 1; return true })
        var outcomes: [MeshBackgroundWake.Result] = []
        XCTAssertNil(handler.receive(payload) { outcomes.append($0) })
        XCTAssertEqual(outcomes, [.noData])
        XCTAssertEqual(calls, 0)
    }

    func testSuccessfulAndFailedSyncHaveHonestResults() async {
        for changed in [false, true] {
            let handler = MeshBackgroundWake(authorized: { true }, synchronize: { changed })
            var outcomes: [MeshBackgroundWake.Result] = []
            let task = handler.receive(payload) { outcomes.append($0) }
            await task?.value
            XCTAssertEqual(outcomes, [changed ? .newData : .noData])
        }
        let handler = MeshBackgroundWake(authorized: { true }, synchronize: { throw CocoaError(.fileReadUnknown) })
        var outcomes: [MeshBackgroundWake.Result] = []
        await handler.receive(payload) { outcomes.append($0) }?.value
        XCTAssertEqual(outcomes, [.failed])
    }

    func testTimeoutCompletesOnceAndLateWorkCannotReportNewData() async {
        let work = WakeGate()
        let deadline = WakeGate()
        let completed = expectation(description: "budget completion")
        let handler = MeshBackgroundWake(
            authorized: { true }, synchronize: { await work.wait(); return true },
            waitBudget: { await deadline.wait() })
        var outcomes: [MeshBackgroundWake.Result] = []
        let task = handler.receive(payload) { outcomes.append($0); completed.fulfill() }
        await deadline.started()
        deadline.release()
        await fulfillment(of: [completed], timeout: 5)
        work.release()
        await task?.value
        XCTAssertEqual(outcomes, [.noData])
    }

    func testConcurrentWakeAndLifecycleCancellationNeverDuplicateWorkOrCallbacks() async {
        let work = WakeGate()
        var allowed = true
        var calls = 0
        let handler = MeshBackgroundWake(authorized: { allowed }, synchronize: {
            calls += 1
            await work.wait()
            return true
        })
        var first: [MeshBackgroundWake.Result] = []
        var duplicate: [MeshBackgroundWake.Result] = []
        let task = handler.receive(payload) { first.append($0) }
        await work.started()
        XCTAssertNil(handler.receive(payload) { duplicate.append($0) })
        allowed = false
        handler.cancel()
        handler.cancel()
        work.release()
        await task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first, [.noData])
        XCTAssertEqual(duplicate, [.noData])
    }

    func testAuthorizationIsRecheckedAfterSuspension() async {
        let work = WakeGate()
        var allowed = true
        let handler = MeshBackgroundWake(authorized: { allowed }, synchronize: { await work.wait(); return true })
        var outcomes: [MeshBackgroundWake.Result] = []
        let task = handler.receive(payload) { outcomes.append($0) }
        await work.started()
        allowed = false
        work.release()
        await task?.value
        XCTAssertEqual(outcomes, [.noData])
    }

    func testColdAndUnenrolledRuntimeNeverOpenKeysOrSync() async throws {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        let cold = try await h.runtime.synchronizeAfterWake(waitForChange: { })
        XCTAssertFalse(cold)
        XCTAssertNil(h.box.kernel)
        await h.runtime.open()
        let count = h.kernel.calls.count
        let unenrolled = try await h.runtime.synchronizeAfterWake(waitForChange: { })
        XCTAssertFalse(unenrolled)
        XCTAssertEqual(h.kernel.calls.count, count)
    }

    func testRuntimeRequestsSyncAndReportsOnlyAnObservedDataChange() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let changed = try await h.runtime.synchronizeAfterWake(waitForChange: {
            _ = try h.kernel.createChat(title: "Synced")
            await h.runtime.settle()
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "syncNow" }.count, 1)
    }

    func testClosingRuntimeDuringWakeCannotReportDataFromARetiredSession() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let changed = try await h.runtime.synchronizeAfterWake(waitForChange: { await h.runtime.close() })
        XCTAssertFalse(changed)
    }

    #if os(iOS)
        func testAppDeclaresBackgroundRemoteNotifications() {
            XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("remote-notification") == true)
        }

        func testDelegateCompletesWithoutAnActiveMeshAndRejectsContentfulPushes() {
            let previous = MeshBackgroundWake.active
            defer { MeshBackgroundWake.active = previous }
            let delegate = PushNotificationAppDelegate()
            MeshBackgroundWake.active = nil
            var outcomes: [UIBackgroundFetchResult] = []
            delegate.application(.shared, didReceiveRemoteNotification: payload) { outcomes.append($0) }
            XCTAssertEqual(outcomes, [.noData])
            var calls = 0
            let handler = MeshBackgroundWake(authorized: { true }, synchronize: { calls += 1; return true })
            MeshBackgroundWake.active = handler
            delegate.application(.shared, didReceiveRemoteNotification: ["aps": ["alert": "legacy"], "notification_id": "existing-alert"]) {
                outcomes.append($0)
            }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(outcomes, [.noData, .noData])
        }

        func testProtectedDataLossAndTerminationCompleteOnceWithoutLateSuccess() async {
            let previous = MeshBackgroundWake.active
            defer { MeshBackgroundWake.active = previous }
            let gate = WakeGate()
            let handler = MeshBackgroundWake(authorized: { true }, synchronize: { await gate.wait(); return true })
            MeshBackgroundWake.active = handler
            var outcomes: [MeshBackgroundWake.Result] = []
            let task = handler.receive(payload) { outcomes.append($0) }
            await gate.started()
            let delegate = PushNotificationAppDelegate()
            delegate.applicationProtectedDataWillBecomeUnavailable(.shared)
            delegate.applicationWillTerminate(.shared)
            gate.release()
            await task?.value
            XCTAssertEqual(outcomes, [.noData])
        }
    #endif
}

@MainActor
private final class WakeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var began = false
    private var released = false

    func wait() async {
        began = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func started() async {
        while !began { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
