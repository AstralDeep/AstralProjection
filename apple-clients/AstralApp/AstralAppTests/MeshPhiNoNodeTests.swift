// Proves on a real Kernel with no node that a fresh mesh labels PHI on its own device, refuses it toward an unapproved endpoint, asks about uncertain text and lets an approved endpoint through.
// The endpoint is a reserved name that never resolves, and the on-device fixture model counts every request, so a refusal is visible as zero requests.

import AstralKernel
import XCTest

@testable import AstralDeep

nonisolated final class ScriptedPhiPrompt: MeshPhiPrompting, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: MeshPhiAnswer
    private var asked: [MeshPhiQuestion] = []

    init(_ answer: MeshPhiAnswer) { self.answer = answer }

    var questions: [MeshPhiQuestion] { lock.withLock { asked } }

    func set(_ value: MeshPhiAnswer) { lock.withLock { answer = value } }

    func ask(_ question: MeshPhiQuestion) -> MeshPhiAnswer {
        lock.withLock {
            asked.append(question)
            return answer
        }
    }
}

final class MeshPhiNoNodeTests: XCTestCase {
    private static let refusals: Set<String> = ["flow.phi_to_model", "provider.no_candidate"]
    private static let endpoint = "https://phi-fixture.invalid/v1"
    private static let clinical = "Patient MRN 4455667 reports chest pain since Monday."
    private static let uncertain = "The visit is booked for 2026-03-14 at the usual clinic."

    private struct Phone {
        let kernel: RealMeshKernel
        let model: FakeOnDeviceModel
        let prompt: ScriptedPhiPrompt
        let changes: ChangeLog
    }

