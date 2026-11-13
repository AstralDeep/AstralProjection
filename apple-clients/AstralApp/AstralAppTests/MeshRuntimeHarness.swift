// Builds a MeshRuntime over an InMemoryMeshKernel with in-memory custody so tests can drive kernel events and inspect state.
// It also provides a recording speech sink and small helpers shared by the mesh runtime tests.

@testable import AstralDeep
import AstralCore
import XCTest

nonisolated final class KernelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: InMemoryMeshKernel?
    private var configs: [MeshKernelConfig] = []
    private var rejecting = false
    var openedConfigs: [MeshKernelConfig] {
        get { lock.withLock { configs } }
        set { lock.withLock { configs = newValue } }
    }
    var rejectMailbox: Bool {
        get { lock.withLock { rejecting } }
        set { lock.withLock { rejecting = newValue } }
    }
    var kernel: InMemoryMeshKernel? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var nonces: [String] = []
    var seen: [String] { lock.withLock { nonces } }
    func record(_ nonce: String) { lock.withLock { nonces.append(nonce) } }
}

@MainActor
final class RecordingSpeechSink: MeshSpeechSink {
    var deltas: [String] = []
    var finished = 0
    var toolsStarted: [String] = []
    var toolsFinished: [String] = []
    var risky: [Bool] = []

    func answerDelta(_ text: String) { deltas.append(text) }
    func answerFinished() { finished += 1 }
    func toolStarted(id: String, cancelSafe: Bool) { toolsStarted.append(id) }
    func toolFinished(id: String) { toolsFinished.append(id) }
    func setRiskyActionPending(_ pending: Bool) { risky.append(pending) }
}

@MainActor
struct MeshRuntimeHarness {
    let runtime: MeshRuntime
    let box: KernelBox
    let tokens: TokenBox
    let defaults: UserDefaults
    let suite: String

    var kernel: InMemoryMeshKernel { box.kernel! }

    init(
        hasMesh: Bool = true, factoryError: MeshKernelError? = nil, mailbox: String? = nil, rejectMailbox: Bool = false,
        onDeviceAvailable: Bool = false, enrollment: (@Sendable (String) async throws -> String)? = nil
    ) {
        let box = KernelBox()
        let tokens = TokenBox()
        let suite = "mesh.runtime.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        if let mailbox { defaults.set(mailbox, forKey: "astral.mesh.mailbox") }
        box.rejectMailbox = rejectMailbox
        let factory: MeshKernelFactory = { config, _, _, _, listener in
            if let factoryError { throw factoryError }
            box.openedConfigs.append(config)
            if box.rejectMailbox, config.mailbox != nil {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "config.mailbox"))
            }
            let kernel = InMemoryMeshKernel(listener: listener, hasMesh: hasMesh)
            box.kernel = kernel
            return kernel
        }
        let signIn: @Sendable (String) async throws -> String =
            enrollment ?? { nonce in
                tokens.record(nonce)
                return "id-token"
            }
        runtime = MeshRuntime(
            makeKernel: factory,
            makeKeys: {
                try DeviceKeys(
                    store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
            },
            consent: ConsentCoordinator(), onDeviceModel: FakeOnDeviceModel(available: onDeviceAvailable),
            tools: DeviceLocalTools(), dataDirectory: FileManager.default.temporaryDirectory,
            deviceLabel: "Test Mac", deviceKind: .desktop, enrollment: signIn, defaults: defaults)
        self.box = box
        self.tokens = tokens
        self.defaults = defaults
        self.suite = suite
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    static func message(
        _ id: String, parent: String?, author: MeshAuthor = .owner, text: String = "text",
        at seconds: TimeInterval, delivery: MeshDelivery = .recorded, surfaces: [String] = []
    ) -> MeshChatMessage {
        MeshChatMessage(
            eventId: id, parentId: parent, author: author, authorDevice: nil, text: text,
            createdAt: Date(timeIntervalSince1970: seconds), delivery: delivery, surfaceIds: surfaces)
    }
}

@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
