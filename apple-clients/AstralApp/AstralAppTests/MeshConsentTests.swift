// Verifies canonical consent binding, roster signing, authentication policy, queue lifecycle and the signer's guards.
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

private nonisolated final class StubPolicyContext: LAContext, @unchecked Sendable {
    let evaluations = PromptCounter()
    let biometryAvailable: Bool
    let expectedPolicy: LAPolicy

    init(biometryAvailable: Bool, expectedPolicy: LAPolicy) {
        self.biometryAvailable = biometryAvailable
        self.expectedPolicy = expectedPolicy
        super.init()
    }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { biometryAvailable }

    override func evaluatePolicy(
        _ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, (any Error)?) -> Void
    ) {
        evaluations.increment()
        reply(policy == expectedPolicy, nil)
    }
}

final class LocalAuthenticatorTests: XCTestCase {
    func testRequiredBiometryEvaluatesOnlyBiometricPolicy() async throws {
        let context = StubPolicyContext(
            biometryAvailable: true, expectedPolicy: .deviceOwnerAuthenticationWithBiometrics)
        let authenticator = LocalAuthenticator(contextFactory: { context })
        let approved = try await authenticator.authenticate(reason: "Add device", requiresBiometry: true)
        XCTAssertTrue(approved === context)
        XCTAssertEqual(context.localizedFallbackTitle, "")
        XCTAssertEqual(context.evaluations.value, 1)
    }

    func testActionMayEvaluateOwnerAuthenticationWithoutBiometry() async throws {
        let context = StubPolicyContext(biometryAvailable: false, expectedPolicy: .deviceOwnerAuthentication)
        let approved = try await LocalAuthenticator(contextFactory: { context })
            .authenticate(reason: "Approve tool", requiresBiometry: false)
        XCTAssertTrue(approved === context)
        XCTAssertEqual(context.evaluations.value, 1)
    }

    func testRequiredBiometryRefusesUnavailableBiometryWithoutAuthentication() async {
        let context = StubPolicyContext(biometryAvailable: false, expectedPolicy: .deviceOwnerAuthentication)
        let authenticator = LocalAuthenticator(contextFactory: { context })
        do {
            _ = try await authenticator.authenticate(reason: "Add device", requiresBiometry: true)
            XCTFail("expected unavailable biometry denial")
        } catch {
            XCTAssertEqual(error as? ConsentDenial, .denied)
        }
        XCTAssertEqual(context.evaluations.value, 0)
    }
}

private func makePrompt(_ digest: String = "sha256:" + String(repeating: "ab", count: 32)) -> ConsentPrompt {
    ConsentPrompt(
        actionTitle: "Send email", effect: "mail.send", target: "to@example.com",
        arguments: "{\"subject\":\"hi\"}", untrustedSource: "a web page", labels: ["untrusted"], digest: digest)
}

