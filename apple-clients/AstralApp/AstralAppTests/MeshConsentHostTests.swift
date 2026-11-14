// Verifies the mounted consent host owns exact-entry callbacks and closing a host cancels its pending work.
// Authentication is controlled in memory, including a late result after a modal has closed.

@testable import AstralDeep
import Foundation
import LocalAuthentication
import Observation
import XCTest

private nonisolated final class ConsentAuthenticationProbe: ConsentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let held: Bool
    private var count = 0
    private var cancelledCount = 0
    private var continuation: CheckedContinuation<LAContext, Error>?

    init(held: Bool = false) { self.held = held }
    var calls: Int { lock.withLock { count } }
    var cancellations: Int { lock.withLock { cancelledCount } }

    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
        if !held {
            lock.withLock { count += 1 }
            return LAContext()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    count += 1
                    self.continuation = continuation
                }
            }
        } onCancel: {
            lock.withLock { cancelledCount += 1 }
        }
    }

    func failAuthentication() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(throwing: ConsentDenial.denied)
    }

    func finishAuthentication() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: LAContext())
    }
}

@MainActor
final class MeshConsentHostTests: XCTestCase {
    private func prompt(_ name: String) -> ConsentPrompt {
        ConsentPrompt(
            actionTitle: name, effect: "roster.add", target: "Synthetic phone", arguments: "Synthetic public record",
            untrustedSource: nil, labels: [], digest: "sha256:" + String(repeating: "ab", count: 32))
    }

    func testAnIdleHostIsNotifiedWhenARequestArrives() async throws {
        let coordinator = ConsentCoordinator()
        let host = UUID()
        coordinator.registerPresenter(host, depth: 0)
        var notified = false
        let idle = withObservationTracking {
            coordinator.presentation(for: host)
        } onChange: {
            notified = true
        }
        XCTAssertNil(idle)
        let request = Task { await coordinator.requestConsent(prompt("Arrives")) }
        let ready = await eventually { coordinator.current != nil }
        XCTAssertTrue(ready)
        XCTAssertTrue(notified, "A host that rendered no prompt must re-render when one arrives")
        XCTAssertNotNil(coordinator.presentation(for: host))
        request.cancel()
        guard case .denied(.cancelled) = await request.value else { return XCTFail("Expected cancellation") }
    }

    func testDeepestHostOwnsPresentationRegardlessOfMountOrder() {
        let coordinator = ConsentCoordinator()
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(modal, depth: 1)
        coordinator.registerPresenter(root, depth: 0)
        XCTAssertEqual(coordinator.presentationOwner, modal)
        coordinator.releasePresenter(UUID())
        XCTAssertEqual(coordinator.presentationOwner, modal)
        coordinator.releasePresenter(modal)
        XCTAssertEqual(coordinator.presentationOwner, root)
        coordinator.releasePresenter(root)
        XCTAssertNil(coordinator.presentationOwner)
    }

    func testStaleParentAndPreviousEntryCallbacksCannotActOnTheChildPrompt() async throws {
        let auth = ConsentAuthenticationProbe()
        let coordinator = ConsentCoordinator(authenticator: auth)
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        let first = Task { await coordinator.requestConsent(prompt("First")) }
        let firstReady = await eventually { coordinator.current?.actionTitle == "First" }
        XCTAssertTrue(firstReady)
        let parentPresentation = try XCTUnwrap(coordinator.presentation(for: root))
        coordinator.registerPresenter(modal, depth: 1)
        let childPresentation = try XCTUnwrap(coordinator.presentation(for: modal))
        XCTAssertNil(coordinator.presentation(for: root))
        coordinator.deny(parentPresentation)
        await coordinator.approve(parentPresentation)
        XCTAssertEqual(coordinator.current?.actionTitle, "First")
        XCTAssertEqual(auth.calls, 0)
        coordinator.deny(childPresentation)
        guard case .denied(.denied) = await first.value else { return XCTFail("Expected explicit denial") }

        let second = Task { await coordinator.requestConsent(prompt("Second")) }
        let secondReady = await eventually { coordinator.current?.actionTitle == "Second" }
        XCTAssertTrue(secondReady)
        coordinator.deny(childPresentation)
        await coordinator.approve(childPresentation)
        XCTAssertEqual(coordinator.current?.actionTitle, "Second")
        XCTAssertEqual(auth.calls, 0)
        await coordinator.approve(try XCTUnwrap(coordinator.presentation(for: modal)))
        guard case .approved = await second.value else { return XCTFail("Expected authenticated approval") }
        XCTAssertEqual(auth.calls, 1)
    }

