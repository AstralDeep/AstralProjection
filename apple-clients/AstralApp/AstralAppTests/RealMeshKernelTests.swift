// Drives two real kernels on loopback through RealMeshKernel with real device keys, the real host signer and a recording consent presenter.
// It covers mesh creation, pairing with a roster consent, chat sync both ways, denial, refused actions and the issuer key cache.

import AstralCore
import AstralKernel
import CryptoKit
import XCTest

@testable import AstralDeep

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

nonisolated final class MemoryHostKeystore: HostKeystore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failure: HostKeystoreError?

    func get(account: String) throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return items[account]
        }
    }

    func put(account: String, secret: Data) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[account] = secret
        }
    }

    func remove(account: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[account] = nil
        }
    }
}

final class RealMeshKernelTests: XCTestCase {
    private struct Device {
        let kernel: RealMeshKernel
        let presenter: RecordingPresenter
        let changes: ChangeLog
        let directory: URL
        let keys: DeviceKeys
    }

    private func open(
        _ label: String, kind: MeshDeviceKind = .desktop,
        peerTools: [MeshPeerTool] = [], mailbox: String? = nil, reusing: Device? = nil,
        keystore: any HostKeystore = MemoryHostKeystore()
    ) async throws -> Device {
        let directory: URL
        let keys: DeviceKeys
        if let reusing {
            directory = reusing.directory
            keys = reusing.keys
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("real-mesh-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let suite = "real.mesh." + UUID().uuidString
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
            keys = try DeviceKeys(
                store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
        }
        let presenter = RecordingPresenter()
        let changes = ChangeLog()
        let config = MeshKernelConfig(
            dataDirectory: directory, deviceLabel: label, deviceKind: kind,
            operationsSecret: try keys.operationsSecret(),
            wrapSecret: try keys.wrapSecret(), installMarker: try keys.installMarker(), restoredInstall: false,
            mailbox: mailbox)
        var network = KernelNetworking.loopback
        network.mailbox = mailbox
        let kernel = try await RealMeshKernel.open(
            config: config, network: network,
            signer: MeshHostSigner(keys: keys, presenter: presenter), model: FakeOnDeviceModel(),
            tools: DeviceLocalTools(), listener: changes, peerTools: peerTools, keystore: keystore)
        return Device(kernel: kernel, presenter: presenter, changes: changes, directory: directory, keys: keys)
    }

    private func createMesh(_ device: Device) async throws -> MeshRecoveryKit {
        let kernel = device.kernel
        return try await Task.detached {
            let kit = try kernel.createMesh()
            try kernel.confirmMeshRecovery()
            return kit
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

    func testConnectionCallsReachTheKernelAndKeepTheirCodes() async throws {
        let mac = try await open("Test Mac")
        _ = try await createMesh(mac)
        XCTAssertTrue(try mac.kernel.connections().isEmpty)
        do {
            let endpoint = "http://public.example/mcp"
            _ = try await mac.kernel.proposeConnection(endpoint: endpoint, name: "Docs", local: false)
            XCTFail("a public endpoint without HTTPS must be refused")
        } catch { XCTAssertEqual((error as? MeshKernelError)?.code, "connection.egress_refused") }
        XCTAssertThrowsError(try mac.kernel.removeConnection(id: "not-an-id")) {
            XCTAssertEqual(($0 as? MeshKernelError)?.code, "connection.malformed")
        }
        do {
            _ = try await mac.kernel.beginConnectionSignIn(id: String(repeating: "0", count: 32), redirect: .appLink)
            XCTFail("an unknown connection cannot sign in")
        } catch { XCTAssertEqual((error as? MeshKernelError)?.code, "connection.unknown") }
        await mac.kernel.stopNetwork()
    }

    func testAClosedKernelRefusesEveryCallInsteadOfAnswering() async throws {
        let mac = try await open("Test Mac")
        _ = try await createMesh(mac)
        await mac.kernel.stopNetwork()
        await mac.kernel.close()
        do {
            _ = try await mac.kernel.meshStatus()
            XCTFail("a closed kernel must refuse")
        } catch {}
        XCTAssertThrowsError(try mac.kernel.connections())
        XCTAssertThrowsError(try mac.kernel.mailboxState())
        XCTAssertThrowsError(try mac.kernel.pendingConsents())
        XCTAssertThrowsError(try mac.kernel.restoreMarker())
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
        XCTAssertFalse(status.recoveryPending)
        XCTAssertFalse(status.stopped)
        let members = try await mac.kernel.roster()
        XCTAssertEqual(members.map(\.label), ["Test Mac"])
        XCTAssertTrue(members[0].isThisDevice)
        XCTAssertEqual(members[0].kind, .desktop)
        XCTAssertTrue(mac.changes.changes.contains(.rosterChanged))
        await mac.kernel.stopNetwork()
    }

    func testCallerTicketCallsRefuseWhatTheKernelRefuses() async throws {
        let mac = try await open("Test Mac")
        let id = "AAECAwQFBgcICQoLDA0ODw"
        XCTAssertThrowsError(try mac.kernel.callerTickets()) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("mesh.not_enrolled"))
        }
        _ = try await createMesh(mac)
        XCTAssertEqual(try mac.kernel.callerTickets(), [])
        let holder = MeshCallerTicketLimits.holderPrefix + "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        XCTAssertThrowsError(
            try mac.kernel.mintCallerTicket(
                nodeId: "sha256:" + String(repeating: "0", count: 64), holderKey: holder, label: "Script",
                toolNames: ["current_datetime"], a2a: false, lifetimeSeconds: 60)
        ) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("caller.wrong_node"))
        }
        XCTAssertThrowsError(try mac.kernel.revokeCallerTicket(id: "short")) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("caller.malformed"))
        }
        try mac.kernel.revokeCallerTicket(id: id)
        try mac.kernel.revokeCallerTicket(id: id)
        XCTAssertEqual(try mac.kernel.callerTickets(), [])
        XCTAssertThrowsError(
            try mac.kernel.verifyCallerRequest(
                MeshCallerRequest(
                    authorization: "forged", proof: nil, method: "POST", target: "/a2a", bodySha256: "d", tool: nil))
        ) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("caller.malformed"))
        }
        await mac.kernel.stopNetwork()
    }

    func testLocalCreationDenialDoesNotCreateMembership() async throws {
        let mac = try await open("Mac")
        mac.presenter.approve = false
        do {
            _ = try await createMesh(mac)
            XCTFail("Denied approval cannot create a mesh")
        } catch {}
        let status = try await mac.kernel.meshStatus()
        XCTAssertFalse(status.hasMesh)
        XCTAssertFalse(status.recoveryPending)
    }

    func testPendingRecoveryReopensAndRequiresApprovalUntilConfirmed() async throws {
        let device = try await open("Mac")
        let kernel = device.kernel
        let kit = try await Task.detached { try kernel.createMesh() }.value
        let pending = try await kernel.meshStatus()
        XCTAssertTrue(pending.recoveryPending)
        await kernel.stopNetwork()
        let reopened = try await open("Mac", reusing: device)
        reopened.presenter.approve = false
        let current = reopened.kernel
        do {
            _ = try await Task.detached { try current.createMesh() }.value
            XCTFail("Recovery reveal requires approval")
        } catch {}
        reopened.presenter.approve = true
        let revealed = try await Task.detached { try current.createMesh() }.value
        XCTAssertEqual(revealed, kit)
        try await Task.detached { try current.confirmMeshRecovery() }.value
        let confirmed = try await current.meshStatus()
        XCTAssertFalse(confirmed.recoveryPending)
        XCTAssertEqual(try current.meshPrincipal().meshId, confirmed.meshId)
        await current.stopNetwork()
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
        try await until("the mac to read the phone message") {
            (try? mac.kernel.chat(chatId: chat))?.messages.count == 2
        }
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
            guard case MeshKernelError.refused(_, let text) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(kit.words[0] + " " + kit.words[1]))
        }
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: "abandon ability", backupPath: file.path)) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("recovery.bad_length"))
        }
        let unknown = (Array(kit.words.dropLast()) + ["zzzzzz"]).joined(separator: " ")
        XCTAssertThrowsError(try fresh.kernel.recoverWithWords(words: unknown, backupPath: file.path)) {
            XCTAssertEqual(
                $0 as? MeshKernelError,
                KernelMapping.refusal("recovery.unknown_word"))
        }
        XCTAssertThrowsError(
            try fresh.kernel.recoverWithWords(words: kit.words.joined(separator: " "), backupPath: nil)
        ) {
            XCTAssertEqual(
                $0 as? MeshKernelError,
                KernelMapping.refusal("recovery.no_roster"))
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
        ) { XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("mesh.already_enrolled")) }
        await fresh.kernel.stopNetwork()
    }

    func testAnAttachmentOnlyMessageSyncsItsFileAndThePeerFetchesTheOriginalBytes() async throws {
        let mac = try await open("Attachment Mac")
        let phone = try await open("Attachment Phone", kind: .pocket)
        _ = try await createMesh(mac)
        try await mac.kernel.startNetwork()
        let chat = try mac.kernel.createChat(title: "Files")
        let offer = try await phone.kernel.createPairingOffer()
        try await mac.kernel.approvePairing(payload: offer.payload)
        try await until("the phone to join") { try await phone.kernel.meshStatus().hasMesh }
        try await until("the phone to read the chat") { (try? phone.kernel.chat(chatId: chat)) != nil }
        let bytes = Data("notes shared with the phone".utf8)
        let attachment = try mac.kernel.addAttachment(chatId: chat, bytes: bytes, mime: "text/plain", name: "notes.txt")
        let sent = try mac.kernel.sendMessage(chatId: chat, text: "", continues: nil, attachments: [attachment.id])
        try await until("the phone to read the attachment-only message") {
            (try? phone.kernel.chat(chatId: chat))?.messages.first?.attachments.count == 1
        }
        let received = try XCTUnwrap(phone.kernel.chat(chatId: chat).messages.first)
        XCTAssertEqual(received.eventId, sent)
        XCTAssertEqual(received.text, "")
        XCTAssertEqual(received.attachments.first?.name, "notes.txt")
        XCTAssertEqual(received.attachments.first?.size, UInt64(bytes.count))
        let fetched = try await phone.kernel.fetchAttachment(handle: attachment.handle)
        XCTAssertEqual(fetched, bytes)
        let elsewhere = try mac.kernel.createChat(title: "Other chat")
        XCTAssertThrowsError(
            try mac.kernel.sendMessage(
                chatId: elsewhere, text: "wrong chat", continues: nil, attachments: [attachment.id]))
        XCTAssertThrowsError(
            try mac.kernel.addAttachment(chatId: chat, bytes: Data(), mime: "text/plain", name: "empty.txt"))
        await mac.kernel.stopNetwork()
        await phone.kernel.stopNetwork()
    }

    func testRequestsAreSentClaimedAndRefusedBetweenTwoPairedKernels() async throws {
        let mac = try await open("Mac")
        let phone = try await open("Phone", kind: .pocket)
        _ = try await createMesh(mac)
        try await mac.kernel.startNetwork()
        let chat = try mac.kernel.createChat(title: "asks")
        let offer = try await phone.kernel.createPairingOffer()
        try await mac.kernel.approvePairing(payload: offer.payload)
        try await until("the phone to join") { try await phone.kernel.meshStatus().hasMesh }
        let roster = try await mac.kernel.roster()
        let macId = try XCTUnwrap(roster.first(where: \.isThisDevice)?.memberId)
        let phoneId = try XCTUnwrap(roster.first { !$0.isThisDevice }?.memberId)
        try await until("the phone to list the chat") { try phone.kernel.listChats().contains { $0.chatId == chat } }

        XCTAssertThrowsError(try mac.kernel.sendRequest(chatId: chat, text: "  ", toMember: phoneId)) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("request.empty"))
        }
        XCTAssertThrowsError(try mac.kernel.sendRequest(chatId: chat, text: "hi", toMember: macId)) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("request.self_addressed"))
        }
        XCTAssertThrowsError(try mac.kernel.sendRequest(chatId: chat, text: "hi", toMember: "sha256:nobody")) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("request.unknown_member"))
        }
        XCTAssertTrue(try mac.kernel.chatRequests(chatId: chat).isEmpty)

        let first = try mac.kernel.sendRequest(chatId: chat, text: "Print the plan", toMember: phoneId)
        try await until("the phone to see the request") {
            try phone.kernel.pendingRequestsForMe().contains { $0.requestId == first }
        }
        let seen = try XCTUnwrap(try phone.kernel.pendingRequestsForMe().first { $0.requestId == first })
        XCTAssertEqual(seen.state, .pending)
        XCTAssertEqual(seen.text, "Print the plan")
        XCTAssertEqual(seen.fromMember, macId)
        XCTAssertEqual(seen.toMember, phoneId)
        XCTAssertEqual(seen.chatId, chat)
        XCTAssertTrue(try mac.kernel.pendingRequestsForMe().isEmpty)
        XCTAssertThrowsError(try mac.kernel.claimRequest(requestId: first)) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("request.not_target"))
        }

        try phone.kernel.claimRequest(requestId: first)
        try phone.kernel.claimRequest(requestId: first)
        try await until("the mac to see the claim") {
            try mac.kernel.chatRequests(chatId: chat).first { $0.requestId == first }?.state == .claimed
        }

        let second = try mac.kernel.sendRequest(chatId: chat, text: "Second", toMember: phoneId)
        try await until("the phone to see the second request") {
            try phone.kernel.pendingRequestsForMe().contains { $0.requestId == second }
        }
        try phone.kernel.refuseRequest(requestId: second, code: MeshRequestRefusal.busy.rawValue)
        try await until("the mac to see the refusal") {
            try mac.kernel.chatRequests(chatId: chat).first { $0.requestId == second }?.state == .refused
        }
        let refused = try XCTUnwrap(try mac.kernel.chatRequests(chatId: chat).first { $0.requestId == second })
        XCTAssertEqual(refused.refusalCode, "request.busy")
        XCTAssertThrowsError(try phone.kernel.refuseRequest(requestId: second, code: "request.busy")) {
            XCTAssertEqual(($0 as? MeshKernelError)?.message, "That request can no longer change.")
            XCTAssertEqual(($0 as? MeshKernelError)?.code?.hasPrefix("request."), true)
        }
        XCTAssertThrowsError(try phone.kernel.refuseRequest(requestId: first, code: "Not A Code")) { _ in }
        XCTAssertTrue(try phone.kernel.pendingRequestsForMe().isEmpty)
        await mac.kernel.stopNetwork()
        await phone.kernel.stopNetwork()
    }

    func testGrantingAToolDrawsTheBiometricConsentAndRevokingNeverDoes() async throws {
        let mac = try await open("Mac")
        _ = try await createMesh(mac)
        let kernel = mac.kernel
        func grant(_ name: String, _ scope: String) async -> Error? {
            await Task.detached { () -> Error? in
                do {
                    try kernel.grantTool(name: name, scope: scope)
                    return nil
                } catch { return error }
            }.value
        }
        let before = mac.presenter.prompts.count
        let granted = await grant("files.read", "mesh_read")
        XCTAssertNil(granted)
        XCTAssertEqual(mac.presenter.prompts.count, before + 1)
        let prompt = try XCTUnwrap(mac.presenter.prompts.last)
        XCTAssertEqual(prompt.actionTitle, "Allow files.read")
        XCTAssertEqual(prompt.effect, "files.read")
        XCTAssertTrue(prompt.target.contains("read your mesh"))
        XCTAssertTrue(prompt.arguments.contains("auth.grant"))
        XCTAssertTrue(prompt.requiresBiometry)

        try kernel.revokeTool(name: "files.read", scope: "mesh_read")
        try kernel.revokeTool(name: "never.granted", scope: "outside_effect")
        XCTAssertEqual(mac.presenter.prompts.count, before + 1)

        mac.presenter.approve = false
        let denied = await grant("mail.send", "outside_effect")
        XCTAssertEqual(denied as? MeshKernelError, .consentDenied)
        mac.presenter.approve = true
        let malformed = await grant("", "mesh_read")
        XCTAssertEqual(malformed as? MeshKernelError, KernelMapping.refusal("grant.malformed"))
        XCTAssertThrowsError(try kernel.revokeTool(name: "files.read", scope: "")) {
            XCTAssertEqual($0 as? MeshKernelError, KernelMapping.refusal("grant.malformed"))
        }
        await kernel.stopNetwork()
    }

    func testAStoppedMeshShowsHaltedAndResumesWithABiometricConsent() async throws {
        let mac = try await open("Mac")
        _ = try await createMesh(mac)
        let marker = try XCTUnwrap(mac.kernel.restoreMarker())
        XCTAssertEqual(marker, try mac.keys.installMarker())
        let kernel = mac.kernel
        let before = mac.presenter.prompts.count
        try await Task.detached { try kernel.raiseStop() }.value
        let halted = try await kernel.meshStatus()
        XCTAssertTrue(halted.stopped)
        XCTAssertEqual(halted.stopLevel, 1)
        mac.presenter.approve = false
        let denied = await Task.detached { () -> Error? in
            do {
                try kernel.resumeStop()
                return nil
            } catch { return error }
        }.value
        XCTAssertEqual(denied as? MeshKernelError, .consentDenied)
        let still = try await kernel.meshStatus()
        XCTAssertTrue(still.stopped)
        mac.presenter.approve = true
        try await Task.detached { try kernel.resumeStop() }.value
        let prompt = try XCTUnwrap(mac.presenter.prompts.last)
        XCTAssertEqual(prompt.effect, "roster.resume")
        XCTAssertEqual(prompt.actionTitle, "Resume the mesh")
        XCTAssertTrue(prompt.requiresBiometry)
        XCTAssertGreaterThan(mac.presenter.prompts.count, before + 1)
        let resumed = try await kernel.meshStatus()
        XCTAssertFalse(resumed.stopped)
        await kernel.stopNetwork()
    }

    func testToolsListThisDevicesToolsThenPeerToolsWithoutDuplicates() async throws {
        let peerId = "sha256:" + String(repeating: "7", count: 64)
        let schema = #"{"type":"object","properties":{},"additionalProperties":false}"#
        let peers = [
            MeshPeerTool(
                deviceId: peerId,
                spec: MeshLocalToolSpec(
                    name: "calendar.read", summary: "Reads the calendar.", schemaJSON: schema,
                    effect: .outwardRead, confidentiality: .private)),
            MeshPeerTool(
                deviceId: peerId,
                spec: MeshLocalToolSpec(
                    name: "device_locale", summary: "Shadowed by the local tool.", schemaJSON: schema)),
        ]
        let mac = try await open("Mac", peerTools: peers)
        let tools = mac.kernel.tools()
        XCTAssertEqual(tools.map(\.name), ["current_datetime", "device_locale", "calendar.read"])
        XCTAssertEqual(tools.map(\.deviceId), [nil, nil, peerId])
        XCTAssertEqual(tools.last?.scope, "outward_read")
        XCTAssertEqual(tools.first?.grantKey, "current_datetime/mesh_read")
        XCTAssertEqual(Set(tools.map(\.id)).count, 3)
        await mac.kernel.stopNetwork()
    }

    func testAMailboxAddressIsCheckedAtOpenAndSurvivesAReopenOfTheSameMesh() async throws {
        let first = try await open("Mac")
        let none = try first.kernel.mailboxState()
        XCTAssertFalse(none.configured)
        XCTAssertEqual(none.status, .disabled)
        _ = try await createMesh(first)
        let original = try await first.kernel.meshStatus()
        await first.kernel.stopNetwork()

        do {
            _ = try await open("Mac", mailbox: "not an address", reusing: first)
            XCTFail("a malformed mailbox must be refused")
        } catch {
            XCTAssertEqual(error as? MeshKernelError, KernelMapping.refusal("config.mailbox"))
        }

        let peerKey = try first.keys.operationsPublicKey().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let second = try await open("Mac", mailbox: peerKey, reusing: first)
        let state = try second.kernel.mailboxState()
        XCTAssertTrue(state.configured)
        XCTAssertNotEqual(state.status, .disabled)
        let status = try await second.kernel.meshStatus()
        XCTAssertTrue(status.hasMesh)
        XCTAssertEqual(status.meshId, original.meshId)
        await second.kernel.stopNetwork()

        let third = try await open("Mac", reusing: first)
        XCTAssertFalse(try third.kernel.mailboxState().configured)
        await third.kernel.stopNetwork()
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
        do {
            _ = try await mac.kernel.act(surfaceId: "sha256:none", componentId: "c", capability: "cap", args: [:])
            XCTFail("an unknown surface must be refused")
        } catch {
            guard case MeshKernelError.refused(let code, let text) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "surface.unknown_surface")
            XCTAssertTrue(text.contains("surface.unknown_surface"))
        }
        do {
            try await mac.kernel.takeOverRun(runId: "missing")
            XCTFail("unknown run should be refused")
        } catch {
            XCTAssertTrue(error is MeshKernelError)
        }
        await mac.kernel.stopNetwork()
    }

    func testWakeRouteCrossesRealBindingsWithExactTargetsAndStoppedWithdrawal() async throws {
        let mac = try await open("Wake Mac")
        _ = try await createMesh(mac)
        let status = try await mac.kernel.meshStatus()
        let mesh = try XCTUnwrap(status.meshId)
        let device = try XCTUnwrap(status.deviceId)
        let route = MeshWakeRoute(
            publisher: "astral", capability: "opaque_wake_capability==",
            expiresAtMS: Int64(Date().timeIntervalSince1970 * 1000) + 60_000)
        try await mac.kernel.setWakeRoute(expectedMeshId: mesh, expectedDeviceId: device, route: route)
        let listed = try await mac.kernel.wakeRoutes()
        XCTAssertEqual(listed, [MeshDeviceWakeRoute(meshId: mesh, deviceId: device, route: route)])
        XCTAssertFalse(String(describing: listed).contains(route.capability))
        do {
            try await mac.kernel.setWakeRoute(expectedMeshId: mesh, expectedDeviceId: "different-device", route: nil)
            XCTFail("A different target accepted a withdrawal")
        } catch {}
        try await Task.detached { try mac.kernel.raiseStop() }.value
        do {
            _ = try await mac.kernel.wakeRoutes()
            XCTFail("Stopped routes remained usable")
        } catch { XCTAssertEqual(error as? MeshKernelError, .stopped) }
        try await mac.kernel.setWakeRoute(expectedMeshId: mesh, expectedDeviceId: device, route: nil)
        try await Task.detached { try mac.kernel.resumeStop() }.value
        let cleared = try await mac.kernel.wakeRoutes()
        XCTAssertTrue(cleared.isEmpty)
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
        let provider = try XCTUnwrap(providers.first)
        XCTAssertTrue(provider.hasKey)
        XCTAssertTrue(provider.availableOnDevice)
        XCTAssertNil(provider.recipients)
        let status = try await mac.kernel.meshStatus()
        let device = try XCTUnwrap(status.deviceId)
        let selected = try mac.kernel.setModelProviderRecipients(name: provider.providerId, recipients: [device])
        XCTAssertEqual(selected.recipients, [device])
        XCTAssertTrue(selected.hasKey)
        XCTAssertTrue(selected.availableOnDevice)
        XCTAssertThrowsError(
            try mac.kernel.setModelProviderRecipients(name: provider.providerId, recipients: ["not-a-member"]))
        let all = try mac.kernel.setModelProviderRecipients(name: provider.providerId, recipients: nil)
        XCTAssertNil(all.recipients)
        XCTAssertTrue(all.hasKey)
        XCTAssertFalse(String(describing: providers).contains("sk-test-key"))
        XCTAssertThrowsError(
            try mac.kernel.setModelProvider(MeshModelProviderConfig(baseURL: "not a url", model: "m", apiKey: "k")))
        await mac.kernel.stopNetwork()
    }

}