    private func open(
        modelAvailable: Bool = true, answer: MeshPhiAnswer = .treatAsPhi
    ) async throws -> Phone {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("no-node-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "no.node." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(
            store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
        let config = MeshKernelConfig(
            dataDirectory: directory, deviceLabel: "Phone", deviceKind: .pocket,
            operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
            installMarker: try keys.installMarker(), restoredInstall: false)
        let model = FakeOnDeviceModel(available: modelAvailable, mode: .respond(.text("Understood.")))
        let prompt = ScriptedPhiPrompt(answer)
        let changes = ChangeLog()
        let kernel = try await RealMeshKernel.open(
            config: config, network: KernelNetworking.loopback,
            signer: MeshHostSigner(keys: keys, presenter: RecordingPresenter()), model: model,
            tools: DeviceLocalTools(), listener: changes, keystore: MemoryHostKeystore(), phiPrompt: prompt)
        addTeardownBlock { await kernel.stopNetwork() }
        _ = try await Task.detached {
            let kit = try kernel.createMesh()
            try kernel.confirmMeshRecovery()
            _ = try kernel.adoptPhiGroup()
            return kit
        }.value
        try kernel.setModelProvider(MeshModelProviderConfig(baseURL: Self.endpoint, model: "m", apiKey: "key"))
        return Phone(kernel: kernel, model: model, prompt: prompt, changes: changes)
    }

    private func turnRequests(_ phone: Phone) -> Int {
        phone.model.requests.filter { !($0.schemaJSON ?? "").contains("findings") }.count
    }

    private func send(
        _ phone: Phone, _ text: String, attended: Bool = false
    ) async throws -> (chat: String, id: String) {
        let kernel = phone.kernel
        return try await Task.detached {
            let chat = try kernel.createChat(title: "t")
            let id = try kernel.sendMessage(
                chatId: chat, text: text, continues: nil, attachments: [], attended: attended)
            return (chat, id)
        }.value
    }

    private func label(_ phone: Phone, chat: String, id: String) throws -> String? {
        try phone.kernel.chat(chatId: chat).messages.first { $0.eventId == id }?.confidentiality
    }

    private func failure(_ phone: Phone) -> String? {
        for change in phone.changes.changes {
            guard case .turnProgress(let progress) = change else { continue }
            switch progress.event {
            case .refused(let code, _): return code
            case .failed(let text): return text
            default: continue
            }
        }
        return nil
    }

    private func run(_ phone: Phone, chat: String) async {
        let kernel = phone.kernel
        _ = try? await Task.detached { try await kernel.runTurn(chatId: chat) }.value
    }

    private func approveEndpoint(_ phone: Phone) async throws {
        let kernel = phone.kernel
        let name = try providerName(phone)
        try await Task.detached {
            let proposal = try kernel.proposeProviderPhiDestination(name: name)
            try kernel.approvePhiDestination(proposal)
        }.value
    }

    private func providerName(_ phone: Phone) throws -> String {
        try XCTUnwrap(phone.kernel.modelProviders().first?.providerId)
    }

    func testClinicalInputIsLabeledPhiAndStaysOnTheDeviceWhenTheEndpointIsUnapproved() async throws {
        let phone = try await open()
        let (chat, id) = try await send(phone, Self.clinical)
        XCTAssertEqual(try label(phone, chat: chat, id: id), "phi")
        await run(phone, chat: chat)
        XCTAssertEqual(turnRequests(phone), 1)
        XCTAssertNil(failure(phone))
        let answer = try phone.kernel.chat(chatId: chat).messages.last
        XCTAssertEqual(answer?.text, "Understood.")
        XCTAssertEqual(answer?.confidentiality, "phi")
        XCTAssertFalse(phone.kernel.phiDestinationAllowed(kind: .model, target: Self.endpoint))
    }

    func testWithNoOnDeviceModelTheUnapprovedEndpointIsRefusedAndNothingIsSent() async throws {
        let phone = try await open(modelAvailable: false)
        let (chat, id) = try await send(phone, Self.clinical)
        XCTAssertEqual(try label(phone, chat: chat, id: id), "phi")
        await run(phone, chat: chat)
        XCTAssertTrue(Self.refusals.contains(failure(phone) ?? ""), "\(failure(phone) ?? "none")")
        XCTAssertEqual(turnRequests(phone), 0)
    }

    func testApprovingTheEndpointByNameLetsTheSameTurnRun() async throws {
        let phone = try await open(modelAvailable: false)
        let (chat, _) = try await send(phone, Self.clinical)
        await run(phone, chat: chat)
        XCTAssertTrue(Self.refusals.contains(failure(phone) ?? ""), "\(failure(phone) ?? "none")")
        try await approveEndpoint(phone)
        XCTAssertTrue(phone.kernel.phiDestinationAllowed(kind: .model, target: Self.endpoint))
        let before = phone.changes.changes.count
        await run(phone, chat: chat)
        let later = phone.changes.changes.dropFirst(before)
        let gated = later.contains { change in
            guard case .turnProgress(let progress) = change, case .refused(let code, _) = progress.event else {
                return false
            }
            return Self.refusals.contains(code)
        }
        XCTAssertFalse(gated)
    }

    func testUncertainInputAsksAttendedAndTheAnswerSetsTheLabel() async throws {
        let phone = try await open(answer: .send)
        let (kept, keptId) = try await send(phone, Self.uncertain, attended: true)
        XCTAssertEqual(phone.prompt.questions.count, 1)
        XCTAssertFalse(phone.prompt.questions[0].items.isEmpty)
        XCTAssertEqual(try label(phone, chat: kept, id: keptId), "private")
        phone.prompt.set(.treatAsPhi)
        let (held, heldId) = try await send(phone, Self.uncertain, attended: true)
        XCTAssertEqual(phone.prompt.questions.count, 2)
        XCTAssertEqual(try label(phone, chat: held, id: heldId), "phi")
    }

    func testUncertainInputNeverAsksWhenUnattended() async throws {
        let phone = try await open(answer: .send)
        let (chat, id) = try await send(phone, Self.uncertain)
        XCTAssertTrue(phone.prompt.questions.isEmpty)
        XCTAssertEqual(try label(phone, chat: chat, id: id), "phi")
    }

    func testWithTheAdapterAbsentTheFloorAloneDecides() async throws {
        let phone = try await open(modelAvailable: false, answer: .send)
        let (chat, id) = try await send(phone, Self.clinical)
        XCTAssertEqual(try label(phone, chat: chat, id: id), "phi")
        let (plain, plainId) = try await send(phone, "What is a good name for a cat?")
        XCTAssertEqual(try label(phone, chat: plain, id: plainId), "private")
        XCTAssertTrue(phone.model.requests.isEmpty)
        XCTAssertFalse(try phone.kernel.phiStatus().modelPresent)
    }
}
