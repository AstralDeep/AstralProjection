// Verifies the mounted consent host owns exact-entry callbacks and closing a host cancels its pending work.
// Authentication is controlled in memory, including a late result after a modal has closed.

@testable import AstralDeep
import Foundation
import LocalAuthentication
import XCTest

private nonisolated final class ConsentAuthenticationProbe: ConsentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let held: Bool
    private var count = 0
    private var continuation: CheckedContinuation<LAContext, Error>?

    init(held: Bool = false) { self.held = held }
    var calls: Int { lock.withLock { count } }

    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
        if !held {
            lock.withLock { count += 1 }
            return LAContext()
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                count += 1
                self.continuation = continuation
            }
        }
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
}
