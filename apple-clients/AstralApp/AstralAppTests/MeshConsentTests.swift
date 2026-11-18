// Verifies canonical consent binding, roster signing, authentication policy, queue lifecycle and the signer's guards.
// Authentication is stubbed, so no biometric prompt appears and nothing here depends on the device.

import AstralKernel
import CryptoKit
import LocalAuthentication
import XCTest

@testable import AstralDeep

private typealias ConsentPrompt = AstralDeep.ConsentPrompt

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

private nonisolated final class HeldPolicyContext: LAContext, @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool, (any Error)?) -> Void)?
    private var invalidations = 0
    var evaluating: Bool { lock.withLock { reply != nil } }
    var invalidated: Int { lock.withLock { invalidations } }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { true }

    override func evaluatePolicy(
        _ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, (any Error)?) -> Void
    ) {
        lock.withLock { self.reply = reply }
    }

    override func invalidate() {
        let pending = lock.withLock {
            invalidations += 1
            let pending = reply
            reply = nil
            return pending
        }
        pending?(false, LAError(.appCancel))
    }
}

final class LocalAuthenticatorTests: XCTestCase {
    func testAppBundleDeclaresFaceIDPurposeForBiometricConsent() throws {
        let purpose = try XCTUnwrap(
            Bundle(for: AppModel.self).object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String)
        XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCancellingAuthenticationInvalidatesTheSystemPromptAndNeverApproves() async throws {
        let context = HeldPolicyContext()
        let authenticator = LocalAuthenticator(contextFactory: { context })
        let attempt = Task { try await authenticator.authenticate(reason: "Add device", requiresBiometry: true) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !context.evaluating, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(context.evaluating)
        attempt.cancel()
        do {
            _ = try await attempt.value
            XCTFail("A cancelled authentication must not return a context")
        } catch {
            XCTAssertEqual((error as? LAError)?.code, .appCancel)
        }
        XCTAssertEqual(context.invalidated, 1)
    }

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
            : kind == "stop" || kind == "resume" ? #"{"counter":2}"#
            : #"{"device":{"cert":""# + base64(64)
                + #"","identity":""# + base64(65, point: true) + #"","kind":"pocket","label":"Phone","ops":""#
                + base64(32) + #"","presence":""# + base64(65, point: true) + #"","wrap":""# + base64(32) + #""}}"#
        return Data(
            ("astral.roster/v2\n" + #"{"author":""# + device + #"","body":"# + body
                + #","clock":{"ms":5,"n":0},"follows":[""# + mesh + #""],"mesh":""# + mesh
                + #"","type":""# + kind + #"","v":2}"#).utf8)
    }

    static let genesisJSON =
        #"{"author":"sha256:3e12e6c5cc474af72a790b85bc913f15c4a6d50f6f2f60b134e4f39cdcaac43c","body":{"device":{"cert":"XDr9mmu91zSdmXMMGj6X9S8Zc1YWkdExf9BOO4kTNechkih9rSjUKTdT0yd3ppJptJgjlYqrUIFQf_9F2lOfvQ","identity":"BGu-ySJRD-eaPX1InaWwz-PrJKahD2fZmFCTjRDoLxjVkTumbkShewtnlcP_aL0xvDp1CuLZeHYtLWU7JXyDaVU","kind":"desktop","label":"local-v2/alice","ops":"98dbF54AHip3sZoiSvNc6YZDqglrC4XbULQOJNYyqHQ","presence":"BCp9Kf0eZjRdqdF0vzbv833DVCUwjrnRdn6MDc_QCVtwigBiz78fP24SXkgK0azaXzJa3bZkoAjPetPi-nr2grs","wrap":"Lr3sh9YQxdPoDLFDrP-X8kwUbsi2vcAAYjIOlbprDnk"},"epoch":{"group":"personal","recovery_wrap":{"ct":"VPChNAryixWqVOXq9J03EXnEQU_i2ercKcD5aQMv8EumlJSetx5dHgQ4Y8-XbKIP","epk":"kPK_aqTGub9LjrZjCtbIEPR154xjoZUpIXaXKLMpewE","nonce":"UY19FElY0sA2TIc1VJslCWErWAc53q2o"},"wraps":[{"device":"sha256:3e12e6c5cc474af72a790b85bc913f15c4a6d50f6f2f60b134e4f39cdcaac43c","wrap":{"ct":"3yadmSlN-fxT7p20hlIyclm9Z3zaYUutpaOriPBS4NAyO4lmB6nspxBgsTSeMbr3","epk":"9FjpKfWJW3imPOVwlLOOoMaj1DzFgNFRhgmJaAsxvi0","nonce":"trwZIhwjQuI2tRdz_5CzgVLFEdMAGqej"}}]},"recovery":{"sign":"014cllX1QBYdHgnT2N3B9xMkNJJxROWx5_XjqUFqM84","wrap":"cXeOzTwc3KomB8shsFwfmR8h92w6LG2p_f8nKAQpUWo"}},"clock":{"ms":1794441600000,"n":0},"follows":[],"mesh":null,"type":"genesis","v":2}"#
    static let genesis = Data(("astral.roster/v2\n" + genesisJSON).utf8)

    static func mutateGenesis(_ path: [String], value: Any?) throws -> Data {
        var entry = try JSONSerialization.jsonObject(with: Data(genesisJSON.utf8)) as! [String: Any]
        func mutate(_ object: [String: Any], path: ArraySlice<String>) -> [String: Any] {
            var result = object
            let key = path.first!
            if path.count == 1 {
                result[key] = value
            } else {
                result[key] = mutate(result[key] as! [String: Any], path: path.dropFirst())
            }
            return result
        }
        entry = mutate(entry, path: path[...])
        let encoded = try JSONSerialization.data(
            withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data("astral.roster/v2\n".utf8) + (try KernelCanonicalJSON.canonicalize(encoded))
    }

    private static func base64(_ count: Int, point: Bool = false) -> String {
        if point { return "BGu-ySJRD-eaPX1InaWwz-PrJKahD2fZmFCTjRDoLxjVkTumbkShewtnlcP_aL0xvDp1CuLZeHYtLWU7JXyDaVU" }
        let data = Data(repeating: 1, count: count)
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

    func testRealV2GenesisVectorBindsItsCompleteSigningInput() throws {
        let input = BoundConsentFixture.genesis
        let prompt = try ConsentPrompt.roster(signingInput: input)
        XCTAssertEqual(prompt.effect, "roster.genesis")
        XCTAssertEqual(
            prompt.target, "local-v2/alice (sha256:3e12e6c5cc474af72a790b85bc913f15c4a6d50f6f2f60b134e4f39cdcaac43c)")
        XCTAssertTrue(prompt.requiresBiometry)
        XCTAssertTrue(prompt.isBound(to: input))
        XCTAssertFalse(
            prompt.isBound(to: try BoundConsentFixture.mutateGenesis(["clock", "ms"], value: 1_794_441_600_001)))
        let native = AstralKernel.ConsentPrompt(
            kind: .other, title: "create_mesh", target: "untrusted display",
            canonicalAction: Data(), canonicalArguments: Data(), signingInput: input, digest: "ignored",
            untrustedSources: [], labels: [], requiresBiometry: true, batch: 1)
        XCTAssertEqual(try KernelHostSigner.display(for: native, message: input), prompt)
    }

    func testGenesisRejectsNullMissingAndExtraFieldsAtEveryObject() throws {
        let fields: [([String], [String])] = [
            ([], ["v", "type", "mesh", "author", "follows", "clock", "body"]),
            (["clock"], ["ms", "n"]),
            (["body"], ["device", "epoch", "recovery"]),
            (["body", "device"], ["identity", "presence", "ops", "wrap", "cert", "kind", "label"]),
            (["body", "epoch"], ["group", "recovery_wrap", "wraps"]),
            (["body", "epoch", "recovery_wrap"], ["ct", "epk", "nonce"]),
            (["body", "recovery"], ["sign", "wrap"]),
        ]
        for (path, keys) in fields {
            for key in keys {
                XCTAssertThrowsError(
                    try ConsentPrompt.roster(signingInput: BoundConsentFixture.mutateGenesis(path + [key], value: nil)),
                    "missing " + (path + [key]).joined(separator: "."))
                if path + [key] != ["mesh"] {
                    XCTAssertThrowsError(
                        try ConsentPrompt.roster(
                            signingInput: BoundConsentFixture.mutateGenesis(path + [key], value: NSNull())),
                        "null " + (path + [key]).joined(separator: "."))
                }
            }
            XCTAssertThrowsError(
                try ConsentPrompt.roster(
                    signingInput: BoundConsentFixture.mutateGenesis(path + ["extra"], value: true)),
                path.joined(separator: "."))
        }
    }

    func testGenesisRejectsMalformedKeysKindsVersionsAndDomains() throws {
        let paths = [
            ["body", "device", "identity"], ["body", "device", "presence"], ["body", "device", "ops"],
            ["body", "device", "wrap"], ["body", "device", "cert"], ["body", "recovery", "sign"],
            ["body", "recovery", "wrap"], ["body", "epoch", "recovery_wrap", "ct"],
            ["body", "epoch", "recovery_wrap", "epk"], ["body", "epoch", "recovery_wrap", "nonce"],
        ]
        let entry = try JSONSerialization.jsonObject(with: Data(BoundConsentFixture.genesisJSON.utf8)) as! [String: Any]
        for path in paths {
            let original = path.reduce(entry as Any) { ($0 as! [String: Any])[$1]! } as! String
            XCTAssertThrowsError(
                try ConsentPrompt.roster(signingInput: BoundConsentFixture.mutateGenesis(path, value: original + "=")),
                path.joined(separator: "."))
            for value: Any in [true, 1, [], [:], "", "AA", "not+url/base64=", String(repeating: "A", count: 128)] {
                XCTAssertThrowsError(
                    try ConsentPrompt.roster(signingInput: BoundConsentFixture.mutateGenesis(path, value: value)),
                    path.joined(separator: "."))
            }
        }
        let invalidPoint = Data([4] + Array(repeating: UInt8(0), count: 64)).base64EncodedString().replacingOccurrences(
            of: "+", with: "-"
        ).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for key in ["identity", "presence"] {
            XCTAssertThrowsError(
                try ConsentPrompt.roster(
                    signingInput: BoundConsentFixture.mutateGenesis(["body", "device", key], value: invalidPoint)))
        }
        let invalid: [([String], Any)] = [
            (["v"], 1), (["v"], "2"), (["body", "issuers"], []),
            (["author"], BoundConsentFixture.device), (["mesh"], BoundConsentFixture.mesh),
            (["follows"], [BoundConsentFixture.mesh]), (["body", "device", "kind"], "unknown"),
            (["body", "device", "label"], ""), (["body", "device", "label"], String(repeating: "x", count: 65)),
            (["body", "epoch", "group"], "phi"), (["body", "epoch", "wraps"], []),
            (["body", "epoch", "wraps"], [:]),
        ]
        for (path, value) in invalid {
            XCTAssertThrowsError(
                try ConsentPrompt.roster(signingInput: BoundConsentFixture.mutateGenesis(path, value: value)),
                path.joined(separator: "."))
        }
        let input = String(decoding: BoundConsentFixture.genesis, as: UTF8.self)
        for domain in ["astral.roster/v1", "astral.consent/v1", "astral.roster/v2x"] {
            XCTAssertThrowsError(
                try ConsentPrompt.roster(
                    signingInput: Data(input.replacingOccurrences(of: "astral.roster/v2", with: domain).utf8)))
        }
    }

    func testGenesisRejectsMalformedAndDuplicateRecipientWraps() throws {
        let entry = try JSONSerialization.jsonObject(with: Data(BoundConsentFixture.genesisJSON.utf8)) as! [String: Any]
        let body = entry["body"] as! [String: Any]
        let epoch = body["epoch"] as! [String: Any]
        let recipient = (epoch["wraps"] as! [[String: Any]])[0]
        let wrap = recipient["wrap"] as! [String: Any]
        var invalid: [[String: Any]] = [
            ["device": "invalid", "wrap": wrap], ["wrap": wrap], ["device": recipient["device"]!],
            ["device": recipient["device"]!, "wrap": wrap, "extra": true],
        ]
        for field in ["ct", "epk", "nonce"] {
            for value: Any? in [nil, NSNull(), "AA", (wrap[field] as! String) + "="] {
                var malformed = wrap
                malformed[field] = value
                invalid.append(["device": recipient["device"]!, "wrap": malformed])
            }
        }
        var extra = wrap
        extra["extra"] = true
        invalid.append(["device": recipient["device"]!, "wrap": extra])
        for value: Any in invalid + [["device": recipient["device"]!, "wrap": NSNull()]] {
            XCTAssertThrowsError(
                try ConsentPrompt.roster(
                    signingInput: BoundConsentFixture.mutateGenesis(["body", "epoch", "wraps"], value: [value])))
        }
        XCTAssertThrowsError(
            try ConsentPrompt.roster(
                signingInput: BoundConsentFixture.mutateGenesis(
                    ["body", "epoch", "wraps"], value: [recipient, recipient])))
    }

    func testMalformedGenesisNeverReachesBiometricPresenter() throws {
        let suite = "consent.genesis." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let presenter = RecordingPresenter()
        let signer = KernelHostSigner(
            MeshHostSigner(
                keys: try DeviceKeys(
                    store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false),
                presenter: presenter))
        for path in [["body", "device", "presence"], ["body", "epoch"], ["body", "recovery"]] {
            let input = try BoundConsentFixture.mutateGenesis(path, value: NSNull())
            let native = AstralKernel.ConsentPrompt(
                kind: .other, title: "create_mesh", target: "ignored",
                canonicalAction: Data(), canonicalArguments: Data(), signingInput: input, digest: "ignored",
                untrustedSources: [], labels: [], requiresBiometry: true, batch: 1)
            XCTAssertThrowsError(try signer.presenceSign(prompt: native, message: input))
        }
        XCTAssertTrue(presenter.prompts.isEmpty)
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
            original.replacingOccurrences(of: #""device":{"cert":""#, with: #""attestation":null,"device":{"cert":""#),
            original.replacingOccurrences(of: #""label":"Phone""#, with: #""label":"""#),
            original.replacingOccurrences(of: #""kind":"pocket""#, with: #""kind":"unknown""#),
            original.replacingOccurrences(of: #""identity":""#, with: #""extra":1,"identity":""#),
            original.replacingOccurrences(of: #""identity":"B"#, with: #""identity":"A"#),
            original.replacingOccurrences(of: #""cert":""#, with: #""cert":"="#),
        ] {
            XCTAssertThrowsError(try ConsentPrompt.roster(signingInput: Data(text.utf8)), text)
        }
    }

    func testRosterRejectsWrongContextUnsupportedKindAndMalformedBody() {
        let original = String(decoding: BoundConsentFixture.roster(), as: UTF8.self)
        for text in [
            original.replacingOccurrences(of: "astral.roster/v2", with: "astral.consent/v1"),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""type":"unknown""#),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""type":"rotate""#),
            original.replacingOccurrences(
                of: #""author":""# + BoundConsentFixture.device, with: #""author":"recovery"#),
            original.replacingOccurrences(of: #""cutoff":{}"#, with: #""cutoff":[]"#),
            original.replacingOccurrences(of: #""type":"remove""#, with: #""sig":"ignored","type":"remove""#),
            original.replacingOccurrences(of: #""v":2"#, with: #""v":2,"v":2"#),
            original.replacingOccurrences(of: #""v":2"#, with: #""v":1"#),
            original.replacingOccurrences(of: "astral.roster/v2", with: "astral.roster/v1"),
            original + " ",
        ] {
            XCTAssertThrowsError(try ConsentPrompt.roster(signingInput: Data(text.utf8)), text)
        }
    }

    func testGenesisSummaryNamesTheDeviceAndKeepsTheRawFieldsForDetails() throws {
        let prompt = try ConsentPrompt.roster(signingInput: BoundConsentFixture.genesis)
        XCTAssertEqual(prompt.summaryLine, "Create your mesh on local-v2/alice")
        XCTAssertEqual(prompt.effect, "roster.genesis")
        XCTAssertTrue(prompt.arguments.contains("\"type\":\"genesis\""))
        XCTAssertFalse(prompt.digest.isEmpty)
    }

    func testRosterSummariesReadInPlainWords() throws {
        let add = try ConsentPrompt.roster(signingInput: BoundConsentFixture.roster("add"))
        XCTAssertEqual(add.summaryLine, "Add Phone to your mesh")
        let remove = try ConsentPrompt.roster(signingInput: BoundConsentFixture.roster("remove"))
        XCTAssertEqual(remove.summaryLine, "Remove a device from your mesh")
        let stop = try ConsentPrompt.roster(signingInput: BoundConsentFixture.roster("stop"))
        XCTAssertEqual(stop.summaryLine, "Stop your mesh on every device")
        let resume = try ConsentPrompt.roster(signingInput: BoundConsentFixture.roster("resume"))
        XCTAssertEqual(resume.summaryLine, "Resume your mesh on every device")
    }

    func testPromptWithoutAKnownKindFallsBackToAGenericLineAndKeepsItsArguments() throws {
        let prompt = try BoundConsentFixture.prompt()
        XCTAssertNil(prompt.summary)
        XCTAssertEqual(prompt.summaryLine, "Review the details before you approve.")
        XCTAssertTrue(prompt.arguments.contains("Arguments:"))
        XCTAssertEqual(prompt.requiringBiometry(true).summary, prompt.summary)
    }

}

@MainActor
final class MeshConsentCoordinatorTests: XCTestCase {
    private let presenter = UUID()

    private func waitForCurrent(_ coordinator: ConsentCoordinator) async {
        coordinator.registerPresenter(presenter, depth: 0)
        while coordinator.current == nil { await Task.yield() }
    }

    private func approveCurrent(_ coordinator: ConsentCoordinator) async {
        guard let presentation = coordinator.presentation(for: presenter) else {
            return XCTFail("No displayed request")
        }
        await coordinator.approve(presentation)
    }

    private func denyCurrent(_ coordinator: ConsentCoordinator) {
        guard let presentation = coordinator.presentation(for: presenter) else {
            return XCTFail("No displayed request")
        }
        coordinator.deny(presentation)
    }

    func testApproveAfterAuthenticationResolvesApproved() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        XCTAssertEqual(coordinator.current, makePrompt())
        await approveCurrent(coordinator)
        guard case .approved = await pending.value else { return XCTFail("expected approval") }
        XCTAssertNil(coordinator.current)
    }

    func testFailedAuthenticationKeepsPromptAndNeverApproves() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: false))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        await approveCurrent(coordinator)
        XCTAssertNotNil(coordinator.current)
        XCTAssertNotNil(coordinator.authenticationMessage)
        XCTAssertFalse(coordinator.isAuthenticating)
        denyCurrent(coordinator)
        guard case .denied(.denied) = await pending.value else { return XCTFail("expected denial") }
    }

    func testDenyResolvesDenied() async {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        denyCurrent(coordinator)
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
        denyCurrent(coordinator)
        _ = await a.value
        while coordinator.current != second { await Task.yield() }
        await approveCurrent(coordinator)
        guard case .approved = await b.value else { return XCTFail("expected approval") }
    }

    func testRetiredPresentationCannotApproveOrDenyAnotherRequest() async throws {
        let coordinator = ConsentCoordinator(authenticator: StubAuthenticator(succeeds: true))
        let pending = Task { await coordinator.requestConsent(makePrompt()) }
        await waitForCurrent(coordinator)
        let presentation = try XCTUnwrap(coordinator.presentation(for: presenter))
        coordinator.deny(presentation)
        guard case .denied = await pending.value else { return XCTFail("expected denial") }
        await coordinator.approve(presentation)
        coordinator.deny(presentation)
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