    func testClosingModalCancelsActiveAndQueuedRequestsBeforeLateAuthentication() async throws {
        let auth = ConsentAuthenticationProbe(held: true)
        let coordinator = ConsentCoordinator(authenticator: auth)
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        coordinator.registerPresenter(modal, depth: 1)
        let first = Task { await coordinator.requestConsent(prompt("First")) }
        let firstReady = await eventually { coordinator.current != nil }
        XCTAssertTrue(firstReady)
        let presentation = try XCTUnwrap(coordinator.presentation(for: modal))
        var enqueued = false
        let second = Task {
            enqueued = true
            return await coordinator.requestConsent(prompt("Second"))
        }
        let queued = await eventually { enqueued }
        XCTAssertTrue(queued)
        let authentication = Task { await coordinator.approve(presentation) }
        let started = await eventually { auth.calls == 1 }
        XCTAssertTrue(started)
        coordinator.releasePresenter(modal)
        XCTAssertEqual(auth.cancellations, 1)
        guard case .denied(.cancelled) = await first.value else {
            return XCTFail("Expected active request cancellation")
        }
        guard case .denied(.cancelled) = await second.value else {
            return XCTFail("Expected queued request cancellation")
        }
        auth.finishAuthentication()
        await authentication.value
        XCTAssertNil(coordinator.current)
        XCTAssertFalse(coordinator.isAuthenticating)
        XCTAssertEqual(coordinator.presentationOwner, root)
        await coordinator.approve(presentation)
        XCTAssertEqual(auth.calls, 1)
    }

    func testClosingParentCancelsItsRequestEvenAfterPresentationMovesToTheModal() async throws {
        let auth = ConsentAuthenticationProbe()
        let coordinator = ConsentCoordinator(authenticator: auth)
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        let request = Task { await coordinator.requestConsent(prompt("Inherited")) }
        let ready = await eventually { coordinator.current != nil }
        XCTAssertTrue(ready)
        coordinator.registerPresenter(modal, depth: 1)
        let presentation = try XCTUnwrap(coordinator.presentation(for: modal))
        coordinator.releasePresenter(root)
        guard case .denied(.cancelled) = await request.value else { return XCTFail("Expected parent cancellation") }
        await coordinator.approve(presentation)
        XCTAssertNil(coordinator.current)
        XCTAssertEqual(auth.calls, 0)
    }

    func testDeeperHostMountingDuringAuthenticationRetiresTheAttemptAndItsLateResult() async throws {
        let auth = ConsentAuthenticationProbe(held: true)
        let coordinator = ConsentCoordinator(authenticator: auth)
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        let first = Task { await coordinator.requestConsent(prompt("First")) }
        let firstReady = await eventually { coordinator.current?.actionTitle == "First" }
        XCTAssertTrue(firstReady)
        let retired = try XCTUnwrap(coordinator.presentation(for: root))
        let authentication = Task { await coordinator.approve(retired) }
        let started = await eventually { auth.calls == 1 }
        XCTAssertTrue(started)
        coordinator.registerPresenter(modal, depth: 1)
        XCTAssertEqual(auth.cancellations, 1)
        guard case .denied(.cancelled) = await first.value else { return XCTFail("Expected cancellation") }
        let second = Task { await coordinator.requestConsent(prompt("Second")) }
        let secondReady = await eventually { coordinator.current?.actionTitle == "Second" }
        XCTAssertTrue(secondReady)
        auth.finishAuthentication()
        await authentication.value
        XCTAssertEqual(coordinator.current?.actionTitle, "Second")
        XCTAssertFalse(coordinator.isAuthenticating)
        XCTAssertNil(coordinator.authenticationMessage)
        await coordinator.approve(retired)
        XCTAssertEqual(auth.calls, 1)
        coordinator.deny(try XCTUnwrap(coordinator.presentation(for: modal)))
        guard case .denied(.denied) = await second.value else { return XCTFail("Expected explicit denial") }
    }

    func testLateFailureOfARetiredAttemptLeavesTheNextRequestUntouched() async throws {
        let auth = ConsentAuthenticationProbe(held: true)
        let coordinator = ConsentCoordinator(authenticator: auth)
        let host = UUID()
        coordinator.registerPresenter(host, depth: 0)
        let first = Task { await coordinator.requestConsent(prompt("First")) }
        let firstReady = await eventually { coordinator.current?.actionTitle == "First" }
        XCTAssertTrue(firstReady)
        let firstPresentation = try XCTUnwrap(coordinator.presentation(for: host))
        let firstAttempt = Task { await coordinator.approve(firstPresentation) }
        let started = await eventually { auth.calls == 1 }
        XCTAssertTrue(started)
        coordinator.deny(firstPresentation)
        guard case .denied(.denied) = await first.value else { return XCTFail("Expected denial during authentication") }
        XCTAssertEqual(auth.cancellations, 1)
        let second = Task { await coordinator.requestConsent(prompt("Second")) }
        let secondReady = await eventually { coordinator.current?.actionTitle == "Second" }
        XCTAssertTrue(secondReady)
        auth.failAuthentication()
        await firstAttempt.value
        XCTAssertNil(coordinator.authenticationMessage)
        XCTAssertFalse(coordinator.isAuthenticating)
        XCTAssertEqual(coordinator.current?.actionTitle, "Second")
        second.cancel()
        guard case .denied(.cancelled) = await second.value else { return XCTFail("Expected cancellation") }
    }

