#if DEBUG
    // DEBUG-only launch scenarios that run mesh mode over an InMemoryMeshKernel with in-memory custody, compiled out of release builds.
    // They let UI tests and screenshots reach onboarding and the seeded shell without a kernel, Keychain items or a sign-in.
    import AstralCore
    import CryptoKit
    import Foundation

    enum MeshUITestFixture {
        enum Scenario: String {
            case onboarding
            case shell
        }

        private static let launchFlag = "--astral-ui-test-mesh"

        static func requestedScenario(arguments: [String] = ProcessInfo.processInfo.arguments) -> Scenario? {
            guard let index = arguments.firstIndex(of: launchFlag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return Scenario(rawValue: arguments[index + 1])
        }

        @MainActor
        static func install(
            _ scenario: Scenario, consent: ConsentCoordinator
        ) -> (mode: AppModeStore, runtime: MeshRuntime) {
            let suite = "MeshUITest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let mode = AppModeStore(defaults: defaults)
            mode.choose(.mesh)
            let hasMesh = scenario == .shell
            let factory: MeshKernelFactory = { _, _, _, _, listener in
                let kernel = InMemoryMeshKernel(listener: listener, hasMesh: hasMesh)
                kernel.recoveryWords = (0..<24).map { "word" + String(UnicodeScalar(UInt8(97 + $0))) }
                kernel.hasLocalMesh = true
                if hasMesh { seed(kernel) }
                return kernel
            }
            let runtime = MeshRuntime(
                makeKernel: factory,
                makeKeys: {
                    try DeviceKeys(
                        store: MeshFixtureSecretStore(), defaults: UserDefaults(suiteName: suite)!,
                        preferHardware: false)
                },
                consent: consent, onDeviceModel: FoundationModelsOnDeviceModel(), tools: DeviceLocalTools(),
                dataDirectory: FileManager.default.temporaryDirectory, deviceLabel: "Preview Mac",
                deviceKind: .desktop,
                enrollment: { _ in "fixture-id-token" }, defaults: defaults)
            return (mode, runtime)
        }

        private static func seed(_ kernel: InMemoryMeshKernel) {
            let now = Date()
            kernel.setMembers([
                MeshMember(
                    memberId: "sha256:" + String(repeating: "b", count: 64), label: "Preview Mac", kind: .desktop,
                    isThisDevice: true, attested: true, lastSeen: nil, path: .none),
                MeshMember(
                    memberId: "sha256:" + String(repeating: "c", count: 64), label: "Sam's iPhone", kind: .pocket,
                    isThisDevice: false, attested: false, lastSeen: now.addingTimeInterval(-1_800), path: .relay),
            ])
            kernel.setSync(
                MeshSyncState(
                    devices: [
                        MeshDeviceSync(
                            memberId: "sha256:" + String(repeating: "c", count: 64), label: "Sam's iPhone",
                            state: .unreachable, lastSeen: now.addingTimeInterval(-1_800), path: .none)
                    ], updatedAt: now))
            kernel.setAllowance(
                MeshAllowance(
                    share: .solo, periodEndsAt: now.addingTimeInterval(14_400),
                    lines: [
                        .init(effectClass: "Notes and memory", remaining: 41, limit: 50),
                        .init(effectClass: "Outside actions", remaining: 0, limit: 0),
                    ], modelTokensRemaining: 18_000, modelTokensLimit: 40_000, blocked: .soloNeedsConsent))
            let chat = kernel.seedChat(
                title: "Weekly plan",
                messages: [
                    message("a", nil, .owner, "Plan my week around the lab meeting", now.addingTimeInterval(-900)),
                    message(
                        "b", "a", .assistant, "Here is a plan.\nSee [the doc](https://evil.example/leak) for more.",
                        now.addingTimeInterval(-800), surfaces: ["s1"]),
                    message("c", "b", .owner, "Make it shorter", now.addingTimeInterval(-700)),
                    message("d", "b", .owner, "Add a gym slot", now.addingTimeInterval(-600)),
                    message(
                        "e", "d", .owner, "Move gym to Friday", now.addingTimeInterval(-60), delivery: .queued),
                ], surfaces: [planSurface()])
            let me = "sha256:" + String(repeating: "b", count: 64)
            let phone = "sha256:" + String(repeating: "c", count: 64)
            kernel.setRequests([
                MeshRequest(
                    requestId: "sha256:" + String(repeating: "1", count: 64), chatId: chat, fromMember: phone,
                    toMember: me, state: .pending, text: "Summarize today's lab notes", refusalCode: nil, tool: nil,
                    createdAt: now.addingTimeInterval(-300)),
                MeshRequest(
                    requestId: "sha256:" + String(repeating: "2", count: 64), chatId: chat, fromMember: me,
                    toMember: phone, state: .refused, text: "Print the weekly plan", refusalCode: "request.busy",
                    tool: nil, createdAt: now.addingTimeInterval(-500)),
                MeshRequest(
                    requestId: "sha256:" + String(repeating: "3", count: 64), chatId: chat, fromMember: me,
                    toMember: phone, state: .claimed, text: "Check the calendar for Friday", refusalCode: nil,
                    tool: "calendar.read", createdAt: now.addingTimeInterval(-120)),
            ], notify: false)
            kernel.setPending([pendingConsent()])
        }

        private static func message(
            _ id: String, _ parent: String?, _ author: MeshAuthor, _ text: String, _ at: Date,
            delivery: MeshDelivery = .recorded, surfaces: [String] = []
        ) -> MeshChatMessage {
            MeshChatMessage(
                eventId: id, parentId: parent, author: author, authorDevice: nil, text: text, createdAt: at,
                delivery: delivery, surfaceIds: surfaces)
        }

        private static func planSurface() -> MeshSurface {
            MeshSurface(
                surfaceId: "s1", root: "root",
                nodes: [
                    "root": MeshSurfaceNode(
                        id: "root", type: "container", props: [:], children: ["card", "go"], provenance: "model"),
                    "card": MeshSurfaceNode(
                        id: "card", type: "metric_card",
                        props: ["title": .string("Focus hours"), "value": .string("18"), "subtitle": .string("this week")],
                        children: [], provenance: "tool"),
                    "go": MeshSurfaceNode(
                        id: "go", type: "button",
                        props: ["label": .string("Add to calendar"), "action": .object(["capability": .string("cap1")])],
                        children: [], provenance: "model"),
                ])
        }

        private static func pendingConsent() -> MeshPendingConsent {
            func id(_ byte: String) -> String { "sha256:" + String(repeating: byte, count: 32) }
            func hash(_ data: Data) -> String {
                "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let arguments = Data(#"{"subject":"Status","to":"lab@example.edu"}"#.utf8)
            let action = Data(
                (#"{"agent":"mail","args_digest":""# + hash(arguments) + #"","device":""# + id("22")
                    + #"","influence":[],"mesh":""# + id("11") + #"","tool":"mail.send","tool_def":""# + id("33")
                    + #"","turn":""# + id("44") + #"","v":1}"#).utf8)
            let consent = Data(
                (#"{"clock":{"ms":1,"n":0},"device":""# + id("22") + #"","digest":""# + hash(action)
                    + #"","kind":"action","v":1}"#).utf8)
            return MeshPendingConsent(
                requestId: "fixture-consent", chatId: nil, kind: .action, canonicalAction: action,
                canonicalArguments: arguments, signingInput: Data("astral.consent/v1\n".utf8) + consent)
        }
    }

    nonisolated final class MeshFixtureSecretStore: MeshSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func load(_ account: String) throws -> Data? { lock.withLock { values[account] } }
        func save(_ value: Data, account: String) throws { lock.withLock { values[account] = value } }
        func remove(_ account: String) throws { lock.withLock { values[account] = nil } }
    }
#endif
