// Verifies native mesh custody, challenge signatures, DPoP member acceptance, and refusal fences.
// Exercises MeshEnrollmentCustody with real CryptoKit keys and an isolated storage/HTTP boundary.

@testable import AstralCore
import CryptoKit
import XCTest

@MainActor final class MeshEnrollmentTests: XCTestCase {
    final class Storage: MeshKeyStorage, @unchecked Sendable {
        var values: [String: Data] = [:]
        var fail = false
        func load(_ key: String) throws -> Data? { values[key] }
        func save(_ value: Data, key: String) throws {
            if fail { throw MeshEnrollmentError.storage }
            values[key] = value
        }
        func remove(_ key: String) throws { values.removeValue(forKey: key) }
        func retainOnly(_ key: String?) throws {
            if fail { throw MeshEnrollmentError.storage }
            values = values.filter { $0.key == key }
        }
    }

    let account = ConversationAccount(issuer: "https://iam.invalid/realms/Astral", subject: "owner")!
    let memberID = String(repeating: "b", count: 32)

    func custody(_ storage: any MeshKeyStorage) throws -> MeshEnrollmentCustody {
        MeshEnrollmentCustody(
            scope: try MeshEnrollmentScope(server: URL(string: "https://app.invalid")!, account: account),
            storage: storage)
    }

