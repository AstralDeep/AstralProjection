// Checks ordinary-turn recovery admission, native worker retirement and stale callbacks without audio hardware or a network service.
// Barrier-controlled in-memory workers stay alive until the fixture explicitly releases them.

@testable import AstralDeep
import XCTest

nonisolated final class ResumeWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0
    private var interrupts = 0
    private var released = false

    var entered: Int { lock.withLock { arrivals } }
    var interrupted: Int { lock.withLock { interrupts } }
    func release() { lock.withLock { released = true } }
    func interrupt() { lock.withLock { interrupts += 1 } }
    func wait() async {
        lock.withLock { arrivals += 1 }
        while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

nonisolated final class ResumeRetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    var delays: [Duration] { lock.withLock { values } }
    func record(_ delay: Duration) -> Int {
        lock.withLock {
            values.append(delay)
            return values.count
        }
    }
}

nonisolated final class ResumeWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false
    private var released = false
    var entered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return arrived
    }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        arrived = true
        while !released { condition.wait() }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class MeshResumeSchedulingTests: XCTestCase {
    func testRepeatedRecoveryTriggersResumeOneExactTurnAndRefuseBusyInputBeforeWriting() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(title: "Open", messages: [MeshRuntimeHarness.message("m", parent: nil, at: 1)])
        h.kernel.seedOrdinaryResume(chatId: chat, turnId: "existing-turn")
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.turnGate = { await gate.wait() }
        await h.runtime.refreshAll()
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.openChat(chat)
        for _ in 0..<5 {
            h.kernel.setSync(.empty)
            await h.runtime.open()
        }
        let accepted = await h.runtime.send("Do not silently accept this")
        XCTAssertFalse(accepted)
        XCTAssertEqual(h.runtime.notice, "This chat is already answering. Try again when it finishes.")
        await h.runtime.act(surfaceId: "s", componentId: "c", capability: "cap")
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "sendMessage" || $0.name == "act" })
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "resumeTurn" }.map(\.detail), [chat + "/existing-turn"])
        XCTAssertFalse(h.kernel.calls.contains { ($0.name == "runTurn" || $0.name == "runMessage") })
        gate.release()
        await h.runtime.settle()
        await h.runtime.openChat(chat)
        XCTAssertEqual(h.runtime.currentChat?.messages.filter { $0.author == .assistant }.count, 1)
    }

    func testNativePendingProofSchedulesTheExactMessageOnceWithoutGenericReplay() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(
            title: "Accepted", messages: [MeshRuntimeHarness.message("accepted", parent: nil, at: 1, delivery: .queued)]
        )
        h.kernel.seedPendingOrdinaryMessage(chatId: chat, messageId: "accepted")
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.turnGate = { await gate.wait() }
        await h.runtime.refreshAll()
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.openChat(chat)
        for _ in 0..<5 { await h.runtime.open() }
        let accepted = await h.runtime.send("Do not replace recovery")
        XCTAssertFalse(accepted)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "resumePendingMessage" }.map(\.detail), [chat + "/accepted"])
        XCTAssertFalse(
            h.kernel.calls.contains {
                ($0.name == "runTurn" || $0.name == "runMessage") || $0.name == "resumeTurn" || $0.name == "sendMessage"
            })
        gate.release()
        await h.runtime.settle()
        await h.runtime.open()
        await h.runtime.settle()
        await h.runtime.openChat(chat)
        XCTAssertEqual(h.runtime.currentChat?.messages.filter { $0.author == .owner }.map(\.eventId), ["accepted"])
        XCTAssertEqual(h.runtime.currentChat?.messages.filter { $0.author == .assistant }.count, 1)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "resumePendingMessage" }.count, 1)
    }

    func testNativePendingDenialsLeaveAmbiguousManagedAndUnknownQueuesUntouched() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let ambiguous = h.kernel.seedChat(
            title: "Ambiguous",
            messages: [
                MeshRuntimeHarness.message("a", parent: nil, at: 1, delivery: .queued),
                MeshRuntimeHarness.message("b", parent: "a", at: 2, delivery: .queued),
            ])
        h.kernel.seedPendingOrdinaryMessage(chatId: ambiguous, messageId: "b")
        let unknown = h.kernel.seedChat(
            title: "Unknown", messages: [MeshRuntimeHarness.message("u", parent: nil, at: 1, delivery: .queued)])
        h.kernel.seedPendingOrdinaryMessage(chatId: unknown, messageId: "u")
        h.kernel.setChatStatus(
            chatId: unknown, .outcomeUnknown(MeshUnknownOutcome(stepId: "step", tool: "send", summary: "Unknown")))
        let managed = h.kernel.seedChat(
            title: "Run", messages: [MeshRuntimeHarness.message("r", parent: nil, at: 1, delivery: .queued)])
        h.kernel.seedPendingOrdinaryMessage(chatId: managed, messageId: "r")
        h.kernel.setRuns([
            MeshRun(
                runId: "run", chatId: managed, kind: .goal, goal: "Goal", status: .done, reason: nil,
                rounds: 1, tokensSpent: 1, role: .executor, executor: nil, unknownSteps: 0)
        ])
        await h.runtime.refreshAll()
        await h.runtime.settle()
        XCTAssertFalse(
            h.kernel.calls.contains {
                $0.name == "resumePendingMessage" || ($0.name == "runTurn" || $0.name == "runMessage")
            })
    }

    func testAcceptedWriteSurvivesCloseBeforeNativeTurnEntryWithoutStartingAfterRetirement() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()!
        let original = h.kernel
        let gate = ResumeWriteGate()
        defer { gate.release() }
        original.sendGate = { gate.wait() }
        let sending = Task { await h.runtime.send("Durably accepted before close") }
        let written = await eventually { gate.entered }
        XCTAssertTrue(written)
        await h.runtime.close()
        gate.release()
        let accepted = await sending.value
        XCTAssertTrue(accepted)
        let saved = try original.chat(chatId: chat)
        XCTAssertEqual(saved.messages.map(\.text), ["Durably accepted before close"])
        XCTAssertEqual(saved.messages.map(\.delivery), [.queued])
        XCTAssertFalse(
            original.calls.contains {
                ($0.name == "runTurn" || $0.name == "runMessage") || $0.name == "resumePendingMessage"
            })
        XCTAssertEqual(h.runtime.phase, .closed)
    }

    func testARecoveryScanFromTheClosedSessionCannotSuppressNewSessionRecovery() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let old = h.kernel
        let scanGate = ResumeWorkerGate()
        let workGate = ResumeWorkerGate()
        defer {
            scanGate.release()
            workGate.release()
        }
        old.pendingGate = { await scanGate.wait() }
        let scanning = Task { await h.runtime.refreshAll() }
        let entered = await eventually { scanGate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.close()
        await h.runtime.open()
        let chat = h.kernel.seedChat(
            title: "Accepted", messages: [MeshRuntimeHarness.message("new", parent: nil, at: 1, delivery: .queued)])
        h.kernel.seedPendingOrdinaryMessage(chatId: chat, messageId: "new")
        h.kernel.turnGate = { await workGate.wait() }
        await h.runtime.refreshAll()
        let recovered = await eventually { workGate.entered == 1 }
        XCTAssertTrue(recovered)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "resumePendingMessage" }.map(\.detail), [chat + "/new"])
        scanGate.release()
        await scanning.value
        workGate.release()
        await h.runtime.settle()
    }

    func testRecoveryDoesNotReplaceAnExistingManualWorker() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()!
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.turnGate = { await gate.wait() }
        let sent = await h.runtime.send("Manual request")
        XCTAssertTrue(sent)
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        guard case .running(let turn) = try? h.kernel.chat(chatId: chat).status else { return XCTFail("running") }
        h.kernel.seedOrdinaryResume(chatId: chat, turnId: turn)
        await h.runtime.refreshAll()
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "resumeTurn" || $0.name == "interrupt" })
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "runMessage" }.count, 1)
        gate.release()
        await h.runtime.settle()
    }

    func testCloseInterruptsButWaitsForTheActualNativeWorkerBeforeStoppingNetwork() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(title: "Open", messages: [MeshRuntimeHarness.message("m", parent: nil, at: 1)])
        h.kernel.seedOrdinaryResume(chatId: chat, turnId: "existing")
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.turnGate = { await gate.wait() }
        h.kernel.interruptGate = { gate.interrupt() }
        await h.runtime.refreshAll()
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        let closing = Task { await h.runtime.close() }
        let interrupted = await eventually { gate.interrupted == 1 }
        XCTAssertTrue(interrupted)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "stopNetwork" })
        let accepted = await h.runtime.send("Do not start during close")
        XCTAssertFalse(accepted)
        gate.release()
        await closing.value
        XCTAssertEqual(h.runtime.phase, .closed)
        XCTAssertTrue(h.runtime.turns.isEmpty)
        XCTAssertTrue(h.kernel.calls.contains { $0.name == "stopNetwork" })
    }

    func testConcurrentCloseCallsWaitForTheSameNativeRetirement() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(title: "Open", messages: [])
        h.kernel.seedOrdinaryResume(chatId: chat, turnId: "existing")
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        h.kernel.turnGate = { await gate.wait() }
        h.kernel.interruptGate = { gate.interrupt() }
        await h.runtime.refreshAll()
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        let first = Task { await h.runtime.close() }
        let interrupted = await eventually { gate.interrupted == 1 }
        XCTAssertTrue(interrupted)
        var secondStarted = false
        var secondFinished = false
        let second = Task {
            secondStarted = true
            await h.runtime.close()
            secondFinished = true
        }
        let joined = await eventually { secondStarted }
        XCTAssertTrue(joined)
        XCTAssertFalse(secondFinished)
        gate.release()
        await first.value
        await second.value
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "stopNetwork" }.count, 1)
    }

    func testOldKernelProgressCannotChangeAReopenedRuntime() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let old = h.kernel
        await h.runtime.close()
        await h.runtime.open()
        let chat = await h.runtime.newChat()!
        old.emit(.turnProgress(MeshTurnProgress(chatId: chat, turnId: "old", event: .failed("Old session"))))
        await h.runtime.settle()
        XCTAssertNil(h.runtime.turns[chat])
        XCTAssertNil(h.runtime.notice)
    }

    func testDelayedProgressFromAnOlderTurnCannotChangeTheCurrentWorkerOrSpeech() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()!
        _ = await h.runtime.send("First")
        await h.runtime.settle()
        let older = try XCTUnwrap(h.runtime.currentTurn?.turnId)
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        let sink = RecordingSpeechSink()
        h.runtime.speechSink = sink
        h.kernel.turnGate = { await gate.wait() }
        _ = await h.runtime.send("Second", speaking: true)
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        guard case .running(let current) = try h.kernel.chat(chatId: chat).status else {
            return XCTFail("Current worker must be running")
        }
        h.kernel.emit(.turnProgress(MeshTurnProgress(chatId: chat, turnId: older, event: .started)))
        h.kernel.emit(
            .turnProgress(
                MeshTurnProgress(chatId: chat, turnId: older, event: .assistantDelta("Old speech before START"))))
        h.kernel.emit(.turnProgress(MeshTurnProgress(chatId: chat, turnId: current, event: .started)))
        let started = await eventually { h.runtime.currentTurn?.turnId == current }
        XCTAssertTrue(started)
        h.kernel.emit(
            .turnProgress(MeshTurnProgress(chatId: chat, turnId: older, event: .assistantDelta("Old speech"))))
        h.kernel.emit(.turnProgress(MeshTurnProgress(chatId: chat, turnId: older, event: .assistantFinished)))
        h.kernel.emit(.turnProgress(MeshTurnProgress(chatId: chat, turnId: older, event: .failed("Old failure"))))
        h.kernel.setAllowance(
            MeshAllowance(
                share: .fresh, periodEndsAt: nil, lines: [], modelTokensRemaining: 123, modelTokensLimit: 456,
                blocked: nil))
        let consumed = await eventually { h.runtime.allowance?.modelTokensRemaining == 123 }
        XCTAssertTrue(consumed)
        XCTAssertEqual(h.runtime.currentTurn?.turnId, current)
        XCTAssertEqual(h.runtime.currentTurn?.running, true)
        XCTAssertNil(h.runtime.currentTurn?.failure)
        XCTAssertEqual(h.runtime.currentTurn?.streamingText, "")
        XCTAssertTrue(sink.deltas.isEmpty)
        XCTAssertEqual(sink.finished, 0)
        gate.release()
        await h.runtime.settle()
    }

    func testAnOldStatusReadAlreadyInFlightCannotOverwriteTheReopenedSession() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let old = h.kernel
        try old.raiseStop()
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        old.statusGate = { await gate.wait() }
        old.emit(.rosterChanged)
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        await h.runtime.close()
        await h.runtime.open()
        XCTAssertFalse(h.runtime.status.stopped)
        gate.release()
        await h.runtime.settle()
        XCTAssertFalse(h.runtime.status.stopped)
    }

    func testQueuedRowsWithoutNativeProofAndUnownedRunningChatsAreNotExecuted() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = h.kernel.seedChat(
            title: "Queued", messages: [MeshRuntimeHarness.message("q", parent: nil, at: 1, delivery: .queued)])
        let remote = h.kernel.seedChat(title: "Remote", messages: [])
        h.kernel.setChatStatus(chatId: remote, .running(turnId: "remote"))
        await h.runtime.refreshAll()
        await h.runtime.settle()
        XCTAssertFalse(
            h.kernel.calls.contains { ($0.name == "runTurn" || $0.name == "runMessage") || $0.name == "resumeTurn" })
    }

    func testUnknownRunOwnedAndStoppedCandidatesDoNotResume() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let unknown = h.kernel.seedChat(title: "Unknown", messages: [])
        h.kernel.seedOrdinaryResume(chatId: unknown, turnId: "unknown")
        h.kernel.setChatStatus(
            chatId: unknown, .outcomeUnknown(MeshUnknownOutcome(stepId: "step", tool: "post", summary: "Unknown")))
        let managed = h.kernel.seedChat(title: "Run", messages: [])
        h.kernel.seedOrdinaryResume(chatId: managed, turnId: "managed")
        h.kernel.setRuns([
            MeshRun(
                runId: "run", chatId: managed, kind: .goal, goal: "Goal", status: .done, reason: nil,
                rounds: 1, tokensSpent: 1, role: .executor, executor: nil, unknownSteps: 0)
        ])
        await h.runtime.refreshAll()
        await h.runtime.settle()
        XCTAssertFalse(
            h.kernel.calls.contains { $0.name == "resumeTurn" || ($0.name == "runTurn" || $0.name == "runMessage") })
        await h.runtime.raiseStop()
        let stopped = h.kernel.seedChat(title: "Stopped", messages: [])
        h.kernel.seedOrdinaryResume(chatId: stopped, turnId: "stopped")
        await h.runtime.refreshAll()
        await h.runtime.settle()
        XCTAssertFalse(
            h.kernel.calls.contains { $0.name == "resumeTurn" || ($0.name == "runTurn" || $0.name == "runMessage") })
    }

    func testExplicitStopJoinsPendingCancellationAndTheRetiredWorker() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Pending stop")
        let entry = ResumeWorkerGate()
        let cancellation = ResumeWorkerGate()
        let calls = ResumeRetryLog()
        defer {
            entry.release()
            cancellation.release()
        }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat, waitForEntry: { await entry.wait() },
            cancelPending: { _, _ in await cancellation.wait() },
            operation: { _ in
                _ = calls.record(.zero)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire(explicitStop: true)
        let cancelling = await eventually { cancellation.entered == 1 }
        XCTAssertTrue(cancelling)
        var finished = false
        let observer = Task {
            await retirement.value
            finished = true
        }
        entry.release()
        _ = await work.task.value
        XCTAssertFalse(finished)
        XCTAssertTrue(calls.delays.isEmpty)
        cancellation.release()
        await observer.value
        XCTAssertTrue(finished)
        XCTAssertTrue(work.interruptionAccepted)
        XCTAssertNil(work.retirementFailure)
    }

    func testClosingBeforeEntryLeavesPendingInputAvailableForRecovery() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Recover later")
        let entry = ResumeWorkerGate()
        let calls = ResumeRetryLog()
        defer { entry.release() }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat, waitForEntry: { await entry.wait() },
            cancelPending: { _, _ in _ = calls.record(.zero) },
            operation: { _ in
                _ = calls.record(.zero)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire()
        entry.release()
        await retirement.value
        XCTAssertTrue(calls.delays.isEmpty)
        XCTAssertFalse(work.interruptionAccepted)
    }

    func testPendingStopFailureDoesNotClaimInterruption() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Refused stop")
        let entry = ResumeWorkerGate()
        defer { entry.release() }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat, waitForEntry: { await entry.wait() },
            cancelPending: { _, _ in throw MeshKernelError.refused("Stop was refused") },
            operation: { _ in
                XCTFail("Retired input entered")
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire(explicitStop: true)
        entry.release()
        await retirement.value
        XCTAssertFalse(work.interruptionAccepted)
        XCTAssertNotNil(work.retirementFailure)
    }

    func testRetirementRetriesAnInterruptThatArrivesBeforeNativeEntry() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Entry race")
        let entry = ResumeWorkerGate()
        let native = ResumeWorkerGate()
        defer {
            entry.release()
            native.release()
        }
        kernel.turnGate = { await native.wait() }
        kernel.interruptGate = {
            guard native.entered > 0 else { throw MeshKernelError.notFound }
            native.interrupt()
            native.release()
        }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat,
            interrupt: { kernel, chat in try kernel.interruptTurn(chatId: chat, turnId: "expected-turn") },
            operation: { kernel in
                await entry.wait()
                try await kernel.runTurn(chatId: chat)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire()
        let attempted = await eventually { kernel.calls.contains { $0.name == "interruptTurn" } }
        XCTAssertTrue(attempted)
        XCTAssertEqual(native.entered, 0)
        entry.release()
        let acknowledged = await eventually { native.interrupted == 1 }
        XCTAssertTrue(acknowledged)
        native.release()
        await retirement.value
        XCTAssertEqual(native.interrupted, 1)
        XCTAssertGreaterThanOrEqual(kernel.calls.filter { $0.name == "interruptTurn" }.count, 2)
    }

    func testDelayedNativeEntryCannotInterruptDifferentActiveWork() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Separate native owners")
        let foreign = ResumeWorkerGate()
        let entry = ResumeWorkerGate()
        let own = ResumeWorkerGate()
        let attempts = ResumeRetryLog()
        defer {
            foreign.release()
            entry.release()
            own.release()
        }
        let unrelated = Task.detached { await foreign.wait() }
        let foreignEntered = await eventually { foreign.entered == 1 }
        XCTAssertTrue(foreignEntered)
        kernel.turnGate = { await own.wait() }
        kernel.interruptGate = {
            foreign.interrupt()
            foreign.release()
        }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat,
            interrupt: { _, _ in
                _ = attempts.record(.zero)
                guard own.entered == 1 else { return false }
                own.interrupt()
                own.release()
                return true
            },
            operation: { kernel in
                await entry.wait()
                try await kernel.runTurn(chatId: chat)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire()
        let attempted = await eventually { foreign.interrupted > 0 || !attempts.delays.isEmpty }
        XCTAssertTrue(attempted)
        XCTAssertEqual(foreign.interrupted, 0)
        XCTAssertFalse(attempts.delays.isEmpty)
        entry.release()
        let ownEntered = await eventually { own.entered == 1 }
        XCTAssertTrue(ownEntered)
        let acknowledged = await eventually { own.interrupted == 1 }
        XCTAssertTrue(acknowledged)
        own.release()
        await retirement.value
        XCTAssertEqual(own.interrupted, 1)
        foreign.release()
        await unrelated.value
    }

    func testUnprovenWorkRetirementWaitsWithoutInterruptingAnyChatWork() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Unproven action")
        let entry = ResumeWorkerGate()
        let native = ResumeWorkerGate()
        defer {
            entry.release()
            native.release()
        }
        kernel.turnGate = { await native.wait() }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat,
            operation: { kernel in
                await entry.wait()
                try await kernel.runTurn(chatId: chat)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire()
        var finished = false
        let observer = Task {
            await retirement.value
            finished = true
        }
        entry.release()
        let nativeEntered = await eventually { native.entered == 1 }
        XCTAssertTrue(nativeEntered)
        XCTAssertFalse(finished)
        XCTAssertFalse(kernel.calls.contains { $0.name.hasPrefix("interrupt") })
        native.release()
        await observer.value
        XCTAssertTrue(finished)
    }

    func testRetirementStillInterruptsWhenNativeValidationOutlivesTheFormerRetryBudget() async throws {
        let kernel = InMemoryMeshKernel(listener: ChangeLog(), hasMesh: true)
        let chat = try kernel.createChat(title: "Delayed validation")
        let entry = ResumeWorkerGate()
        let native = ResumeWorkerGate()
        let retryBarrier = ResumeWorkerGate()
        let retries = ResumeRetryLog()
        defer {
            entry.release()
            native.release()
            retryBarrier.release()
        }
        kernel.turnGate = { await native.wait() }
        kernel.interruptGate = {
            guard native.entered > 0 else { throw MeshKernelError.notFound }
            native.interrupt()
            native.release()
        }
        let work = MeshTurnWork(
            id: UUID(), kernel: kernel, chatId: chat,
            waitForRetry: { delay in
                if retries.record(delay) >= 101 { await retryBarrier.wait() } else { await Task.yield() }
            },
            interrupt: { kernel, chat in try kernel.interruptTurn(chatId: chat, turnId: "expected-turn") },
            operation: { kernel in
                await entry.wait()
                try await kernel.runTurn(chatId: chat)
                return nil
            })
        let entered = await eventually { entry.entered == 1 }
        XCTAssertTrue(entered)
        let retirement = work.retire()
        let stillRetrying = await eventually { retries.delays.count >= 101 }
        XCTAssertTrue(stillRetrying)
        entry.release()
        let nativeEntered = await eventually { native.entered == 1 }
        XCTAssertTrue(nativeEntered)
        retryBarrier.release()
        if !stillRetrying { native.release() }
        await retirement.value
        XCTAssertEqual(native.interrupted, 1)
        XCTAssertEqual(
            Array(retries.delays.prefix(5)),
            [.milliseconds(20), .milliseconds(40), .milliseconds(80), .milliseconds(160), .milliseconds(250)])
        XCTAssertTrue(retries.delays.dropFirst(4).allSatisfy { $0 == .milliseconds(250) })
    }

    func testAWorkerDoesNotKeepTheRuntimeAliveAndDeinitInterruptsIt() async {
        var runtime: MeshRuntime?
        let kernel: InMemoryMeshKernel
        do {
            let h = MeshRuntimeHarness()
            runtime = h.runtime
            await runtime?.open()
            kernel = h.kernel
            let defaults = h.defaults
            let suite = h.suite
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        }
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        let chat = kernel.seedChat(title: "Open", messages: [MeshRuntimeHarness.message("m", parent: nil, at: 1)])
        kernel.seedOrdinaryResume(chatId: chat, turnId: "existing")
        kernel.turnGate = { await gate.wait() }
        kernel.interruptGate = { gate.interrupt() }
        await runtime?.refreshAll()
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        weak var released = runtime
        runtime = nil
        let retired = await eventually { released == nil && gate.interrupted == 1 }
        XCTAssertTrue(retired)
        gate.release()
    }
}
