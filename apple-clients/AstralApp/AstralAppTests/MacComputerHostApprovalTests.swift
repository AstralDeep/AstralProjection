// Exercises approval acknowledgment liveness with the real host and controllable raw delays.
// Every waiter uses an ordinary session and retains cancellation, capacity and channel fences.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerHostApprovalTests: XCTestCase {
        private func pending(_ fixture: MacComputerLifecycleFixture, delay: MacComputerLifecycleDelay)
            -> (Task<Bool, Never>, XCTestExpectation)
        {
            let entered = expectation(description: "registered approval timeout enters raw IO")
            delay.onEntry = { count in if count == 1 { entered.fulfill() } }
            fixture.io.configure { $0.delayHook = { try await delay.sleep($0) } }
            let barrier = fixture.host.recordApprovalInteraction()
            let task = Task { await fixture.host.flushApprovalPause(barrier) }
            return (task, entered)
        }
        func testLateMatchingAcknowledgmentResolvesTheRegisteredWaiterOnce() async throws {
            let fixture = try MacComputerLifecycleFixture()
            let delay = MacComputerLifecycleDelay()
            defer {
                fixture.close()
                delay.cancelAll()
            }
            try fixture.enableAndStart()
            let (task, entered) = pending(fixture, delay: delay)
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(delay.pendingCount, 1)
            XCTAssertFalse(fixture.host.approvalPauseReady(fixture.sessionID))
            fixture.host.consume(try fixture.session(state: "paused"))
            let result = await task.value
            XCTAssertTrue(result)
            XCTAssertTrue(fixture.host.approvalPauseReady(fixture.sessionID))
            XCTAssertEqual(delay.pendingCount, 0)
            XCTAssertEqual(delay.cancelledCount, 1)
            fixture.host.consume(try fixture.session(state: "paused"))
            XCTAssertEqual(delay.cancelledCount, 1)
        }
        func testTaskCancellationCannotAuthorizeAndRemovesTheRegisteredTimeout() async throws {
            let fixture = try MacComputerLifecycleFixture()
            let delay = MacComputerLifecycleDelay()
            defer {
                fixture.close()
                delay.cancelAll()
            }
            try fixture.enableAndStart()
            let (task, entered) = pending(fixture, delay: delay)
            await fulfillment(of: [entered], timeout: 5)
            task.cancel()
            let result = await task.value
            XCTAssertFalse(result)
            XCTAssertEqual(delay.pendingCount, 0)
            XCTAssertEqual(delay.cancelledCount, 1)
            XCTAssertEqual(fixture.host.session?.state, "paused")
            XCTAssertFalse(fixture.channel.events.contains("resumed"))
        }
        func testStopDisconnectAndOwnerChangeResolvePendingApprovalWithoutAuthority() async throws {
            for action in 0..<3 {
                let fixture = try MacComputerLifecycleFixture()
                let delay = MacComputerLifecycleDelay()
                defer {
                    fixture.close()
                    delay.cancelAll()
                }
                try fixture.enableAndStart()
                let (task, entered) = pending(fixture, delay: delay)
                await fulfillment(of: [entered], timeout: 5)
                if action == 0 { fixture.host.stop() }
                if action == 1 { fixture.host.disconnect() }
                if action == 2 { fixture.host.bind(owner: "different-owner|different-server") { _ in true } }
                let result = await task.value
                XCTAssertFalse(result)
                XCTAssertEqual(delay.pendingCount, 0)
                XCTAssertNil(fixture.host.session)
                XCTAssertFalse(fixture.channel.events.contains("resumed"))
            }
        }
        func testTimeoutRemovesTheWaiterBeforeLateAcknowledgment() async throws {
            let fixture = try MacComputerLifecycleFixture()
            let delay = MacComputerLifecycleDelay()
            defer {
                fixture.close()
                delay.cancelAll()
            }
            try fixture.enableAndStart()
            let (task, entered) = pending(fixture, delay: delay)
            await fulfillment(of: [entered], timeout: 5)
            delay.finishAll()
            let result = await task.value
            XCTAssertFalse(result)
            XCTAssertEqual(delay.pendingCount, 0)
            fixture.host.consume(try fixture.session(state: "paused"))
            XCTAssertEqual(fixture.host.session?.state, "paused")
            XCTAssertFalse(fixture.channel.events.contains("resumed"))
        }
        func testWaiterCapacityIsBoundedAndAcknowledgmentReleasesEveryAdmittedWaiter() async throws {
            let fixture = try MacComputerLifecycleFixture()
            let delay = MacComputerLifecycleDelay()
            defer {
                fixture.close()
                delay.cancelAll()
            }
            try fixture.enableAndStart()
            let registered = expectation(description: "all admitted timeouts entered raw IO")
            registered.expectedFulfillmentCount = 32
            delay.onEntry = { _ in registered.fulfill() }
            fixture.io.configure { $0.delayHook = { try await delay.sleep($0) } }
            let barrier = fixture.host.recordApprovalInteraction()
            let tasks = (0..<32).map { _ in Task { await fixture.host.flushApprovalPause(barrier) } }
            await fulfillment(of: [registered], timeout: 5)
            XCTAssertEqual(delay.pendingCount, 32)
            let overflow = await fixture.host.flushApprovalPause(barrier)
            XCTAssertFalse(overflow)
            XCTAssertEqual(delay.pendingCount, 32)
            fixture.host.consume(try fixture.session(state: "paused"))
            for task in tasks {
                let allowed = await task.value
                XCTAssertTrue(allowed)
            }
            XCTAssertEqual(delay.pendingCount, 0)
            XCTAssertEqual(delay.cancelledCount, 32)
        }
        func testTerminationResolvesApprovalAndStopsTheAcquiredMonitor() async throws {
            let fixture = try MacComputerLifecycleFixture()
            let delay = MacComputerLifecycleDelay()
            defer {
                fixture.close()
                delay.cancelAll()
            }
            try fixture.enableAndStart()
            let (task, entered) = pending(fixture, delay: delay)
            await fulfillment(of: [entered], timeout: 5)
            let stops = fixture.monitor.stops
            fixture.host.applicationWillTerminate()
            let result = await task.value
            XCTAssertFalse(result)
            XCTAssertNil(fixture.host.session)
            XCTAssertFalse(fixture.monitor.running)
            XCTAssertGreaterThan(fixture.monitor.stops, stops)
            XCTAssertNil(fixture.host.descriptor)
            XCTAssertEqual(delay.pendingCount, 0)
        }
    }

    nonisolated final class MacComputerLifecycleDelay: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var entries = 0
        private var cancelled = 0
        private var entry: (@Sendable (Int) -> Void)?
        var onEntry: (@Sendable (Int) -> Void)? {
            get { lock.withLock { entry } }
            set { lock.withLock { entry = newValue } }
        }
        var pendingCount: Int { lock.withLock { pending.count } }
        var cancelledCount: Int { lock.withLock { cancelled } }
        func sleep(_ nanoseconds: UInt64) async throws {
            precondition(nanoseconds == 5_000_000_000)
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending[id] = continuation
                    entries += 1
                    let count = entries
                    let callback = entry
                    lock.unlock()
                    callback?(count)
                }
            } onCancel: {
                self.cancel(id)
            }
        }
        private func cancel(_ id: UUID) {
            let continuation = lock.withLock {
                let continuation = pending.removeValue(forKey: id)
                if continuation != nil { cancelled += 1 }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        func cancelAll() {
            let ids = lock.withLock { Array(pending.keys) }
            for id in ids { cancel(id) }
        }
        func finishAll() {
            let continuations = lock.withLock {
                let continuations = Array(pending.values)
                pending = [:]
                return continuations
            }
            for continuation in continuations { continuation.resume() }
        }
    }
#endif
