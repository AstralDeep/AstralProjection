// Test doubles for the kernel wrapper: a software host signer, a test token issuer with its key set, and polling and configuration helpers.
// Nothing here touches the network, the Keychain or the Secure Enclave.
import CryptoKit
import Foundation
import XCTest

@testable import AstralKernel

final class SoftwareHostSigner: HostSigner, @unchecked Sendable {
    private let identity = P256.Signing.PrivateKey()
    private let presence = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var prompts: [ConsentPrompt] = []
    var allowPresence = true

    var seenPrompts: [ConsentPrompt] { lock.withLock { prompts } }

    func identityPublicKey() -> Data { identity.publicKey.x963Representation }

    func identitySign(message: Data) throws -> Data {
        try identity.signature(for: message).rawRepresentation
    }

    func presencePublicKey() -> Data { presence.publicKey.x963Representation }

    func presenceSign(prompt: ConsentPrompt, message: Data) throws -> Data {
        lock.withLock { prompts.append(prompt) }
        guard allowPresence else { throw HostSignerError.Denied(message: "declined") }
        return try presence.signature(for: message).rawRepresentation
    }

    func hardwareBacked() -> Bool { false }
}

enum TestIssuer {
    static let issuer = "https://auth.example.test/realms/astral"
    static let client = "astral-desktop"
    private static let key = P256.Signing.PrivateKey()

    static var config: IssuerConfig {
        let point = key.publicKey.x963Representation
        let jwks: [String: Any] = [
            "keys": [
                [
                    "kid": "k1", "kty": "EC", "crv": "P-256", "x": b64(point[1..<33]), "y": b64(point[33..<65]),
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: jwks, options: [.sortedKeys])
        return IssuerConfig(issuer: issuer, clientId: client, jwksJson: String(decoding: data, as: UTF8.self))
    }

    static func token(nonce: String, subject: String) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = b64(json(["alg": "ES256", "kid": "k1", "typ": "JWT"]))
        let claims: [String: Any] = [
            "iss": issuer, "aud": client, "sub": subject, "iat": now, "exp": now + 300, "nonce": nonce,
        ]
        let signingInput = header + "." + b64(json(claims))
        let signature = try! key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + b64(signature)
    }

    private static func json(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func b64(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct TestDevice {
    let directory: URL
    let signer: SoftwareHostSigner
    let operations: Data
    let wrap: Data
    let marker: Data
    let label: String

    init(label: String, in testCase: XCTestCase, marker: UInt8) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astral-kernel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory) }
        signer = SoftwareHostSigner()
        operations = try newOperationsSecret()
        wrap = try newOperationsSecret()
        self.marker = Data(repeating: marker, count: 32)
        self.label = label
    }

    var config: KernelConfig {
        KernelConfig(
            dataDir: directory.path, operationsSecret: operations, wrapSecret: wrap, restoreMarker: marker,
            deviceLabel: label, deviceKind: .desktop, issuers: [TestIssuer.config], network: KernelNetworking.loopback)
    }

    func open(listener: KernelListener? = nil) throws -> KernelService {
        try KernelService(config: config, signer: signer, listener: listener)
    }
}

func until(_ what: String, timeout: TimeInterval = 30, _ condition: () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("timed out waiting for \(what)")
}