private nonisolated enum BoundConsentFixture {
    static let device = "sha256:" + String(repeating: "22", count: 32)
    static let mesh = "sha256:" + String(repeating: "11", count: 32)
    static let influence = "sha256:" + String(repeating: "55", count: 32)
    static let digest = "sha256:7ac3722123cc474d61ea44588fa850d924c9314354faf843bc39939b0d25fb90"
    static let arguments = Data(#"{"subject":"hi","to":"to@example.com"}"#.utf8)
    static let action = Data(
        (#"{"agent":"mail-agent","args_digest":"sha256:5893f8f0b40cbada559fa66c78342bf0885a745a8a3bf76f093b92f2df93faa8","device":""#
            + device + #"","influence":[""# + influence + #""],"mesh":""# + mesh
            + #"","tool":"mail.send","tool_def":"sha256:"# + String(repeating: "44", count: 32)
            + #"","turn":"sha256:"# + String(repeating: "33", count: 32) + #"","v":1}"#).utf8)
    static let message = Data(
        (#"astral.consent/v1"# + "\n" + #"{"clock":{"ms":5,"n":0},"device":""# + device
            + #"","digest":""# + digest + #"","kind":"action","v":1}"#).utf8)

    static func prompt() throws -> ConsentPrompt {
        try ConsentPrompt.action(canonicalAction: action, canonicalArguments: arguments, signingInput: message)
    }

    static func roster(_ kind: String = "remove") -> Data {
        let body =
            kind == "remove"
            ? #"{"cutoff":{},"device":""# + device + #""}"#
            : #"{"attestation":null,"device":{"cert":""# + base64(64)
                + #"","identity":""# + base64(65, point: true) + #"","kind":"pocket","label":"Phone","ops":""#
                + base64(32) + #"","presence":""# + base64(65, point: true) + #"","wrap":""# + base64(32) + #""}}"#
        return Data(
            ("astral.roster/v1\n" + #"{"author":""# + device + #"","body":"# + body
                + #","clock":{"ms":5,"n":0},"follows":[""# + mesh + #""],"mesh":""# + mesh
                + #"","type":""# + kind + #"","v":1}"#).utf8)
    }

    private static func base64(_ count: Int, point: Bool = false) -> String {
        var data = Data(repeating: 1, count: count)
        if point { data[0] = 4 }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

final class ConsentPromptBindingTests: XCTestCase {
    func testActionDisplaysOnlyCanonicalActionAndArguments() throws {
        let prompt = try BoundConsentFixture.prompt()
        XCTAssertEqual(prompt.effect, "mail.send")
        XCTAssertEqual(prompt.digest, BoundConsentFixture.digest)
        XCTAssertTrue(prompt.arguments.contains(String(decoding: BoundConsentFixture.action, as: UTF8.self)))
        XCTAssertTrue(prompt.arguments.contains(String(decoding: BoundConsentFixture.arguments, as: UTF8.self)))
        XCTAssertEqual(prompt.untrustedSource, BoundConsentFixture.influence)
        XCTAssertTrue(prompt.isBound(to: BoundConsentFixture.message))
        XCTAssertFalse(makePrompt(BoundConsentFixture.digest).isBound(to: BoundConsentFixture.message))
    }

    func testActionRejectsDifferentArgumentsAndDifferentAction() {
        XCTAssertThrowsError(
            try ConsentPrompt.action(
                canonicalAction: BoundConsentFixture.action, canonicalArguments: Data(#"{"subject":"changed"}"#.utf8),
                signingInput: BoundConsentFixture.message))
        let changed = Data(
            String(decoding: BoundConsentFixture.action, as: UTF8.self)
                .replacingOccurrences(of: "mail.send", with: "mail.delete").utf8)
        XCTAssertThrowsError(
            try ConsentPrompt.action(
                canonicalAction: changed, canonicalArguments: BoundConsentFixture.arguments,
                signingInput: BoundConsentFixture.message))
    }

    func testActionRejectsWrongContextKindDigestAndMalformedSigningInput() {
        let original = String(decoding: BoundConsentFixture.message, as: UTF8.self)
        let invalid = [
            original.replacingOccurrences(of: "astral.consent/v1", with: "astral.roster/v1"),
            original.replacingOccurrences(of: #""kind":"action""#, with: #""kind":"policy""#),
            original.replacingOccurrences(of: #""kind":"action""#, with: #""kind":"unknown""#),
            original.replacingOccurrences(of: BoundConsentFixture.digest, with: BoundConsentFixture.device),
            original.replacingOccurrences(of: BoundConsentFixture.digest, with: BoundConsentFixture.device)
                .replacingOccurrences(
                    of: #""v":1"#, with: #""unrelated":""# + BoundConsentFixture.digest + #"","v":1"#),
            original.replacingOccurrences(
                of: #""digest":""# + BoundConsentFixture.digest,
                with: #""unrelated":""# + BoundConsentFixture.digest),
            original.replacingOccurrences(of: #""v":1"#, with: #""v":1,"v":1"#),
            original.replacingOccurrences(of: #""v":1"#, with: #""v":true"#),
            original.replacingOccurrences(of: #""ms":5"#, with: #""ms":5.0"#),
            original.replacingOccurrences(of: #""ms":5"#, with: #""ms":-1"#),
            original.replacingOccurrences(of: #""ms":5"#, with: #""ms":9223372036854775808"#),
            original + " ",
            BoundConsentFixture.digest,
        ]
        for text in invalid {
            XCTAssertThrowsError(
                try ConsentPrompt.action(
                    canonicalAction: BoundConsentFixture.action, canonicalArguments: BoundConsentFixture.arguments,
                    signingInput: Data(text.utf8)), text)
        }
        XCTAssertThrowsError(
            try ConsentPrompt.action(
                canonicalAction: BoundConsentFixture.action, canonicalArguments: BoundConsentFixture.arguments,
                signingInput: Data([0xFF])))
    }

    func testActionRejectsNoncanonicalAndDuplicateActionOrArguments() {
        let original = String(decoding: BoundConsentFixture.action, as: UTF8.self)
        for text in [
            original + " ", original.replacingOccurrences(of: #""v":1"#, with: #""v":1,"v":1"#),
            original.replacingOccurrences(of: "mail.send", with: "mail.\\u0073end"),
        ] {
            XCTAssertThrowsError(
                try ConsentPrompt.action(
                    canonicalAction: Data(text.utf8), canonicalArguments: BoundConsentFixture.arguments,
                    signingInput: BoundConsentFixture.message))
        }
        for text in [
            #"{"subject":"hi", "to":"to@example.com"}"#,
            #"{"subject":"hi","subject":"hi","to":"to@example.com"}"#,
        ] {
            XCTAssertThrowsError(
                try ConsentPrompt.action(
                    canonicalAction: BoundConsentFixture.action, canonicalArguments: Data(text.utf8),
                    signingInput: BoundConsentFixture.message))
        }
    }

    func testActionBindingCoversEntireSigningInput() throws {
        let prompt = try BoundConsentFixture.prompt()
        let changed = String(decoding: BoundConsentFixture.message, as: UTF8.self)
            .replacingOccurrences(of: #""ms":5"#, with: #""ms":6"#)
        XCTAssertFalse(prompt.isBound(to: Data(changed.utf8)))
        XCTAssertFalse(prompt.isBound(to: Data(prompt.digest.utf8)))
    }

    func testRosterAddAndRemoveBindFullInputAndRequireBiometry() throws {
        for kind in ["add", "remove"] {
            let message = BoundConsentFixture.roster(kind)
            let prompt = try ConsentPrompt.roster(signingInput: message)
            XCTAssertTrue(prompt.requiresBiometry)
            XCTAssertTrue(prompt.isBound(to: message))
            XCTAssertEqual(prompt.effect, "roster." + kind)
            XCTAssertTrue(
                prompt.arguments.contains(String(decoding: message, as: UTF8.self).components(separatedBy: "\n")[1]))
            let changed = Data(
                String(decoding: message, as: UTF8.self)
                    .replacingOccurrences(of: #""ms":5"#, with: #""ms":6"#).utf8)
            XCTAssertFalse(prompt.isBound(to: changed))
            XCTAssertFalse(prompt.isBound(to: Data(prompt.digest.utf8)))
        }
    }

    func testRosterAddRejectsMalformedDeviceRecord() {
        let original = String(decoding: BoundConsentFixture.roster("add"), as: UTF8.self)
        for text in [
            original.replacingOccurrences(of: #""attestation":null"#, with: #""attestation":true"#),
            original.replacingOccurrences(of: #""label":"Phone""#, with: #""label":"""#),
            original.replacingOccurrences(of: #""kind":"pocket""#, with: #""kind":"unknown""#),
            original.replacingOccurrences(of: #""identity":""#, with: #""extra":1,"identity":""#),
            original.replacingOccurrences(of: #""identity":"BA"#, with: #""identity":"AA"#),
            original.replacingOccurrences(of: #""cert":""#, with: #""cert":"="#),
        ] {
            XCTAssertThrowsError(try ConsentPrompt.roster(signingInput: Data(text.utf8)), text)
        }
    }

    func testRosterRejectsWrongContextUnsupportedKindAndMalformedBody() {
        let original = String(decoding: BoundConsentFixture.roster(), as: UTF8.self)
        for text in [
            original.replacingOccurrences(of: "astral.roster/v1", with: "astral.consent/v1"),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""type":"unknown""#),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""type":"rotate""#),
            original.replacingOccurrences(
                of: #""author":""# + BoundConsentFixture.device, with: #""author":"recovery"#),
            original.replacingOccurrences(of: #""cutoff":{}"#, with: #""cutoff":[]"#),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""sig":"ignored","type":"remove""#),
            original.replacingOccurrences(of: #""v":1"#, with: #""v":1,"v":1"#),
            original + " ",
        ] {
            XCTAssertThrowsError(try ConsentPrompt.roster(signingInput: Data(text.utf8)), text)
        }
    }
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
        let prompt = try BoundConsentFixture.prompt()
        let message = BoundConsentFixture.message
        let signature = try await signOffMain(signer, prompt: prompt, message: message)
        XCTAssertEqual(signature.count, 64)
        let key = try P256.Signing.PublicKey(x963Representation: try signer.presencePublicKey())
        XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
        XCTAssertFalse(signer.hardwareBacked())
    }

    func testRosterAddAndRemoveSignExactCanonicalMessages() async throws {
        let (signer, _) = try signer { .approved(ConsentApproval(context: nil)) }
        let key = try P256.Signing.PublicKey(x963Representation: signer.presencePublicKey())
        for kind in ["add", "remove"] {
            let message = BoundConsentFixture.roster(kind)
            let prompt = try ConsentPrompt.roster(signingInput: message)
            let signature = try await signOffMain(signer, prompt: prompt, message: message)
            XCTAssertTrue(
                key.isValidSignature(
                    try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
        }
    }

    func testBoundPromptRejectsChangedInputBeforePresenter() async throws {
        let counter = PromptCounter()
        let (signer, _) = try signer {
            counter.increment()
            return .approved(ConsentApproval(context: nil))
        }
        let prompt = try BoundConsentFixture.prompt()
        let changed = Data(
            String(decoding: BoundConsentFixture.message, as: UTF8.self)
                .replacingOccurrences(of: #""kind":"action""#, with: #""kind":"policy""#).utf8)
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: changed)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? HostSigningError, .digestMismatch)
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testDeniedConsentThrowsAndSignsNothing() async throws {
        let (signer, _) = try signer { .denied(.denied) }
        let prompt = try BoundConsentFixture.prompt()
        let message = BoundConsentFixture.message
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: message)
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? HostSigningError, .consentDenied(.denied))
        }
    }

    func testTimedOutConsentThrows() async throws {
        let (signer, _) = try signer { .denied(.timedOut) }
        let prompt = try BoundConsentFixture.prompt()
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: BoundConsentFixture.message)
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

    func testDisplayOnlyPromptCannotAuthorizeMessageContainingItsDigest() async throws {
        let counter = PromptCounter()
        let (signer, _) = try signer {
            counter.increment()
            return .approved(ConsentApproval(context: nil))
        }
        let prompt = makePrompt()
        do {
            _ = try await signOffMain(signer, prompt: prompt, message: Data(prompt.digest.utf8))
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
        XCTAssertFalse(prompt.isBound(to: Data("x abcdef0123456789ff y".utf8)))
        XCTAssertFalse(prompt.isBound(to: Data("x y".utf8)))
        XCTAssertFalse(makePrompt("").isBound(to: Data("anything".utf8)))
    }
}

private nonisolated final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