    func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func decoded(_ value: String) -> Data {
        Data(
            base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - value.count % 4) % 4))!
    }

    func link(owner: String = "owner", challenge: Data = Data(repeating: 3, count: 32)) throws -> String {
        let body: JSONValue = .object([
            "v": .number(1), "o": .string(owner), "i": .string(String(repeating: "a", count: 32)),
            "t": .string(encoded(Data(repeating: 4, count: 32))), "c": .string(encoded(challenge)),
        ])
        return "https://app.invalid/enroll#" + encoded(try body.encoded())
    }

    func member(_ key: JSONValue, owner: String = "owner") -> JSONValue {
        .object([
            "owner_id": .string(owner), "member_id": .string(memberID), "device_key": key, "status": .string("active"),
        ])
    }

    func testIdentityPersistsAcrossControllerRestartAndPurgesOtherScopes() throws {
        let storage = Storage()
        let original = try custody(storage).publicIdentity(current: { true })
        XCTAssertEqual(try custody(storage).publicIdentity(current: { true }), original)
        XCTAssertEqual(storage.values.count, 1)
        let other = MeshEnrollmentCustody(
            scope: try MeshEnrollmentScope(server: URL(string: "https://other.invalid")!, account: account),
            storage: storage)
        XCTAssertNotEqual(try other.publicIdentity(current: { true }), original)
        XCTAssertEqual(storage.values.count, 1)
        try other.retire()
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testHTTPSCanonicalOriginAndPublicOnlyIdentity() throws {
        for raw in [
            "http://app.invalid", "https://u:p@app.invalid", "https://app.invalid/path", "https://app.invalid?x=1",
            "https://app.invalid#x",
        ] {
            XCTAssertThrowsError(try MeshEnrollmentScope(server: URL(string: raw)!, account: account))
        }
        let storage = Storage()
        let key = try custody(storage).publicIdentity(current: { true })
        try MeshEnrollmentCustody.validatePublicIdentity(key)
        for change in ["d", "alg", "private_key"] {
            var fields = key.objectValue!
            fields[change] = .string("secret")
            XCTAssertThrowsError(try MeshEnrollmentCustody.validatePublicIdentity(.object(fields)))
        }
        XCTAssertThrowsError(
            try MeshEnrollmentCustody.validatePublicIdentity(
                .object(["kty": .string("OKP"), "crv": .string("Ed25519"), "x": .string("AQ")])))
        storage.fail = true
        XCTAssertThrowsError(try custody(storage).publicIdentity(current: { true }))
        XCTAssertThrowsError(try custody(Storage()).publicIdentity(current: { false }))
    }

    func testRealChallengeAndDPoPProofPrecedeSafeMemberPersistence() async throws {
        let storage = Storage()
        let client = try custody(storage)
        let identity = try client.publicIdentity(current: { true })
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: decoded(identity["x"]!.stringValue!))
        let expected = member(identity)
        var calls = 0
        let id = try await client.redeem(
            link: link(), current: { true },
            transport: { request in
                calls += 1
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                switch request.url!.path {
                case "/api/mesh/enrollment/redeem":
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    let body = try JSONValue.parse(request.httpBody!)
                    XCTAssertEqual(Set(body.objectValue!.keys), ["payload", "signature"])
                    XCTAssertTrue(
                        publicKey.isValidSignature(
                            self.decoded(body["signature"]!.stringValue!), for: Data(repeating: 3, count: 32)))
                    return .object([
                        "access_token": .string("test-dpop-session"), "token_type": .string("DPoP"),
                        "expires_in": .number(300), "member": expected,
                    ])
                case "/api/mesh/nonce":
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    return .object(["nonce": .string("challenge.random"), "expires_in": .number(30)])
                case "/api/mesh/me":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DPoP test-dpop-session")
                    let parts = request.value(forHTTPHeaderField: "DPoP")!.split(separator: ".").map(String.init)
                    let claims = try JSONValue.parse(self.decoded(parts[1]))
                    XCTAssertEqual(claims["htu"], .string("https://app.invalid/api/mesh/me"))
                    XCTAssertEqual(claims["htm"], .string("GET"))
                    XCTAssertEqual(claims["nonce"], .string("challenge.random"))
                    XCTAssertTrue(
                        publicKey.isValidSignature(self.decoded(parts[2]), for: Data((parts[0] + "." + parts[1]).utf8)))
                    XCTAssertFalse(
                        String(decoding: storage.values.values.first!, as: UTF8.self).contains(self.memberID))
                    return .object(["member": expected])
                default:
                    XCTFail("unexpected endpoint")
                    throw MeshEnrollmentError.invalid
                }
            })
        XCTAssertEqual(id, memberID)
        XCTAssertEqual(calls, 3)
        let retained = String(decoding: storage.values.values.first!, as: UTF8.self)
        XCTAssertTrue(retained.contains(memberID))
        XCTAssertFalse(retained.contains("test-dpop-session"))
    }

    func testMissingKeyForeignLinkAndMalformedChallengeNeverCallNetwork() async throws {
        let storage = Storage()
        let client = try custody(storage)
        var calls = 0
        let transport: (URLRequest) async throws -> JSONValue = { _ in
            calls += 1
            throw MeshEnrollmentError.unavailable
        }
        do {
            _ = try await client.redeem(link: link(), current: { true }, transport: transport)
            XCTFail()
        } catch {}
        XCTAssertTrue(storage.values.isEmpty)
        _ = try client.publicIdentity(current: { true })
        let good = try link()
        for bad in [
            good.replacingOccurrences(of: "app.invalid", with: "foreign.invalid"),
            good.replacingOccurrences(of: "/enroll#", with: "/enroll?x=1#"),
            good.replacingOccurrences(of: "/enroll#", with: "/%65nroll#"), try link(owner: "other"),
            try link(challenge: Data(repeating: 3, count: 31)), good + "=", good + "%41",
        ] {
            do {
                _ = try await client.redeem(link: bad, current: { true }, transport: transport)
                XCTFail()
            } catch {}
        }
        XCTAssertEqual(calls, 0)
    }

    func testForeignResponseRetiredContextFailureAndReplayDoNotPersistSuccess() async throws {
        for failure in ["owner", "key", "token", "state", "expired", "me", "retired", "network", "storage"] {
            let storage = Storage()
            let client = try custody(storage)
            let key = try client.publicIdentity(current: { true })
            var current = true
            var expected = member(key).objectValue!
            if failure == "owner" { expected["owner_id"] = .string("other") }
            if failure == "key" { expected["device_key"] = .object([:]) }
            if failure == "state" { expected["status"] = .string("revoked") }
            do {
                _ = try await client.redeem(
                    link: link(), current: { current },
                    transport: { request in
                        if failure == "network" { throw MeshEnrollmentError.unavailable }
                        if request.url!.path.hasSuffix("redeem") {
                            if failure == "retired" { current = false }
                            return .object([
                                "access_token": .string("session"),
                                "token_type": .string(failure == "token" ? "Bearer" : "DPoP"),
                                "expires_in": .number(failure == "expired" ? 0 : 300), "member": .object(expected),
                            ])
                        }
                        if request.url!.path.hasSuffix("nonce") {
                            return .object(["nonce": .string("challenge.random")])
                        }
                        if failure == "storage" { storage.fail = true }
                        return .object([
                            "member": failure == "me" ? self.member(key, owner: "foreign") : .object(expected)
                        ])
                    })
                XCTFail("accepted \(failure)")
            } catch {}
            XCTAssertFalse(String(decoding: storage.values.values.first!, as: UTF8.self).contains(memberID))
            do {
                _ = try await client.redeem(
                    link: link(), current: { true },
                    transport: { _ in
                        throw MeshEnrollmentError.unavailable
                    })
                XCTFail("server denial must remain denial")
            } catch {}
        }
    }
    func testProtectedKeychainStorageSurvivesRestartAndPurgesOnlyItsNamespace() throws {
        let service = "com.personalailabs.astraldeep.mesh.tests." + UUID().uuidString
        let storage = KeychainMeshKeyStorage(service: service)
        defer { try? storage.retainOnly(nil) }
        let first = try custody(storage)
        let identity = try first.publicIdentity(current: { true })
        let reloaded = try custody(KeychainMeshKeyStorage(service: service))
        XCTAssertEqual(try reloaded.publicIdentity(current: { true }), identity)
        try storage.save(Data("unrelated".utf8), key: "other")
        try storage.retainOnly(first.scope.storageKey)
        XCTAssertNil(try storage.load("other"))
        XCTAssertNotNil(try storage.load(first.scope.storageKey))
        try first.retire()
        XCTAssertNil(try storage.load(first.scope.storageKey))
        let memory = InMemoryMeshKeyStorage()
        try memory.save(Data([1]), key: "one")
        try memory.save(Data([2]), key: "two")
        try memory.retainOnly("one")
        XCTAssertEqual(try memory.load("one"), Data([1]))
        XCTAssertNil(try memory.load("two"))
        try memory.remove("one")
        XCTAssertNil(try memory.load("one"))
    }

}
