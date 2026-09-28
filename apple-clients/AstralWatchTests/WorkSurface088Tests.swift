// Tests for the watch Work surface: isolation from conversation speech, owner/connection-change clearing
// without queueing reads, disabled-button validity, admission-refusal ticket retirement, reconnect retry
// retention, and the ten-second read timeout measured on a controllable clock.

import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class WatchWorkSurface088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let other = "44444444-4444-4444-8444-444444444444"

    private func frame(_ request: JSONValue) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("work"), "region": .string("modal"),
                "title": .string("Server title"), "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": request,
                "components": .array([
                    .object([
                        "type": .string("text"), "content": .string("Exact **excerpt**"), "variant": .string("body"),
                    ])
                ]),
            ]))
    }

    private func model() -> WatchModel {
        let model = WatchModel()
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        model.connected = true
        model.workVisible = true
        let request = WorkReadRequest(
            payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
        model.workReadState.begin(request, generation: generation)
        return model
    }

    func testWorkIsSeparateFromConversationAndCannotSpeakOrPaintStaleResponse() {
        let model = model()
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Original canvas")]))]
        model.pendingDictation = "Draft"
        let canvas = model.canvas
        model.handleFrame(frame(.string(other)))
        model.handleFrame(frame(.null))
        XCTAssertNil(model.workUpdate)
        model.handleFrame(frame(.string(generation)))
        XCTAssertEqual(model.workUpdate?.title, "Server title")
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.pendingDictation, "Draft")
        XCTAssertFalse(model.speaker.isSpeaking)
        model.closeWorkRead()
        model.handleFrame(frame(.string(generation)))
        XCTAssertFalse(model.workVisible)
        XCTAssertNil(model.workUpdate)
    }

    func testOwnerAndConnectionChangesClearPrivateWorkAndNeverQueueARead() async {
        for ownerChange in [true, false] {
            let model = model()
            model.handleFrame(frame(.string(generation)))
            if ownerChange {
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            } else {
                await model.handle(.disconnected(reason: "synthetic"))
            }
            XCTAssertNil(model.workReadState.generation)
            XCTAssertNil(model.workUpdate)
            model.handleFrame(frame(.string(generation)))
            XCTAssertNil(model.workUpdate)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testUnrelatedChromeAndMissingServerDescriptorRemainNoninteractive() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"settings","kind":"menu"},{"key":"pulse","kind":"action","label":"Pulse","action":{"surface":"pulse"}}],"menu":[]}}"#
            )!)
        XCTAssertTrue(model.workControls.isEmpty)
        XCTAssertFalse(model.workVisible)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Setup","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.workUpdate)
        XCTAssertFalse(model.workVisible)
        XCTAssertTrue(model.canvas.isEmpty)
    }
    func testDuplicateWorkResponseCannotReplaceOrCloseAcceptedContent() {
        let model = model()
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workReadState.generation)
        var payload = frame(.string(generation)).payload.objectValue!
        payload["title"] = .string("Late replacement")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertEqual(model.workUpdate?.title, "Server title")
        payload["components"] = .array([])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertTrue(model.workVisible)
        XCTAssertEqual(model.workUpdate?.title, "Server title")
    }

    func testAdmissionRefusalRetiresWorkTicketWithoutQueueing() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"work","kind":"action","label":"Work","action":{"surface":"work","params":{"mode":"list"}}}],"menu":[]}}"#
            )!)
        let control = model.workControls.first!
        model.connected = false
        model.openWork(control)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
    func testTimeoutOrSendFailureRetiresOnlyCurrentTicketAndKeepsRetrySelection() {
        let model = model()
        model.failWorkRead(generation: other)
        XCTAssertEqual(model.workReadState.generation, generation)
        model.failWorkRead(generation: generation)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workUpdate)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Late","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.workUpdate)
        XCTAssertTrue(model.workReadFailed)
    }

    func testMatchingAdmissionRefusalRetiresPrivateReadBeforeGenericErrorHandling() {
        let model = model()
        let request = model.workReadState.request!
        let text = request.frameText(requestGeneration: generation)
        XCTAssertTrue(model.workReadState.bindSubmission(frameText: text))
        let submission = model.workReadState.submissionId!
        let refusal = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,
             "code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
            """)!
        model.handleFrame(refusal)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.errorBanner)
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workUpdate)
    }
    func testReconnectKeepsSelectedRetiredWorkUnavailableUntilExplicitRead() async {
        let model = model()
        await model.handle(.disconnected(reason: "synthetic"))
        XCTAssertTrue(model.workVisible)
        XCTAssertTrue(model.workReadFailed)
        await model.handle(.connected)
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertNil(model.workUpdate)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }

    func testReadExpiresWhenTheModelClockReachesTenSecondsAndNotEarlier() async {
        XCTAssertEqual(WatchModel.workReadTimeout, .seconds(10))
        XCTAssertTrue(WatchModel().workReadClock is SuspendingClock)
        let model = model()
        let clock = ManualClock()
        model.workReadClock = clock
        let expiry = Task { await model.expireWorkRead(generation: generation) }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(10) - .milliseconds(1))
        XCTAssertEqual(clock.pendingSleeps, 1)
        XCTAssertEqual(model.workReadState.generation, generation)
        XCTAssertFalse(model.workReadFailed)
        clock.advance(by: .milliseconds(1))
        let expired = await expiry.value
        XCTAssertTrue(expired)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
    }

    func testAnsweredOrCancelledReadTimerNeverFailsTheRead() async {
        let answered = model()
        let clock = ManualClock()
        answered.workReadClock = clock
        let answeredExpiry = Task { await answered.expireWorkRead(generation: generation) }
        await clock.waitForSleeper()
        answered.handleFrame(frame(.string(generation)))
        clock.advance(by: WatchModel.workReadTimeout)
        let answeredExpired = await answeredExpiry.value
        XCTAssertFalse(answeredExpired)
        XCTAssertEqual(answered.workUpdate?.title, "Server title")
        XCTAssertFalse(answered.workReadFailed)

        let pending = model()
        pending.workReadClock = clock
        let pendingExpiry = Task { await pending.expireWorkRead(generation: generation) }
        await clock.waitForSleeper()
        pendingExpiry.cancel()
        let pendingExpired = await pendingExpiry.value
        XCTAssertFalse(pendingExpired)
        XCTAssertEqual(clock.pendingSleeps, 0)
        XCTAssertEqual(pending.workReadState.generation, generation)
        XCTAssertFalse(pending.workReadFailed)
    }
}

private nonisolated final class ManualClock: Clock, @unchecked Sendable {
    nonisolated struct Instant: InstantProtocol {
        let offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var registration: CheckedContinuation<Void, Never>?

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (outcome, waiter) = lock.withLock {
                    () -> (Result<Void, Error>?, CheckedContinuation<Void, Never>?) in
                    if Task.isCancelled { return (.failure(CancellationError()), nil) }
                    if deadline <= current { return (.success(()), nil) }
                    sleepers[id] = (deadline, continuation)
                    defer { registration = nil }
                    return (nil, registration)
                }
                if let outcome { continuation.resume(with: outcome) }
                waiter?.resume()
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitForSleeper() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                guard sleepers.isEmpty else { return true }
                registration = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func advance(by duration: Swift.Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}