    func testReturningToAPreviousHostIssuesAFreshGenerationAndEntriesAreNeverReused() async throws {
        let coordinator = ConsentCoordinator(authenticator: ConsentAuthenticationProbe())
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        let first = Task { await coordinator.requestConsent(prompt("Same")) }
        let ready = await eventually { coordinator.current != nil }
        XCTAssertTrue(ready)
        let original = try XCTUnwrap(coordinator.presentation(for: root))
        coordinator.registerPresenter(modal, depth: 1)
        coordinator.releasePresenter(modal)
        guard case .denied(.cancelled) = await first.value else { return XCTFail("Expected modal close to cancel") }
        XCTAssertEqual(coordinator.presentationOwner, root)

        let second = Task { await coordinator.requestConsent(prompt("Same")) }
        let secondReady = await eventually { coordinator.current != nil }
        XCTAssertTrue(secondReady)
        let fresh = try XCTUnwrap(coordinator.presentation(for: root))
        XCTAssertEqual(fresh.prompt, original.prompt)
        coordinator.deny(original)
        await coordinator.approve(original)
        XCTAssertNotNil(coordinator.current)
        coordinator.registerPresenter(root, depth: 0)
        let unchanged = try XCTUnwrap(coordinator.presentation(for: root))
        coordinator.deny(unchanged)
        guard case .denied(.denied) = await second.value else { return XCTFail("Expected the fresh binding to work") }
    }

    func testDoubleApproveAuthenticatesOnceAndDenyAfterApprovalChangesNothing() async throws {
        let auth = ConsentAuthenticationProbe(held: true)
        let coordinator = ConsentCoordinator(authenticator: auth)
        let host = UUID()
        coordinator.registerPresenter(host, depth: 0)
        let request = Task { await coordinator.requestConsent(prompt("Once")) }
        let ready = await eventually { coordinator.current != nil }
        XCTAssertTrue(ready)
        let presentation = try XCTUnwrap(coordinator.presentation(for: host))
        let firstTap = Task { await coordinator.approve(presentation) }
        let started = await eventually { auth.calls == 1 }
        XCTAssertTrue(started)
        await coordinator.approve(presentation)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertTrue(coordinator.isAuthenticating)
        auth.finishAuthentication()
        await firstTap.value
        guard case .approved = await request.value else { return XCTFail("Expected one authenticated approval") }
        coordinator.deny(presentation)
        await coordinator.approve(presentation)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertNil(coordinator.current)
        XCTAssertEqual(auth.cancellations, 0)
    }

    func testQueuedRequestsStayWithTheHostThatAskedWhenPresentationMoves() async throws {
        let coordinator = ConsentCoordinator(authenticator: ConsentAuthenticationProbe())
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        let rootActive = Task { await coordinator.requestConsent(prompt("Root active")) }
        let rootReady = await eventually { coordinator.current?.actionTitle == "Root active" }
        XCTAssertTrue(rootReady)
        var rootQueuedAsked = false
        let rootQueued = Task {
            rootQueuedAsked = true
            return await coordinator.requestConsent(prompt("Root queued"))
        }
        let rootQueuedReady = await eventually { rootQueuedAsked }
        XCTAssertTrue(rootQueuedReady)
        await Task.yield()
        coordinator.registerPresenter(modal, depth: 1)
        XCTAssertEqual(coordinator.presentation(for: modal)?.prompt.actionTitle, "Root active")
        var modalAsked = false
        let modalQueued = Task {
            modalAsked = true
            return await coordinator.requestConsent(prompt("Modal queued"))
        }
        let modalReady = await eventually { modalAsked }
        XCTAssertTrue(modalReady)
        await Task.yield()
        coordinator.releasePresenter(modal)
        guard case .denied(.cancelled) = await rootActive.value else {
            return XCTFail("The prompt shown by the closed modal must end")
        }
        guard case .denied(.cancelled) = await modalQueued.value else {
            return XCTFail("The closed modal's queued request must end")
        }
        let survivor = await eventually { coordinator.current?.actionTitle == "Root queued" }
        XCTAssertTrue(survivor)
        XCTAssertNil(coordinator.presentation(for: modal))
        coordinator.deny(try XCTUnwrap(coordinator.presentation(for: root)))
        guard case .denied(.denied) = await rootQueued.value else { return XCTFail("Expected root denial") }
    }

    func testRequestsWithAHostNeverAuthenticateOrApproveWithoutAnApproveTap() async {
        let auth = ConsentAuthenticationProbe()
        let coordinator = ConsentCoordinator(authenticator: auth, timeout: .milliseconds(50))
        let root = UUID()
        let modal = UUID()
        coordinator.registerPresenter(root, depth: 0)
        coordinator.registerPresenter(modal, depth: 1)
        guard case .denied(.timedOut) = await coordinator.requestConsent(prompt("Unattended")) else {
            return XCTFail("An unattended request must time out as a denial")
        }
        coordinator.releasePresenter(modal)
        guard case .denied(.timedOut) = await coordinator.requestConsent(prompt("Unattended root")) else {
            return XCTFail("An unattended request must time out as a denial")
        }
        XCTAssertEqual(auth.calls, 0)
    }
}
