// Exercises the real portable keyboard and drag sequencers under changing observation and desktop authority.
// The Mac driver uses these same callbacks before every emitted input step and safety release.

import XCTest

@testable import AstralCore

final class ComputerPhysicalBoundaryTests: XCTestCase {
    func testNativeMutationCannotTargetItsOwnProcessOrWindows() throws {
        XCTAssertThrowsError(try ComputerHostTargetPolicy.externalProcess(10, hostPID: 10))
        XCTAssertThrowsError(try ComputerHostTargetPolicy.externalProcess(nil, hostPID: 10))
        XCTAssertNoThrow(try ComputerHostTargetPolicy.externalProcess(20, hostPID: 10))
        let covered = CGRect(x: 10, y: 10, width: 50, height: 50)
        let own = ComputerHostTargetWindow(pid: 10, bounds: covered)
        let other = ComputerHostTargetWindow(pid: 20, bounds: covered)
        XCTAssertThrowsError(
            try ComputerHostTargetPolicy.externalPoint(CGPoint(x: 20, y: 20), hostPID: 10, windows: [own, other]))
        XCTAssertNoThrow(
            try ComputerHostTargetPolicy.externalPoint(CGPoint(x: 20, y: 20), hostPID: 10, windows: [other, own]))
        XCTAssertNoThrow(try ComputerHostTargetPolicy.externalPoint(CGPoint(x: 80, y: 80), hostPID: 10, windows: [own]))
    }

    func testConsentRequiresFreshOneUsePhysicalInputIncludingAsyncActivation() {
        var proof = ComputerHostLocalInputProof(hostPID: 20, marker: 30)
        XCTAssertFalse(proof.consume(at: 10))
        proof.record(sourcePID: 0, sourceState: 1, userData: 0, at: 10)
        XCTAssertTrue(proof.consume(at: 10.5))
        XCTAssertFalse(proof.consume(at: 10.5))
        proof.record(sourcePID: 0, sourceState: 1, userData: 0, at: 12)
        XCTAssertFalse(proof.consume(at: 15))
    }

    func testInjectedOrUnknownInputCannotRearmOrReusePhysicalEvidence() {
        for event in [(Int32(20), Int64(1), Int64(0)), (0, 1, 30), (50, 0, 0)] {
            var proof = ComputerHostLocalInputProof(hostPID: 20, marker: 30)
            proof.record(sourcePID: 0, sourceState: 1, userData: 0, at: 10)
            proof.record(sourcePID: event.0, sourceState: event.1, userData: event.2, at: 10.1)
            XCTAssertFalse(proof.consume(at: 10.2))
        }
        var proof = ComputerHostLocalInputProof(hostPID: 20, marker: 30)
        proof.record(sourcePID: 0, sourceState: 1, userData: 0, at: 10)
        proof.invalidate()
        XCTAssertFalse(proof.consume(at: 10.1))
    }

    func testUnavailableDesktopRejectsNewSessionAndOldTicket() throws {
        let authority = ComputerHostAuthority()
        let session = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try authority.begin(session))
        authority.setDesktopAvailable(true)
        try authority.begin(session)
        let request = try ComputerHostRequest(
            json: .object([
                "type": .string("computer_request"), "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                "session_id": .string(session), "verb": .string("wait"), "args": .object([:]),
                "deadline_ms": .number(1000),
            ]))
        let ticket = try authority.admit(request)
        authority.setDesktopAvailable(false)
        XCTAssertThrowsError(try authority.verify(ticket))
        XCTAssertThrowsError(try authority.begin(UUID().uuidString.lowercased()))
    }

    func testKeyboardStopsAfterFirstChunkWhenFocusOrTopologyChanges() async throws {
        for changeFocus in [true, false] {
            let state = PhysicalTestState()
            let expected = state.identity
            do {
                try await ComputerHostInputSequence.type(
                    String(repeating: "a", count: 100),
                    authorize: {
                        try ComputerHostObservationGate.validate(
                            expected: expected, current: state.identity, requireScreenshot: false)
                    },
                    post: { _, down in
                        if down { state.change(afterFocus: changeFocus) }
                    })
                XCTFail("A changed observation must stop the production keyboard sequence")
            } catch {}
            XCTAssertEqual(state.downs, 1)
        }
    }

    func testDragRevocationReleasesAtCurrentPositionWithoutEndJump() async throws {
        let state = PhysicalTestState()
        let expected = state.identity
        let end = CGPoint(x: 100, y: 100)
        do {
            try await ComputerHostInputSequence.drag(
                from: .zero, to: end,
                authorize: {
                    try ComputerHostObservationGate.validate(
                        expected: expected, current: state.identity, requireScreenshot: true)
                }, post: { step in state.record(step) }, delay: {})
            XCTFail("Revocation must stop the drag")
        } catch {}
        XCTAssertEqual(state.drags, 1)
        XCTAssertEqual(state.releases, 1)
        XCTAssertNotEqual(state.cursor, end)
    }

    func testPointerNeedsKnownIdentityAndCurrentScreenshot() {
        let unknown = ComputerHostObservationIdentity(foreground: nil, topology: "a", screenshot: true)
        XCTAssertThrowsError(
            try ComputerHostObservationGate.validate(expected: unknown, current: unknown, requireScreenshot: true))
        let unseen = ComputerHostObservationIdentity(foreground: 1, topology: "a", screenshot: false)
        XCTAssertThrowsError(
            try ComputerHostObservationGate.validate(expected: unseen, current: unseen, requireScreenshot: true))
    }
}

private final class PhysicalTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ComputerHostObservationIdentity(foreground: 1, topology: "a", screenshot: true)
    private var count = 0
    private var moves = 0
    private var ups = 0
    private var position = CGPoint.zero
    var identity: ComputerHostObservationIdentity {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    var downs: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    var drags: Int {
        lock.lock()
        defer { lock.unlock() }
        return moves
    }
    var releases: Int {
        lock.lock()
        defer { lock.unlock() }
        return ups
    }
    var cursor: CGPoint {
        lock.lock()
        defer { lock.unlock() }
        return position
    }
    func change(afterFocus: Bool) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        value = ComputerHostObservationIdentity(
            foreground: afterFocus ? 2 : 1, topology: afterFocus ? "a" : "b", screenshot: true)
    }
    func record(_ step: ComputerHostPointerStep) {
        lock.lock()
        defer { lock.unlock() }
        switch step {
        case .down(let point): position = point
        case .drag(let point):
            position = point
            moves += 1
            value = ComputerHostObservationIdentity(foreground: 2, topology: "a", screenshot: true)
        case .release: ups += 1
        }
    }
}
