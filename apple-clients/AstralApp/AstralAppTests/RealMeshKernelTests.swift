// Drives two real kernels on loopback through RealMeshKernel with real device keys, the real host signer and a recording consent presenter.
// It covers mesh creation, pairing with a roster consent, chat sync both ways, denial, refused actions and the issuer key cache.

@testable import AstralDeep
import AstralKernel
import CryptoKit
import XCTest

nonisolated final class RecordingPresenter: ConsentPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AstralDeep.ConsentPrompt] = []
    var approve = true
    var prompts: [AstralDeep.ConsentPrompt] { lock.withLock { seen } }

    func requestConsent(_ prompt: AstralDeep.ConsentPrompt) async -> ConsentDecision {
        lock.withLock { seen.append(prompt) }
        return approve ? .approved(ConsentApproval(context: nil)) : .denied(.denied)
    }
}

nonisolated final class ChangeLog: MeshKernelListening, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeshKernelChange] = []
    var changes: [MeshKernelChange] { lock.withLock { values } }
    func onChange(_ change: MeshKernelChange) { lock.withLock { values.append(change) } }
}

nonisolated enum TestTokenIssuer {
    static let issuer = "https://auth.example.test/realms/astral"
    static let client = "astral-desktop"
    private static let key = P256.Signing.PrivateKey()

    static var config: IssuerConfig {
        let point = key.publicKey.x963Representation
        let jwks: [String: Any] = [
            "keys": [["kid": "k1", "kty": "EC", "crv": "P-256", "x": b64(point[1..<33]), "y": b64(point[33..<65])]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: jwks, options: [.sortedKeys])
        return IssuerConfig(issuer: issuer, clientId: client, jwksJson: String(decoding: data, as: UTF8.self))
    }

    static func token(nonce: String) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = b64(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "k1", "typ": "JWT"]))
        let claims: [String: Any] = [
            "iss": issuer, "aud": client, "sub": "user-1", "iat": now, "exp": now + 300, "nonce": nonce,
        ]
        let input = header + "." + b64(try! JSONSerialization.data(withJSONObject: claims))
        return input + "." + b64(try! key.signature(for: Data(input.utf8)).rawRepresentation)
    }

    private static func b64(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

final class RealMeshKernelTests: XCTestCase {
    private struct Device {
        let kernel: RealMeshKernel
        let presenter: RecordingPresenter
        let changes: ChangeLog
    }

    private func open(_ label: String, kind: MeshDeviceKind = .desktop, issuers: [IssuerConfig]? = nil) async throws
        -> Device
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("real-mesh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "real.mesh." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(
            store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
        let presenter = RecordingPresenter()
        let changes = ChangeLog()
        let config = MeshKernelConfig(
            dataDirectory: directory, deviceLabel: label, deviceKind: kind, operationsSecret: try keys.operationsSecret(),
            wrapSecret: try keys.wrapSecret(), installMarker: try keys.installMarker(), restoredInstall: false)
        let kernel = try await RealMeshKernel.open(
            config: config, issuers: issuers ?? [TestTokenIssuer.config], network: KernelNetworking.loopback,
            signer: MeshHostSigner(keys: keys, presenter: presenter), model: FakeOnDeviceModel(),
            tools: DeviceLocalTools(), listener: changes)
        return Device(kernel: kernel, presenter: presenter, changes: changes)
    }

    private func createMesh(_ device: Device) async throws -> MeshRecoveryKit {
        let kernel = device.kernel
        return try await Task.detached {
            let request = try kernel.beginMeshCreation()
            return try kernel.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: request.nonce))
        }.value
    }

    private func until(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testFreshKernelReportsNoMeshAndCreationYieldsRecoveryWordsAndAStatus() async throws {
        let mac = try await open("Test Mac")
        let fresh = try await mac.kernel.meshStatus()
        XCTAssertFalse(fresh.hasMesh)
        XCTAssertNil(fresh.meshId)
        XCTAssertFalse(mac.kernel.version().isEmpty)
        let kit = try await createMesh(mac)
        XCTAssertEqual(kit.words.count, 24)
        let status = try await mac.kernel.meshStatus()
        XCTAssertTrue(status.hasMesh)
        XCTAssertTrue(status.attested)
        XCTAssertFalse(status.stopped)
        let members = try await mac.kernel.roster()
        XCTAssertEqual(members.map(\.label), ["Test Mac"])
        XCTAssertTrue(members[0].isThisDevice)
        XCTAssertEqual(members[0].kind, .desktop)
        XCTAssertTrue(mac.changes.changes.contains(.rosterChanged))
        await mac.kernel.stopNetwork()
    }

    func testCreationWithoutAnIssuerOrWithTheWrongNonceIsRefusedInPlainWords() async throws {
        let none = try await open("No issuer", issuers: [])
        XCTAssertThrowsError(try none.kernel.beginMeshCreation()) { error in
            guard case MeshKernelError.refused(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("sign-in service"))
        }
        let mac = try await open("Mac")
        let kernel = mac.kernel
        let outcome = await Task.detached { () -> Error? in
            do {
                _ = try kernel.beginMeshCreation()
                _ = try kernel.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: "00"))
                return nil
            } catch { return error }
        }.value
        XCTAssertNotNil(outcome)
        let status = try await mac.kernel.meshStatus()
        XCTAssertFalse(status.hasMesh)
    }

    func testPairingAsksForAConsentAndSyncsChatsBothWays() async throws {
        let mac = try await open("Mac")
        let phone = try await open("Phone", kind: .pocket)
        _ = try await createMesh(mac)
        try await mac.kernel.startNetwork()
        let chat = try mac.kernel.createChat(title: "shared")
        let first = try mac.kernel.sendMessage(chatId: chat, text: "from mac", continues: nil)

        let offer = try await phone.kernel.createPairingOffer()
        XCTAssertFalse(offer.shortCode.isEmpty)
        let preview = try mac.kernel.previewPairing(payload: offer.payload)
        XCTAssertEqual(preview.deviceLabel, "Phone")
        XCTAssertEqual(preview.deviceKind, .pocket)
        XCTAssertEqual(preview.comparisonCode, offer.shortCode)
        try await mac.kernel.approvePairing(payload: offer.payload)

        let prompt = try XCTUnwrap(mac.presenter.prompts.last)
        XCTAssertEqual(prompt.effect, "roster.add")
        XCTAssertTrue(prompt.requiresBiometry)
        XCTAssertTrue(prompt.target.contains("Phone"))

        try await until("the phone to join") { try await phone.kernel.meshStatus().hasMesh }
        let roster = try await mac.kernel.roster()
        XCTAssertEqual(Set(roster.map(\.label)), ["Mac", "Phone"])
        try await until("the phone to read the chat") { (try? phone.kernel.chat(chatId: chat))?.messages.count == 1 }
        let second = try phone.kernel.sendMessage(chatId: chat, text: "from phone", continues: nil)
        try await until("the mac to read the phone message") { (try? mac.kernel.chat(chatId: chat))?.messages.count == 2 }
        let macView = try mac.kernel.chat(chatId: chat)
        let phoneView = try await phoneViewWhenCaughtUp(phone, chat: chat, count: 2)
        XCTAssertEqual(Set(macView.messages.map(\.eventId)), Set([first, second]))
        XCTAssertEqual(Set(macView.messages.map(\.eventId)), Set(phoneView.messages.map(\.eventId)))
        XCTAssertEqual(macView.messages.filter { $0.parentId == nil }.count, 1)
        let phoneChat = try phone.kernel.createChat(title: "from phone")
        try await until("the mac to list it") { try mac.kernel.listChats().contains { $0.chatId == phoneChat } }
        let sync = try await mac.kernel.syncState()
        XCTAssertEqual(sync.devices.map(\.label), ["Phone"])
        await mac.kernel.stopNetwork()
        await phone.kernel.stopNetwork()
    }

    func testRecoveryWithTheWordsAndABackupRestoresTheMeshOnANewDevice() async throws {
        let mac = try await open("Mac")
        let kit = try await createMesh(mac)
        let chat = try mac.kernel.createChat(title: "kept")
        _ = try mac.kernel.sendMessage(chatId: chat, text: "remember this", continues: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try mac.kernel.exportBackup(path: file.path)
        let original = try await mac.kernel.meshStatus()
        await mac.kernel.stopNetwork()

        let fresh = try await open("New Mac")
        let wrong = Array(kit.words.reversed()).joined(separator: " ")
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: wrong, backupPath: file.path)) { error in
            guard case MeshKernelError.refused(let text) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(kit.words[0] + " " + kit.words[1]))
        }
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: "abandon ability", backupPath: file.path)) {
            XCTAssertEqual($0 as? MeshKernelError, .refused("Enter all 24 recovery words."))
        }
        let unknown = (Array(kit.words.dropLast()) + ["zzzzzz"]).joined(separator: " ")
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: unknown, backupPath: file.path)) {
            XCTAssertEqual(
                $0 as? MeshKernelError,
                .refused("One of the words is not on the recovery word list. Check the spelling."))
        }
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: kit.words.joined(separator: " "), backupPath: nil)) {
            XCTAssertEqual(
                $0 as? MeshKernelError,
                .refused("Choose a backup file. This device holds no copy of your mesh."))
        }
        let notABackup = FileManager.default.temporaryDirectory.appendingPathComponent("junk-" + UUID().uuidString)
        try Data("not a backup".utf8).write(to: notABackup)
        addTeardownBlock { try? FileManager.default.removeItem(at: notABackup) }
        XCTAssertThrowsError(
            try fresh.kernel.recoverWithWords(words: kit.words.joined(separator: " "), backupPath: notABackup.path))
        let before = try await fresh.kernel.meshStatus()
        XCTAssertFalse(before.hasMesh)

        let result = try fresh.kernel.recoverWithWords(words: kit.words.joined(separator: " "), backupPath: file.path)
        XCTAssertEqual(result.meshId, original.meshId)
        XCTAssertNotEqual(result.deviceId, original.deviceId)
        XCTAssertGreaterThan(result.eventsImported, 0)
        let status = try await fresh.kernel.meshStatus()
        XCTAssertTrue(status.hasMesh)
        XCTAssertEqual(status.meshId, original.meshId)
        let roster = try await fresh.kernel.roster()
        XCTAssertEqual(Set(roster.map(\.label)), ["Mac", "New Mac"])
        XCTAssertEqual(roster.first(where: \.isThisDevice)?.label, "New Mac")
        XCTAssertEqual(try fresh.kernel.chat(chatId: chat).messages.map(\.text), ["remember this"])
        XCTAssertThrowsError(
            try fresh.kernel.recoverWithWords(words: kit.words.joined(separator: " "), backupPath: file.path)
        ) { XCTAssertEqual($0 as? MeshKernelError, .refused("This device already belongs to a mesh.")) }
        await fresh.kernel.stopNetwork()
    }

    private func phoneViewWhenCaughtUp(_ device: Device, chat: String, count: Int) async throws -> MeshChatView {
        try await until("the phone view") { (try? device.kernel.chat(chatId: chat))?.messages.count == count }
        return try device.kernel.chat(chatId: chat)
    }

    func testDeniedConsentLeavesTheRosterAloneAndMapsToDenial() async throws {
        let mac = try await open("Mac")
        let phone = try await open("Phone", kind: .pocket)
        _ = try await createMesh(mac)
        let offer = try await phone.kernel.createPairingOffer()
        mac.presenter.approve = false
        do {
            try await mac.kernel.approvePairing(payload: offer.payload)
            XCTFail("approval should be refused")
        } catch {
            XCTAssertEqual(error as? MeshKernelError, .consentDenied)
        }
        let roster = try await mac.kernel.roster()
        XCTAssertEqual(roster.count, 1)
        XCTAssertThrowsError(try mac.kernel.previewPairing(payload: "not a payload"))
        await mac.kernel.stopNetwork()
        await phone.kernel.stopNetwork()
    }

    func testChatTreeBranchesAndQueuedMessagesFollowTheKernelsTurns() async throws {
        let mac = try await open("Mac")
        _ = try await createMesh(mac)
        let chat = try mac.kernel.createChat(title: "tree")
        let first = try mac.kernel.sendMessage(chatId: chat, text: "one", continues: nil)
        let second = try mac.kernel.sendMessage(chatId: chat, text: "two", continues: first)
        let view = try mac.kernel.chat(chatId: chat)
        XCTAssertEqual(view.messages.map(\.text), ["one", "two"])
        XCTAssertEqual(view.messages.map(\.delivery), [.queued, .queued])
        XCTAssertEqual(view.messages[0].parentId, nil)
        XCTAssertEqual(view.messages[1].parentId, first)
        XCTAssertEqual(second, view.messages[1].eventId)
        XCTAssertThrowsError(try mac.kernel.sendMessage(chatId: chat, text: "  ", continues: nil))
        XCTAssertThrowsError(try mac.kernel.sendMessage(chatId: chat, text: "x", continues: "sha256:unknown"))
        XCTAssertThrowsError(try mac.kernel.fork(chatId: chat, eventId: "sha256:unknown"))
        let summaries = try mac.kernel.listChats()
        XCTAssertEqual(summaries.first?.queuedCount, 2)
        XCTAssertEqual(summaries.first?.preview, "two")
        await mac.kernel.stopNetwork()
    }

    func testRunsLearningConsentsAndActionsAreHonestWhenNothingIsRunning() async throws {
        let mac = try await open("Mac")
        _ = try await createMesh(mac)
        let runs = try await mac.kernel.runs()
        XCTAssertTrue(runs.isEmpty)
        let proposals = try await mac.kernel.learningProposals()
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(try mac.kernel.pendingConsents().isEmpty)
        XCTAssertTrue(try mac.kernel.modelProviders().isEmpty)
        let allowance = try mac.kernel.allowance()
        XCTAssertNotNil(allowance.modelTokensLimit)
        XCTAssertThrowsError(try mac.kernel.act(surfaceId: "s", componentId: "c", action: "a")) { error in
            guard case MeshKernelError.unavailable = error else { return XCTFail("\(error)") }
        }
        do {
            try await mac.kernel.takeOverRun(runId: "missing")
            XCTFail("unknown run should be refused")
        } catch {
            XCTAssertTrue(error is MeshKernelError)
        }
        await mac.kernel.stopNetwork()
    }

    func testProviderSettingsAreSealedAndListedWithoutSecrets() async throws {
        let mac = try await open("Mac")
        _ = try await createMesh(mac)
        try mac.kernel.setModelProvider(
            MeshModelProviderConfig(baseURL: "https://api.example.test/v1", model: "model-a", apiKey: "sk-test-key"))
        let providers = try mac.kernel.modelProviders()
        XCTAssertEqual(providers.map(\.model), ["model-a"])
        XCTAssertEqual(providers.first?.baseURL, "https://api.example.test/v1")
        XCTAssertTrue(providers.first?.isDefault ?? false)
        XCTAssertFalse(String(describing: providers).contains("sk-test-key"))
        XCTAssertThrowsError(
            try mac.kernel.setModelProvider(MeshModelProviderConfig(baseURL: "not a url", model: "m", apiKey: "k")))
        await mac.kernel.stopNetwork()
    }

    func testIssuerKeysAreFetchedCachedAndUsedWhenTheNetworkFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("issuer-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keys = Data(TestTokenIssuer.config.jwksJson.utf8)
        let online = MeshIssuerSource(
            issuer: "https://id.example.test/realms/a", clientId: "astral-desktop",
            keysURL: URL(string: "https://id.example.test/realms/a/protocol/openid-connect/certs")!
        ) { _ in keys }
        let first = await online.issuers(cacheIn: directory)
        XCTAssertEqual(first.map(\.issuer), ["https://id.example.test/realms/a"])
        let offline = MeshIssuerSource(
            issuer: online.issuer, clientId: online.clientId, keysURL: online.keysURL
        ) { _ in throw URLError(.notConnectedToInternet) }
        let cached = await offline.issuers(cacheIn: directory)
        XCTAssertEqual(cached.first?.jwksJson, first.first?.jwksJson)
        let garbage = MeshIssuerSource(issuer: online.issuer, clientId: online.clientId, keysURL: online.keysURL) { _ in
            Data("{}".utf8)
        }
        let kept = await garbage.issuers(cacheIn: directory)
        XCTAssertEqual(kept.first?.jwksJson, first.first?.jwksJson)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("issuer-" + UUID().uuidString)
        let none = await offline.issuers(cacheIn: empty)
        XCTAssertTrue(none.isEmpty)
    }
}
