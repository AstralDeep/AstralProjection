// Reopens consistent snapshots of temporary real Kernels before and during ordinary turns.
// Native recovery must preserve exact signed message and turn identity, answer once, and reject unproven queued input.

@testable import AstralDeep
import AstralKernel
import SQLite3
import XCTest

nonisolated final class ResumeChangeRelay: MeshKernelListening, @unchecked Sendable {
    private let listener: any MeshKernelListening
    private let changes: ChangeLog

    init(_ listener: any MeshKernelListening, changes: ChangeLog) {
        self.listener = listener
        self.changes = changes
    }

    func onChange(_ change: MeshKernelChange) {
        changes.onChange(change)
        listener.onChange(change)
    }
}

nonisolated final class ResumeModelGate: AstralOnDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var released = false

    var requests: Int { lock.withLock { entered } }
    func available() -> Bool { true }
    func release() { lock.withLock { released = true } }
    func complete(_ request: AstralDeep.OnDeviceRequest) async -> AstralDeep.OnDeviceResponse {
        lock.withLock { entered += 1 }
        while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(5)) }
        return FakeOnDeviceResponses.response(.text("Original answer"), to: request)
    }
}

final class MeshOrdinaryResumeTests: XCTestCase {
    private func snapshot(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where !["kernel.sqlite3", "kernel.sqlite3-wal", "kernel.sqlite3-shm"].contains(item.lastPathComponent) {
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        var input: OpaquePointer?
        var output: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(source.appendingPathComponent("kernel.sqlite3").path, &input, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        defer { sqlite3_close(input) }
        XCTAssertEqual(sqlite3_open(destination.appendingPathComponent("kernel.sqlite3").path, &output), SQLITE_OK)
        defer { sqlite3_close(output) }
        let backup = try XCTUnwrap(sqlite3_backup_init(output, "main", input, "main"))
        XCTAssertEqual(sqlite3_backup_step(backup, -1), SQLITE_DONE)
        XCTAssertEqual(sqlite3_backup_finish(backup), SQLITE_OK)
    }

    func testRecoverySelectionRequiresOneLocalOrdinaryTurnOnTheActiveFeed() {
        let stamp = ClockStamp(ms: 1, n: 0)
        let message = AstralKernel.ChatMessage(
            id: "message", role: .user, kind: "chat.user_message", text: "Hello", componentJson: nil,
            turn: "turn", branch: "turn", labels: LabelView(confidentiality: "private", integrity: "owner"),
            status: .complete, feed: "local-feed", seq: 1, clock: stamp, author: "local", attachments: [])
        let turn = TurnInfo(
            id: "turn", continues: nil, message: "message", branch: "turn", status: .running,
            feed: "local-feed", clock: stamp, steps: 0, author: "local")
        let view = AstralKernel.ChatView(
            chatId: "chat", title: nil, created: nil, lastActivity: stamp, messages: [message], turns: [turn],
            branches: [], forkPoints: [], surfaces: [], unreadable: [], waiting: [], invalid: [])
        func selected(_ value: AstralKernel.ChatView) -> MeshResumeTarget? {
            RealMeshKernel.ordinaryResumeTarget(in: value, deviceId: "local", feed: "local-feed")
        }
        XCTAssertEqual(selected(view), MeshResumeTarget(chatId: "chat", turnId: "turn"))
        var foreign = view
        foreign.turns[0].author = "peer"
        XCTAssertNil(selected(foreign))
        foreign = view
        foreign.messages[0].author = "peer"
        XCTAssertNil(selected(foreign))
        var oldFeed = view
        oldFeed.turns[0].feed = "old-feed"
        XCTAssertNil(selected(oldFeed))
        var ended = view
        ended.turns[0].status = .ended
        XCTAssertNil(selected(ended))
        var queued = view
        queued.turns = []
        queued.messages[0].status = .queued
        XCTAssertNil(selected(queued))
        var unlinked = view
        unlinked.turns[0].message = nil
        XCTAssertNil(selected(unlinked))
        var managed = view
        managed.messages[0].kind = "chat.request"
        XCTAssertNil(selected(managed))
        var ambiguous = view
        ambiguous.turns.append(turn)
        XCTAssertNil(selected(ambiguous))
    }

    func testReopenResumesTheExactLocalOrdinaryTurnWithoutAnotherStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ordinary-resume-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let restored = root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "ordinary.resume." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults, preferHardware: false)
        let config = MeshKernelConfig(
            dataDirectory: source, deviceLabel: "Mac", deviceKind: .desktop,
            operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
            installMarker: try keys.installMarker(), restoredInstall: false)
        let waiting = ResumeModelGate()
        let original = try await RealMeshKernel.open(
            config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
            signer: MeshHostSigner(keys: keys, presenter: RecordingPresenter()), model: waiting,
            tools: DeviceLocalTools(), listener: ChangeLog())
        _ = try await Task.detached {
            let request = try original.beginMeshCreation()
            return try original.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: request.nonce))
        }.value
        let chat = try original.createChat(title: "Interrupted request")
        let message = try original.sendMessage(chatId: chat, text: "Answer this once", continues: nil)
        let work = Task.detached { try await original.runTurn(chatId: chat) }
        addTeardownBlock {
            try? original.interrupt(chatId: chat)
            waiting.release()
            _ = try? await work.value
            await original.stopNetwork()
        }
        let entered = await eventually { waiting.requests == 1 }
        XCTAssertTrue(entered)
        guard case .running(let turnId) = try original.chat(chatId: chat).status else {
            return XCTFail("The real kernel must have a signed open turn")
        }
        try snapshot(source, to: restored)
        try original.interrupt(chatId: chat)
        waiting.release()
        _ = try? await work.value
        await original.stopNetwork()
        let answering = FakeOnDeviceModel(mode: .respond(.text("Resumed answer")))
        let changes = ChangeLog()
        let runtime = MeshRuntime(
            makeKernel: { config, signer, model, tools, listener in
                try await RealMeshKernel.open(
                    config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
                    signer: signer, model: model, tools: tools, listener: ResumeChangeRelay(listener, changes: changes))
            },
            makeKeys: { keys }, consent: ConsentCoordinator(), onDeviceModel: answering, tools: DeviceLocalTools(),
            dataDirectory: restored, deviceLabel: "Mac", deviceKind: .desktop,
            enrollment: { TestTokenIssuer.token(nonce: $0) }, defaults: defaults)
        await runtime.open()
        let resumed = await eventually { answering.requests.count == 1 }
        XCTAssertTrue(resumed, "Opening the existing store must resume its local ordinary turn")
        if resumed { await runtime.settle() }
        await runtime.openChat(chat)
        XCTAssertEqual(runtime.currentChat?.messages.filter { $0.author == .owner }.map(\.eventId), [message])
        XCTAssertEqual(runtime.currentChat?.messages.filter { $0.author == .assistant }.map(\.text), ["Resumed answer"])
        let progress = changes.changes.compactMap { change -> MeshTurnProgress? in
            if case .turnProgress(let value) = change, value.chatId == chat { return value }
            return nil
        }
        XCTAssertFalse(progress.contains { $0.event == .started })
        XCTAssertTrue(progress.allSatisfy { $0.turnId == turnId })
        await runtime.close()
    }
    func testReopenRecoversTheExactLocallyAcceptedMessageBeforeItsTurnStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-message-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let restored = root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "pending.message." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults, preferHardware: false)
        let config = MeshKernelConfig(
            dataDirectory: source, deviceLabel: "Mac", deviceKind: .desktop,
            operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
            installMarker: try keys.installMarker(), restoredInstall: false)
        let original = try await RealMeshKernel.open(
            config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
            signer: MeshHostSigner(keys: keys, presenter: RecordingPresenter()), model: FakeOnDeviceModel(),
            tools: DeviceLocalTools(), listener: ChangeLog())
        _ = try await Task.detached {
            let request = try original.beginMeshCreation()
            return try original.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: request.nonce))
        }.value
        let chat = try original.createChat(title: "Accepted before crash")
        let message = try original.sendMessage(
            chatId: chat, text: "This accepted input must get one answer", continues: nil)
        XCTAssertEqual(try original.chat(chatId: chat).status, .idle)
        try snapshot(source, to: restored)
        await original.stopNetwork()
        let answering = FakeOnDeviceModel(mode: .respond(.text("Recovered accepted input")))
        let changes = ChangeLog()
        let runtime = MeshRuntime(
            makeKernel: { config, signer, model, tools, listener in
                try await RealMeshKernel.open(
                    config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
                    signer: signer, model: model, tools: tools, listener: ResumeChangeRelay(listener, changes: changes))
            },
            makeKeys: { keys }, consent: ConsentCoordinator(), onDeviceModel: answering, tools: DeviceLocalTools(),
            dataDirectory: restored, deviceLabel: "Mac", deviceKind: .desktop,
            enrollment: { TestTokenIssuer.token(nonce: $0) }, defaults: defaults)
        await runtime.open()
        let resumed = await eventually { answering.requests.count == 1 }
        XCTAssertTrue(resumed, "The native proof must recover this device's accepted ordinary message")
        if resumed { await runtime.settle() }
        await runtime.openChat(chat)
        XCTAssertEqual(runtime.currentChat?.messages.filter { $0.author == .owner }.map(\.eventId), [message])
        XCTAssertEqual(
            runtime.currentChat?.messages.filter { $0.author == .assistant }.map(\.text), ["Recovered accepted input"])
        await runtime.open()
        await runtime.settle()
        XCTAssertEqual(answering.requests.count, 1)
        let starts = changes.changes.compactMap { change -> MeshTurnProgress? in
            if case .turnProgress(let value) = change, value.chatId == chat, value.event == .started { return value }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        await runtime.close()
    }

    func testExplicitStopBeforeNativeEntryCannotReplayTheSameMessageAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pending-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "pending.stop." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults, preferHardware: false)
        let config = MeshKernelConfig(
            dataDirectory: directory, deviceLabel: "Mac", deviceKind: .desktop,
            operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
            installMarker: try keys.installMarker(), restoredInstall: false)
        let original = try await RealMeshKernel.open(
            config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
            signer: MeshHostSigner(keys: keys, presenter: RecordingPresenter()), model: FakeOnDeviceModel(),
            tools: DeviceLocalTools(), listener: ChangeLog())
        _ = try await Task.detached {
            let request = try original.beginMeshCreation()
            return try original.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: request.nonce))
        }.value
        let chat = try original.createChat(title: "Stop before entry")
        await original.stopNetwork()
        let answering = FakeOnDeviceModel(mode: .respond(.text("This stopped input must not be answered")))
        func makeRuntime(entry: @escaping @Sendable () async -> Void = {}) -> MeshRuntime {
            MeshRuntime(
                makeKernel: { config, signer, model, tools, listener in
                    try await RealMeshKernel.open(
                        config: config, issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback,
                        signer: signer, model: model, tools: tools, listener: listener)
                },
                makeKeys: { keys }, consent: ConsentCoordinator(), onDeviceModel: answering, tools: DeviceLocalTools(),
                dataDirectory: directory, deviceLabel: "Mac", deviceKind: .desktop,
                enrollment: { TestTokenIssuer.token(nonce: $0) }, defaults: defaults, waitForTurnEntry: entry)
        }
        let gate = ResumeWorkerGate()
        defer { gate.release() }
        let runtime = makeRuntime { await gate.wait() }
        await runtime.open()
        await runtime.openChat(chat)
        let accepted = await runtime.send("Stop this accepted input")
        XCTAssertTrue(accepted)
        let entered = await eventually { gate.entered == 1 }
        XCTAssertTrue(entered)
        let message = try XCTUnwrap(runtime.currentChat?.messages.last?.eventId)
        let stopping = Task { await runtime.interrupt() }
        let requested = await eventually {
            runtime.currentTurn?.stopRequested == true || runtime.currentTurn?.interrupted == true
        }
        XCTAssertTrue(requested)
        gate.release()
        await stopping.value
        await runtime.settle()
        XCTAssertEqual(answering.requests.count, 0)
        await runtime.close()
        let reopened = makeRuntime()
        await reopened.open()
        await reopened.settle()
        await reopened.openChat(chat)
        XCTAssertEqual(answering.requests.count, 0, "Explicitly stopped input must not execute after reopening")
        XCTAssertEqual(reopened.currentChat?.messages.filter { $0.author == .owner }.map(\.eventId), [message])
        XCTAssertTrue(reopened.currentChat?.messages.filter { $0.author == .assistant }.isEmpty == true)
        await reopened.close()
    }

}
