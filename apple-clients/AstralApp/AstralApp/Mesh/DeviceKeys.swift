// Holds this device's P-256 identity and presence keys, in the Secure Enclave when the hardware allows it.
// MeshHostSigner signs through it, and the restore marker tells the app a backup restore left it without its old keys.

import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated enum DeviceKeysError: Error, Equatable {
    case corruptKey
    case unusable
}

nonisolated final class DeviceKeys: @unchecked Sendable {
    private enum Account {
        static let identity = "identity-key"
        static let presence = "presence-key"
        static let marker = "install-marker"
    }

    private enum Tag: UInt8 {
        case secureEnclave = 1
        case software = 2
    }

    private let store: MeshSecretStore
    private let defaults: UserDefaults
    private let installKey: String
    private let restoreKey: String
    private let lock = NSLock()
    private var identityHardware = false
    private var presenceHardware = false
    private var restored = false

    init(
        service: String = MeshKeychainStore.defaultService,
        store: MeshSecretStore? = nil,
        defaults: UserDefaults = .standard,
        preferHardware: Bool = SecureEnclave.isAvailable
    ) throws {
        self.store = store ?? MeshKeychainStore(service: service)
        self.defaults = defaults
        installKey = "\(service).install-id"
        restoreKey = "\(service).restore-pending"
        try prepare(preferHardware: preferHardware)
    }

    var hardwareBacked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return identityHardware && presenceHardware
    }

    var wasRestored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return restored
    }

    func acknowledgeRestore() {
        lock.lock()
        defer { lock.unlock() }
        restored = false
        defaults.removeObject(forKey: restoreKey)
    }

    func identityPublicKey() throws -> Data {
        try publicKey(account: Account.identity, context: nil)
    }

    func presencePublicKey() throws -> Data {
        try publicKey(account: Account.presence, context: nil)
    }

    func identitySign(_ message: Data) throws -> Data {
        try sign(message, account: Account.identity, context: nil)
    }

    func presenceSign(_ message: Data, authentication: LAContext?) throws -> Data {
        try sign(message, account: Account.presence, context: authentication)
    }

    private func prepare(preferHardware: Bool) throws {
        let kept = try store.load(Account.marker).flatMap { String(data: $0, encoding: .utf8) }
        let recorded = defaults.string(forKey: installKey)
        var fresh = false
        if let recorded, kept != recorded {
            try store.remove(Account.identity)
            try store.remove(Account.presence)
            try store.remove(Account.marker)
            defaults.set(true, forKey: restoreKey)
            fresh = true
        }
        let installId: String
        if !fresh, let kept {
            installId = kept
        } else {
            installId = UUID().uuidString
            try store.save(Data(installId.utf8), account: Account.marker)
        }
        defaults.set(installId, forKey: installKey)
        restored = defaults.bool(forKey: restoreKey)
        identityHardware = try ensureKey(Account.identity, hardware: preferHardware, presence: false)
        presenceHardware = try ensureKey(Account.presence, hardware: preferHardware, presence: true)
    }

    private func ensureKey(_ account: String, hardware: Bool, presence: Bool) throws -> Bool {
        if let blob = try store.load(account) {
            guard let first = blob.first, let tag = Tag(rawValue: first) else { throw DeviceKeysError.corruptKey }
            return tag == .secureEnclave
        }
        if hardware, let rep = try? Self.makeSecureEnclaveKey(presence: presence) {
            try store.save(Data([Tag.secureEnclave.rawValue]) + rep, account: account)
            return true
        }
        let key = P256.Signing.PrivateKey()
        try store.save(Data([Tag.software.rawValue]) + key.rawRepresentation, account: account)
        return false
    }

    private static func makeSecureEnclaveKey(presence: Bool) throws -> Data {
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = presence ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage]
        let accessible =
            presence ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard let control = SecAccessControlCreateWithFlags(nil, accessible, flags, &error) else {
            throw error?.takeRetainedValue() ?? DeviceKeysError.unusable
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: control).dataRepresentation
    }

    private func blob(_ account: String) throws -> (Tag, Data) {
        guard let blob = try store.load(account), let first = blob.first, let tag = Tag(rawValue: first) else {
            throw DeviceKeysError.corruptKey
        }
        return (tag, blob.dropFirst())
    }

    private func publicKey(account: String, context: LAContext?) throws -> Data {
        let (tag, rep) = try blob(account)
        switch tag {
        case .secureEnclave:
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: rep, authenticationContext: context)
                .publicKey.x963Representation
        case .software:
            return try P256.Signing.PrivateKey(rawRepresentation: rep).publicKey.x963Representation
        }
    }

    private func sign(_ message: Data, account: String, context: LAContext?) throws -> Data {
        let (tag, rep) = try blob(account)
        switch tag {
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: rep, authenticationContext: context)
            return try key.signature(for: message).rawRepresentation
        case .software:
            return try P256.Signing.PrivateKey(rawRepresentation: rep).signature(for: message).rawRepresentation
        }
    }
}
