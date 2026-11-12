// Verifies the consent queue, denial, timeout, cancellation, authentication failure and the signer's digest and thread guards.
// Authentication is stubbed, so no biometric prompt appears and nothing here depends on the device.

import CryptoKit
import LocalAuthentication
import XCTest

@testable import AstralDeep

private nonisolated struct StubAuthenticator: ConsentAuthenticating {
    let succeeds: Bool
    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
        guard succeeds else { throw ConsentDenial.denied }
        return LAContext()
    }
}

private func makePrompt(_ digest: String = "sha256:" + String(repeating: "ab", count: 32)) -> ConsentPrompt {
    ConsentPrompt(
        actionTitle: "Send email", effect: "mail.send", target: "to@example.com",
        arguments: "{\"subject\":\"hi\"}", untrustedSource: "a web page", labels: ["untrusted"], digest: digest)
}

@MainActor
final class MeshConsentCoordinatorTests: XCTestCase {
    private func waitForCurrent(_ coordinator: ConsentCoordinator) async {
        while coordinator.current == nil { await Task.yield() }
    }

    func testApproveAfterAuthenticationResolvesApproved() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        XCTAssertEqual(coordinator.current, makePrompt())
        await coordinator.approve()
        guard case .approved = await pending.value else { return XCTFail("expected approval") }
        XCTAssertNil(coordinator.current)
    }

    func testFailedAuthenticationKeepsPromptAndNeverApproves() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: false))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        await coordinator.approve()
        XCTAssertNotNil(coordinator.current)
        XCTAssertNotNil(coordinator.authenticationMessage)
        XCTAssertFalse(coordinator.isAuthenticating)
        coordinator.deny()
        guard case .denied(.denied) = await pending.value else { return XCTFail("expected denial") }
    }

    func testDenyResolvesDenied() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        coordinator.deny()
        guard case .denied(.denied) = await pending.value else { return XCTFail("expected denial") }
        XCTAssertNil(coordinator.current)
    }

    func testTimeoutResolvesAsDenial() async {
        let coordinator = ConsentCoordinator(
            authenticator: StubAuthenticator(succeeds: true), timeout: .milliseconds(20))
        guard case .denied(.timedOut) = await coordinator.requestConsent(makePrompt()) else {
            return XCTFail("expected timeout denial")
        }
        XCTAssertNil(coordinator.current)
    }

    func testCancellationResolvesAsDenialAndDismisses() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        pending.cancel()
        guard case .denied(.cancelled) = await pending.value else { return XCTFail("expected cancellation") }
        while coordinator.current != nil { await Task.yield() }
    }

    func testAlreadyCancelledRequestNeverShows() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.requestConsent(makePrompt())
        }
        guard case .denied(.cancelled) = await pending.value else { return XCTFail("expected cancellation") }
        XCTAssertNil(coordinator.current)
    }

    func testRequestsAreShownOneAtATimeInOrder() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let first = makePrompt("sha256:" + String(repeating: "11", count: 32))
        let second = makePrompt("sha256:" + String(repeating: "22", count: 32))
        let a = Task { await coordinator.requestConsent(first) }
        await waitForCurrent(coordinator)
        let b = Task { await coordinator.requestConsent(second) }
        await Task.yield()
        XCTAssertEqual(coordinator.current, first)
        coordinator.deny()
        _ = await a.value
        while coordinator.current != second { await Task.yield() }
        await coordinator.approve()
        guard case .approved = await b.value else { return XCTFail("expected approval") }
    }

    func testApproveWithNothingPendingDoesNothing() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        await coordinator.approve()
        coordinator.deny()
        XCTAssertNil(coordinator.current)
    }
}

final class MeshHostSignerTests: XCTestCase {
    private struct FixedPresenter: ConsentPresenting {
        let decision: @Sendable () -> ConsentDecision
        func requestConsent(_ prompt: ConsentPrompt) async -> ConsentDecision { decision() }
    }

    private func signer(_ decision: @escaping @Sendable () -> ConsentDecision) throws -> (MeshHostSigner, DeviceKeys) {
        let suite = "MeshHostSignerTests.\(UUID().uuidString)"
        let keys = try DeviceKeys(
            store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
        return (MeshHostSigner(keys: keys, presenter: FixedPresenter(decision: decision)), keys)
    }

    private func signOffMain(_ signer: MeshHostSigner, prompt: ConsentPrompt, message: Data) async throws -> Data {
        try await Task.detached { try signer.presenceSign(prompt: prompt, message: message) }.value
    }

    func testApprovedConsentSignsMessage() async throws {
        let (signer, _) = try signer { .approved(ConsentApproval(context: nil)) }
        let prompt = makePrompt()
        let message = Data(("astral.consent/v1\n{\"action\":\"" + prompt.digest + "\"}").utf8)
        let signature = try await signOffMain(signer, prompt: prompt, message: message)
        XCTAssertEqual(signature.count, 64)
        let key = try P256.Signing.PublicKey(x963Representation: try signer.presencePublicKey())
        XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
        XCTAssertFalse(signer.hardwareBacked())
    }

    func testDeniedConsentThrowsAndSignsNothing() async throws {
        let (signer, _) = try signer { .denied(.denied) }
        let prompt = makePrompt()
        let message = Data(prompt.digest.utf8)
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: message)
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? HostSigningError, .consentDenied(.denied))
        }
    }

    func testTimedOutConsentThrows() async throws {
        let (signer, _) = try signer { .denied(.timedOut) }
        let prompt = makePrompt()
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: Data(prompt.digest.utf8))
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? HostSigningError, .consentDenied(.timedOut))
        }
    }

    func testMessageNotBoundToDisplayedDigestIsRefusedBeforeAnyPrompt() async throws {
        let counter = PromptCounter()
        let (signer, _) = try signer {
            counter.increment()
            return .approved(ConsentApproval(context: nil))
        }
        do {
            _ = try await signOffMain(signer, prompt: makePrompt(), message: Data("unrelated".utf8))
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? HostSigningError, .digestMismatch)
        }
        XCTAssertEqual(counter.value, 0)
    }

    @MainActor
    func testCallingOnTheMainThreadIsRefused() throws {
        let (signer, _) = try signer { .approved(ConsentApproval(context: nil)) }
        let prompt = makePrompt()
        XCTAssertThrowsError(try signer.presenceSign(prompt: prompt, message: Data(prompt.digest.utf8))) {
            XCTAssertEqual($0 as? HostSigningError, .calledOnMainThread)
        }
    }

    func testIdentityOperationsDoNotNeedConsent() throws {
        let (signer, _) = try signer { .denied(.denied) }
        XCTAssertEqual(try signer.identityPublicKey().count, 65)
        XCTAssertEqual(try signer.identitySign(Data("x".utf8)).count, 64)
    }

    func testPromptDigestHelpers() {
        let prompt = makePrompt("sha256:abcdef0123456789ff")
        XCTAssertEqual(prompt.digestHex, "abcdef0123456789ff")
        XCTAssertEqual(prompt.shortDigest, "abcdef012345")
        XCTAssertTrue(prompt.isBound(to: Data("x abcdef0123456789ff y".utf8)))
        XCTAssertFalse(prompt.isBound(to: Data("x y".utf8)))
        XCTAssertFalse(makePrompt("").isBound(to: Data("anything".utf8)))
    }
}

private nonisolated final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
