// Test doubles for the kernel wrapper: a software host signer, polling and configuration helpers.
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
            deviceLabel: label, deviceKind: .desktop, network: KernelNetworking.loopback)
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
