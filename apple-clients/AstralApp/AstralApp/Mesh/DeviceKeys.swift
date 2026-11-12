// Holds this device's P-256 identity/presence keys and device-only Ed25519 operations and X25519 wrapping secrets.
// MeshHostSigner uses P-256 keys, while trusted host code can read local secrets and the restore-aware install marker.

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
        static let operations = "operations-key"
        static let wrap = "wrap-key"
        static let marker = "install-marker"
        static let custody = "local-keys-state"
        static let keys = [identity, presence, operations, wrap]
    }

    private enum Tag: UInt8 {
        case secureEnclave = 1
        case software = 2
    }

    private enum CustodyState: UInt8 {
        case pending = 1
        case ready = 2
    }

    private static let initializationLock = NSLock()

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
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
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

    func operationsSecret() throws -> Data {
        _ = try installMarker()
        return try curveSecret(Account.operations)
    }

    func operationsPublicKey() throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: operationsSecret()).publicKey.rawRepresentation
    }

    func wrapSecret() throws -> Data {
        _ = try installMarker()
        return try curveSecret(Account.wrap)
    }

    func wrapPublicKey() throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: wrapSecret()).publicKey.rawRepresentation
    }

    func installMarker() throws -> Data {
        guard let marker = try store.load(Account.marker) else { throw DeviceKeysError.corruptKey }
        _ = try Self.markerId(marker)
        guard try custodyState(marker: marker) == .ready else { throw DeviceKeysError.corruptKey }
        return marker
    }

    private func prepare(preferHardware: Bool) throws {
        let kept = try store.load(Account.marker).map(Self.markerId)
        let recorded = defaults.string(forKey: installKey)
        var fresh = false
        if let recorded, kept != recorded {
            defaults.set(true, forKey: restoreKey)
            for account in Account.keys + [Account.custody, Account.marker] { try store.remove(account) }
            fresh = true
        }
        let installId: String
        if !fresh, let kept {
            installId = kept
        } else {
            installId = try prepareNewInstall()
            try store.save(Data(installId.utf8), account: Account.marker)
        }
        defaults.set(installId, forKey: installKey)
        restored = defaults.bool(forKey: restoreKey)
        let marker = Data(installId.utf8)
        let state = try custodyState(marker: marker)
        if state == nil {
            guard try store.load(Account.operations) == nil, try store.load(Account.wrap) == nil else {
                throw DeviceKeysError.corruptKey
            }
            guard try store.load(Account.identity) != nil, try store.load(Account.presence) != nil else {
                throw DeviceKeysError.corruptKey
            }
            try store.save(Data([CustodyState.pending.rawValue]) + marker, account: Account.custody)
        }
        if state == .ready {
            for account in Account.keys {
                guard try store.load(account) != nil else { throw DeviceKeysError.corruptKey }
            }
        }
        identityHardware = try ensureKey(Account.identity, hardware: preferHardware, presence: false)
        presenceHardware = try ensureKey(Account.presence, hardware: preferHardware, presence: true)
        try ensureCurveKey(Account.operations)
        try ensureCurveKey(Account.wrap)
        if state != .ready {
            try store.save(Data([CustodyState.ready.rawValue]) + marker, account: Account.custody)
        }
    }

    private func prepareNewInstall() throws -> String {
        for account in Account.keys {
            guard try store.load(account) == nil else { throw DeviceKeysError.corruptKey }
        }
        if let pending = try store.load(Account.custody) {
            guard pending.first == CustodyState.pending.rawValue else { throw DeviceKeysError.corruptKey }
            return try Self.markerId(Data(pending.dropFirst()))
        }
        let installId = UUID().uuidString
        try store.save(Data([CustodyState.pending.rawValue]) + Data(installId.utf8), account: Account.custody)
        return installId
    }

    private static func markerId(_ marker: Data) throws -> String {
        guard let value = String(data: marker, encoding: .utf8), UUID(uuidString: value) != nil else {
            throw DeviceKeysError.corruptKey
        }
        return value
    }

    private func custodyState(marker: Data) throws -> CustodyState? {
        guard let value = try store.load(Account.custody) else { return nil }
        guard let first = value.first, let state = CustodyState(rawValue: first), value.dropFirst() == marker else {
            throw DeviceKeysError.corruptKey
        }
        return state
    }

    private func curveSecret(_ account: String) throws -> Data {
        guard let secret = try store.load(account), secret.count == 32 else { throw DeviceKeysError.corruptKey }
        return secret
    }

    private func ensureCurveKey(_ account: String) throws {
        if try store.load(account) != nil {
            _ = try curveSecret(account)
            return
        }
        let secret =
            account == Account.operations
            ? Curve25519.Signing.PrivateKey().rawRepresentation
            : Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try store.save(secret, account: account)
    }

    private func ensureKey(_ account: String, hardware: Bool, presence: Bool) throws -> Bool {
        if let blob = try store.load(account) {
            guard let first = blob.first, let tag = Tag(rawValue: first) else { throw DeviceKeysError.corruptKey }
            do { _ = try publicKey(account: account, context: nil) } catch { throw DeviceKeysError.corruptKey }
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
