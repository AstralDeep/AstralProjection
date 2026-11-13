// Unit tests for the pure mapping layer between the generated kernel records and the host's Mesh types: status, allowance, errors, turn events, the chat tree, surfaces, host-signer prompts and local tools.
// They build the generated records directly, so no kernel is opened.

@testable import AstralDeep
import AstralKernel
import CryptoKit
import XCTest

final class KernelMappingTests: XCTestCase {
    private let feed = "feed-a"

    private func message(
        _ id: String, _ role: AstralKernel.Role, text: String?, turn: String?, branch: String? = nil, ms: UInt64,
        status: AstralKernel.MessageStatus = .complete, kind: String? = nil
    ) -> AstralKernel.ChatMessage {
        AstralKernel.ChatMessage(
            id: id, role: role, kind: kind ?? (role == .user ? "chat.user_message" : "chat.assistant_message"),
            text: text, componentJson: nil, turn: turn, branch: branch,
            labels: LabelView(confidentiality: "private", integrity: "owner"), status: status, feed: feed, seq: ms,
            clock: ClockStamp(ms: ms, n: 0), author: "device")
    }

    private func turn(_ id: String, continues: String?, message: String?, branch: String, ms: UInt64) -> TurnInfo {
        TurnInfo(
            id: id, continues: continues, message: message, branch: branch, status: .ended, feed: feed,
            clock: ClockStamp(ms: ms, n: 0), steps: 1, author: "device")
    }

    private func view(
        messages: [AstralKernel.ChatMessage], turns: [TurnInfo], surfaces: [SurfaceEvent] = []
    ) -> AstralKernel.ChatView {
        AstralKernel.ChatView(
            chatId: "chat", title: "Title", created: nil, lastActivity: ClockStamp(ms: 99, n: 0), messages: messages,
            turns: turns, branches: [], forkPoints: [], surfaces: surfaces, unreadable: [], waiting: [], invalid: [])
    }

    private func twoTurnView() -> AstralKernel.ChatView {
        view(
            messages: [
                message("u1", .user, text: "one", turn: "t1", branch: "t1", ms: 1),
                message("a1", .assistant, text: "answer one", turn: "t1", branch: "t1", ms: 3),
                message("s1", .assistant, text: "spoken", turn: "t1", ms: 4, kind: "chat.spoken"),
                message("u2", .user, text: "two", turn: "t2", branch: "t1", ms: 5),
                message("a2", .assistant, text: "answer two", turn: "t2", branch: "t1", ms: 7),
                message("u3", .user, text: "three", turn: "t3", branch: "t3", ms: 8),
                message("q1", .user, text: "queued", turn: nil, branch: "t1", ms: 20, status: .queued),
            ],
            turns: [
                turn("t1", continues: nil, message: "u1", branch: "t1", ms: 2),
                turn("t2", continues: "t1", message: "u2", branch: "t1", ms: 4),
                turn("t3", continues: "t1", message: "u3", branch: "t3", ms: 8),
            ])
    }

    func testChatTreeChainsTurnsAfterTheTurnTheyContinueAndSkipsSpokenRecords() {
        let folded = KernelChatMapper.fold(twoTurnView(), queuedBases: [:])
        let parents = Dictionary(uniqueKeysWithValues: folded.messages.map { ($0.eventId, $0.parentId) })
        XCTAssertNil(parents["u1"] ?? nil)
        XCTAssertEqual(parents["a1"], "u1")
        XCTAssertEqual(parents["u2"], "a1")
        XCTAssertEqual(parents["a2"], "u2")
        XCTAssertEqual(parents["u3"], "a1")
        XCTAssertNil(parents["s1"] ?? nil)
        XCTAssertFalse(folded.messages.contains { $0.eventId == "s1" })
        XCTAssertEqual(parents["q1"], "a2")
        XCTAssertEqual(folded.messages.first { $0.eventId == "q1" }?.delivery, .queued)
        XCTAssertEqual(folded.messages.first { $0.eventId == "a1" }?.author, .assistant)
        let branches = KernelChatMapper.branches(of: folded.messages)
        XCTAssertEqual(Set(branches.map(\.headId)), ["q1", "u3"])
        XCTAssertEqual(branches.first { $0.headId == "u3" }?.forkId, "a1")
    }

    func testContinuationResolvesMessagesToTheirTurnAndQueuedMessagesToTheirAnchor() {
        let v = twoTurnView()
        XCTAssertEqual(KernelChatMapper.continuation(for: "a1", in: v, queuedBases: [:]), .turn("t1"))
        XCTAssertEqual(KernelChatMapper.continuation(for: "u2", in: v, queuedBases: [:]), .turn("t2"))
        XCTAssertEqual(KernelChatMapper.continuation(for: "q1", in: v, queuedBases: [:]), .turn("t2"))
        XCTAssertEqual(KernelChatMapper.continuation(for: "q1", in: v, queuedBases: ["q1": "t1"]), .turn("t1"))
        XCTAssertNil(KernelChatMapper.continuation(for: "missing", in: v, queuedBases: [:]))
        let empty = view(
            messages: [message("q", .user, text: "hi", turn: nil, ms: 1, status: .queued)], turns: [])
        XCTAssertEqual(KernelChatMapper.continuation(for: "q", in: empty, queuedBases: [:]), .root)
    }

    func testSurfacesFoldPutsAndPatchesAndRejectBadDocuments() {
        func event(_ id: String, _ kind: String, _ ms: UInt64, _ body: String) -> SurfaceEvent {
            SurfaceEvent(
                id: id, kind: kind, feed: feed, seq: ms, clock: ClockStamp(ms: ms, n: 0), after: [], bodyJson: body,
                bodyState: .present)
        }
        let document =
            #"{"document":{"v":1,"surface":"new","root":"root","components":{"root":{"id":"root","type":"container","props":{},"children":["card"],"prov":"model"},"card":{"id":"card","type":"metric_card","props":{"title":"Focus"},"children":[],"prov":"tool"}},"capabilities":{}}}"#
        let patch =
            #"{"surface":"s1","ops":[{"op":"set","id":"card","prop":"title","value":"Updated"},{"op":"add","parent":"root","index":null,"component":{"id":"extra","type":"text","props":{},"children":[],"prov":"model"}},{"op":"remove","id":"missing"}]}"#
        let badPatch = #"{"surface":"s1","ops":[{"op":"remove","id":"root"},{"op":"add","parent":"root","index":0,"component":{"id":"card","type":"x","props":{},"children":[],"prov":"model"}}]}"#
        let badDocument = #"{"document":{"v":1,"surface":"new","root":"nope","components":{}}}"#
        let events = [
            event("s1", "ui.surface_put", 1, document), event("p1", "ui.patch", 2, patch),
            event("p2", "ui.patch", 3, badPatch), event("bad", "ui.surface_put", 4, badDocument),
            event("act", "ui.action", 5, "{}"),
            SurfaceEvent(
                id: "held", kind: "ui.surface_put", feed: feed, seq: 6, clock: ClockStamp(ms: 6, n: 0), after: [],
                bodyJson: nil, bodyState: .keyUnknown),
        ]
        let folded = KernelSurfaceFold.fold(events)
        XCTAssertEqual(folded.map(\.surface.surfaceId), ["s1"])
        let surface = folded[0].surface
        XCTAssertEqual(surface.nodes["card"]?.props["title"], .string("Updated"))
        XCTAssertEqual(surface.nodes["root"]?.children, ["card", "extra"])
        XCTAssertEqual(surface.nodes["card"]?.provenance, "tool")
        let withSurface = view(
            messages: [
                message("u1", .user, text: "q", turn: "t1", branch: "t1", ms: 1),
                message("a1", .assistant, text: "a", turn: "t1", branch: "t1", ms: 2),
            ], turns: [turn("t1", continues: nil, message: "u1", branch: "t1", ms: 1)], surfaces: events)
        let placed = KernelChatMapper.fold(withSurface, queuedBases: [:])
        XCTAssertEqual(placed.messages.first { $0.eventId == "a1" }?.surfaceIds, ["s1"])
    }

    func testStatusAllowanceAndProvidersMap() {
        let status = KernelMapping.status(
            AstralKernel.MeshStatus(
                state: .enrolled, meshId: "m", deviceId: "d", feed: "f", marker: .matches, members: 2, unattested: true,
                attestationDueS: nil, stop: 3, hardwareBacked: true, endpoint: .stopped, pairingOpen: false))
        XCTAssertTrue(status.hasMesh)
        XCTAssertFalse(status.attested)
        XCTAssertFalse(status.stopped)
        XCTAssertEqual(status.stopLevel, 3)
        let restored = KernelMapping.status(
            AstralKernel.MeshStatus(
                state: .restored, meshId: "m", deviceId: "d", feed: "f", marker: .mismatch, members: 2, unattested: false,
                attestationDueS: nil, stop: 0, hardwareBacked: false, endpoint: .stopped, pairingOpen: false))
        XCTAssertFalse(restored.hasMesh)

        let allowance = KernelMapping.allowance(
            AllowanceView(
                periodIndex: 2, mode: "solo",
                dimensions: [
                    AllowanceDimension(name: "model_tokens", cap: 100, consumed: 100, remaining: 0, consented: 0),
                    AllowanceDimension(name: "outside_effect", cap: 0, consumed: 0, remaining: 0, consented: 0),
                ], clockRegressed: false, refusals: ["allowance.solo_cap_reached"]))
        XCTAssertEqual(allowance.share, .solo)
        XCTAssertEqual(allowance.modelTokensLimit, 100)
        XCTAssertEqual(allowance.lines.map(\.effectClass), ["Outside actions"])
        XCTAssertEqual(allowance.blocked, .soloNeedsConsent)
        XCTAssertEqual(allowance.periodEndsAt, Date(timeIntervalSince1970: 3 * 86_400))
        let spent = KernelMapping.allowance(
            AllowanceView(
                periodIndex: -1, mode: "fresh",
                dimensions: [AllowanceDimension(name: "model_tokens", cap: 5, consumed: 5, remaining: 0, consented: 0)],
                clockRegressed: false, refusals: ["allowance.share_spent"]))
        XCTAssertEqual(spent.blocked, .periodExhausted)
        XCTAssertNil(spent.periodEndsAt)

        let infos = [
            ModelProviderInfo(name: "a", baseUrl: "https://a", models: ["m1"], fallbackOrder: 0, selfHosted: false),
            ModelProviderInfo(name: "b", baseUrl: "https://b", models: [], fallbackOrder: 1, selfHosted: true),
        ]
        XCTAssertEqual(infos.map { KernelMapping.provider($0, lowestOrder: 0).isDefault }, [true, false])
        XCTAssertEqual(KernelMapping.provider(infos[1], lowestOrder: 0).model, "")
        let config = try? KernelMapping.providerConfig(
            MeshModelProviderConfig(baseURL: "http://localhost:8080/v1", model: "m", apiKey: "k"))
        XCTAssertEqual(config?.selfHosted, true)
        XCTAssertNil(config?.recipients)
        XCTAssertEqual(config?.name, "localhost")
        XCTAssertEqual(
            try KernelMapping.providerConfig(
                MeshModelProviderConfig(baseURL: "https://api.example.test/v1", model: "m", apiKey: "k")
            ).name, "api-example-test")
    }

    func testErrorsMapToPlainWordsAndDenials() {
        XCTAssertEqual(
            KernelMapping.error(KernelError.Denied(code: "signer.denied", message: "x")) as? MeshKernelError,
            .consentDenied)
        let refused = KernelMapping.error(KernelError.State(code: "mesh.already_enrolled", message: "x"))
        XCTAssertEqual(refused as? MeshKernelError, .refused("This device already belongs to a mesh."))
        XCTAssertEqual(
            KernelMapping.error(TurnsError.Failed(code: "consent.declined", message: "")) as? MeshKernelError,
            .consentDenied)
        XCTAssertEqual(
            KernelMapping.error(RunsFfiError.Failed(code: "signer.denied", message: "")) as? MeshKernelError,
            .consentDenied)
        guard case MeshKernelError.refused(let text) = KernelMapping.error(
            RunsFfiError.Failed(code: "run.unknown", message: ""))
        else { return XCTFail("expected refusal") }
        XCTAssertTrue(text.contains("run.unknown"))
        guard case MeshKernelError.storage = KernelMapping.error(KernelError.Store(code: "store.io", message: ""))
        else { return XCTFail("expected storage") }
    }

    func testTurnProgressMapsToHostEvents() {
        func events(_ progress: TurnProgress) -> [MeshTurnEvent] {
            KernelMapping.turn(progress).compactMap {
                if case .turnProgress(let value) = $0 { return value.event }
                return nil
            }
        }
        XCTAssertEqual(events(.textDelta(chatId: "c", turnId: "t", text: "hi")), [.assistantDelta("hi")])
        XCTAssertEqual(
            events(.ended(chatId: "c", turnId: "t", reason: "completed", code: nil)), [.assistantFinished, .finished])
        XCTAssertEqual(events(.ended(chatId: "c", turnId: "t", reason: "interrupted", code: nil)), [.interrupted])
        XCTAssertTrue(events(.ended(chatId: "c", turnId: "t", reason: "fork", code: nil)).isEmpty)
        XCTAssertEqual(
            events(.ended(chatId: "c", turnId: "t", reason: "failed", code: "turn.no_provider")),
            [.failed("Add a model provider in Settings before asking for an answer.")])
        XCTAssertEqual(
            events(.toolResult(chatId: "c", turnId: "t", callId: "k", status: "error", code: nil)),
            [.toolFinished(id: "k", succeeded: false)])
        XCTAssertEqual(
            events(.toolProposed(chatId: "c", turnId: "t", callId: "k", tool: "mail.send", argumentsJson: "{}")),
            [.toolStarted(id: "k", name: "mail.send", cancelSafe: false)])
        let consent = PendingConsent(
            requestId: "r", chatId: "c", turnId: "t", callId: "k", toolName: "x", argumentsJson: "{}", reasons: [],
            influence: [], actionDigest: "d", actionJson: "{}")
        let requested = KernelMapping.turn(.consentRequested(consent: consent))
        XCTAssertTrue(requested.contains(.consentRequested(requestId: "r")))
        XCTAssertEqual(KernelMapping.changes(.syncStateChanged), [.syncStateChanged])
        XCTAssertEqual(KernelMapping.changes(.chatChanged(chatId: nil)), [.chatChanged(chatId: nil)])
        XCTAssertTrue(KernelMapping.changes(.pairing(progress: .failed(code: "x"))).isEmpty)
        XCTAssertTrue(KernelMapping.isEnrollmentComplete(.enrollment(state: .enrolled)))
        XCTAssertFalse(KernelMapping.isEnrollmentComplete(.enrollment(state: .creating)))
    }

    func testRunsAndProposalsMap() {
        let run = KernelMapping.run(
            RunInfo(
                runId: "r", chatId: "c", kind: .watch, goal: "g", project: nil, status: "paused", pauseKind: "owner",
                reason: "why", rounds: 2, stalls: 0, tokensSpent: 9, role: "watcher", executor: "dev", contested: [],
                branches: [], unknownSteps: [UnknownStepInfo(turn: "t", calls: ["k"], reason: "r")], hasNotes: false,
                lastSlot: nil))
        XCTAssertEqual(run.status, .paused)
        XCTAssertEqual(run.role, .watcher)
        XCTAssertEqual(run.unknownSteps, 1)
        XCTAssertEqual(MeshPresentation.runRole(run, executorLabel: "Phone"), "Running on Phone")
        let proposal = KernelMapping.proposal(
            ProposalInfo(
                id: "p", kind: "skill", name: "n", content: "c", contentHash: "h", tools: ["t"], project: nil,
                tool: nil, wider: false, status: "waiting_owner", statusDetail: [], integrity: "untrusted",
                confidentiality: "private", gatePassed: true, gateCodes: [], ownerReasons: ["wider"], hygiene: [],
                replayPassed: nil, evidenceEventIds: []))
        XCTAssertEqual(proposal.status, .waitingOwner)
        XCTAssertTrue(proposal.untrusted)
        XCTAssertEqual(KernelMapping.evaluation(.declined(reason: "no")), .declined("no"))
        XCTAssertEqual(MeshPresentation.evaluation(.waitingOwner), "Still waiting for your review.")
    }

    func testLocalToolsAreReadOnlyAndRefuseArguments() throws {
        let tools = DeviceLocalTools(
            now: { Date(timeIntervalSince1970: 0) }, locale: { Locale(identifier: "fr_CA") },
            timeZone: { TimeZone(identifier: "UTC")! })
        XCTAssertTrue(tools.list().allSatisfy { $0.effect == .meshRead })
        let time = try tools.call(name: "current_datetime", argumentsJSON: "{}", ticket: Data())
        XCTAssertEqual(time, #"{"iso8601":"1970-01-01T00:00:00Z","timezone":"GMT","weekday":"Thursday"}"#)
        let locale = try tools.call(name: "device_locale", argumentsJSON: "", ticket: Data())
        XCTAssertTrue(locale.contains("fr_CA"))
        XCTAssertThrowsError(try tools.call(name: "device_locale", argumentsJSON: #"{"x":1}"#, ticket: Data()))
        XCTAssertThrowsError(try tools.call(name: "device_locale", argumentsJSON: "[1]", ticket: Data()))
        let bridge = KernelLocalTools(tools)
        XCTAssertEqual(try bridge.list().map(\.name), ["current_datetime", "device_locale"])
        XCTAssertThrowsError(try bridge.call(name: "rm", argumentsJson: "{}", ticket: "t"))
        XCTAssertNoThrow(try bridge.call(name: "device_locale", argumentsJson: "{}", ticket: "t"))
    }

    func testHostSignerRefusesMismatchedOrUnreadablePrompts() {
        func prompt(kind: ConsentKind, title: String = "t", input: Data) -> AstralKernel.ConsentPrompt {
            AstralKernel.ConsentPrompt(
                kind: kind, title: title, target: "x", canonicalAction: Data(), canonicalArguments: Data(),
                signingInput: input, digest: "d", untrustedSources: [], labels: [], requiresBiometry: true)
        }
        let input = Data("astral.roster/v1\n{}".utf8)
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(kind: .rosterAdd, input: input), message: Data("other".utf8)))
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(kind: .other, input: input), message: input))
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(kind: .rosterAdd, input: input), message: input))
        XCTAssertThrowsError(try KernelHostSigner.display(for: prompt(kind: .toolEffect, title: "run.takeover", input: input), message: input))
        let signer = KernelHostSigner(MeshHostSigner(keys: try! DeviceKeys(
            store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: "k." + UUID().uuidString)!,
            preferHardware: false), presenter: RecordingPresenter()))
        XCTAssertThrowsError(try signer.presenceSign(prompt: prompt(kind: .stop, input: input), message: input)) { error in
            guard case HostSignerError.Failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(signer.identityPublicKey().count, 65)
        XCTAssertEqual(signer.presencePublicKey().count, 65)
        XCTAssertFalse(signer.hardwareBacked())
    }

    func testStopAndTakeoverPromptsParseTheirExactSigningInput() throws {
        func id(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }
        func hash(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let key = String(repeating: "A", count: 43)
        let stop = #"{"author":"\#(id("2"))","body":{"counter":2},"clock":{"ms":1,"n":0},"follows":["\#(id("3"))"],"mesh":"\#(id("1"))","type":"stop","v":1}"#
        let stopPrompt = try AstralDeep.ConsentPrompt.roster(signingInput: Data(("astral.roster/v1\n" + stop).utf8))
        XCTAssertEqual(stopPrompt.effect, "roster.stop")
        XCTAssertEqual(stopPrompt.actionTitle, "Stop the mesh")
        let zero = stop.replacingOccurrences(of: #""counter":2"#, with: #""counter":0"#)
        XCTAssertThrowsError(try AstralDeep.ConsentPrompt.roster(signingInput: Data(("astral.roster/v1\n" + zero).utf8)))
        _ = key

        let action = Data(#"{"executor":"\#(id("2"))","kind":"run.takeover","run":"chat.run1","supersedes":["\#(id("4"))"],"v":1}"#.utf8)
        let consent = Data(#"{"clock":{"ms":1,"n":0},"device":"\#(id("2"))","digest":"\#(hash(action))","kind":"action","v":1}"#.utf8)
        let input = Data("astral.consent/v1\n".utf8) + consent
        let takeover = try AstralDeep.ConsentPrompt.takeover(canonicalAction: action, signingInput: input)
        XCTAssertTrue(takeover.isBound(to: input))
        XCTAssertTrue(takeover.requiresBiometry)
        XCTAssertFalse(takeover.isBound(to: input + Data([0])))
        let other = Data(#"{"executor":"\#(id("5"))","kind":"run.takeover","run":"chat.run1","supersedes":[],"v":1}"#.utf8)
        XCTAssertThrowsError(try AstralDeep.ConsentPrompt.takeover(canonicalAction: other, signingInput: input))

        let signer = AstralKernel.ConsentPrompt(
            kind: .toolEffect, title: "run.takeover", target: "owner_action", canonicalAction: action,
            canonicalArguments: action, signingInput: input, digest: hash(action), untrustedSources: [], labels: [],
            requiresBiometry: false)
        let shown = try KernelHostSigner.display(for: signer, message: input)
        XCTAssertEqual(shown.actionTitle, "Take over this run")
        XCTAssertTrue(shown.isBound(to: input))
    }

    func testGrantPromptsParseTheirExactSigningInputAndRequireBiometry() throws {
        func id(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }
        let action = Data(#"{"agent":"kernel","grant":"\#(id("a"))","kind":"auth.grant","scope":"mesh_read","tool":"files.read"}"#.utf8)
        func input(kind: String = "grant", digest: String? = nil, device: String? = nil, context: String = "astral.consent/v1") -> Data {
            Data(
                (context + "\n" + #"{"clock":{"ms":1,"n":0},"device":"\#(device ?? id("2"))","digest":"\#(digest ?? id("a"))","kind":"\#(kind)","v":1}"#)
                    .utf8)
        }
        XCTAssertTrue(AstralDeep.ConsentPrompt.isGrant(canonicalAction: action))
        XCTAssertFalse(AstralDeep.ConsentPrompt.isGrant(canonicalAction: Data(#"{"tool":"x"}"#.utf8)))
        XCTAssertFalse(AstralDeep.ConsentPrompt.isGrant(canonicalAction: Data("not json".utf8)))
        let good = input()
        let prompt = try AstralDeep.ConsentPrompt.grant(canonicalAction: action, canonicalArguments: action, signingInput: good)
        XCTAssertEqual(prompt.actionTitle, "Allow files.read")
        XCTAssertEqual(prompt.effect, "files.read")
        XCTAssertEqual(prompt.target, "Permission: read your mesh, for kernel")
        XCTAssertTrue(prompt.requiresBiometry)
        XCTAssertTrue(prompt.isBound(to: good))
        XCTAssertFalse(prompt.isBound(to: good + Data([0])))
        let bad: [(Data, Data, Data)] = [
            (action, Data(#"{"agent":"kernel"}"#.utf8), good),
            (action, action, input(kind: "action")),
            (action, action, input(digest: id("b"))),
            (action, action, input(device: "device")),
            (action, action, input(context: "astral.roster/v1")),
            (Data(#"{"agent":"kernel","grant":"\#(id("a"))","kind":"auth.grant","scope":"mesh_read"}"#.utf8), action, good),
            (Data(#"{"agent":"","grant":"\#(id("a"))","kind":"auth.grant","scope":"mesh_read","tool":"x"}"#.utf8), action, good),
            (Data(#"{"agent":"kernel","grant":"\#(id("a"))","kind":"auth.grant","scope":"","tool":"x"}"#.utf8), action, good),
            (Data(#"{"agent":"kernel","grant":"g","kind":"auth.grant","scope":"mesh_read","tool":"x"}"#.utf8), action, good),
            (Data(#"{"agent":"kernel","grant":"\#(id("a"))","kind":"auth.grant", "scope":"mesh_read","tool":"x"}"#.utf8), action, good),
        ]
        for (shown, arguments, signing) in bad {
            XCTAssertThrowsError(try AstralDeep.ConsentPrompt.grant(canonicalAction: shown, canonicalArguments: arguments, signingInput: signing))
        }
        let routed = AstralKernel.ConsentPrompt(
            kind: .toolEffect, title: "files.read", target: "grant mesh_read", canonicalAction: action,
            canonicalArguments: action, signingInput: good, digest: id("a"), untrustedSources: [], labels: [],
            requiresBiometry: false)
        let shown = try KernelHostSigner.display(for: routed, message: good)
        XCTAssertEqual(shown.actionTitle, "Allow files.read")
        XCTAssertTrue(shown.requiresBiometry)
        XCTAssertTrue(shown.isBound(to: good))
        XCTAssertEqual(MeshToolScope.description("*"), "every kind of action")
        XCTAssertEqual(MeshToolScope.description("custom"), "custom")
    }

    func testPendingConsentCardsRequireMatchingArguments() throws {
        func id(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }
        func hash(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let arguments = Data(#"{"to":"a@b.c"}"#.utf8)
        let action = Data(
            #"{"agent":"mail","args_digest":"\#(hash(arguments))","device":"\#(id("2"))","influence":["\#(id("9"))"],"mesh":"\#(id("1"))","tool":"mail.send","tool_def":"\#(id("3"))","turn":"\#(id("4"))","v":1}"#.utf8)
        let card = try AstralDeep.ConsentPrompt.pending(canonicalAction: action, canonicalArguments: arguments)
        XCTAssertEqual(card.actionTitle, "Approve mail.send")
        XCTAssertNotNil(card.untrustedSource)
        XCTAssertThrowsError(try AstralDeep.ConsentPrompt.pending(canonicalAction: action, canonicalArguments: Data(#"{"to":"x"}"#.utf8)))
        let runtimeCard = MeshPendingConsent(
            requestId: "r", chatId: "c", kind: .action, canonicalAction: action, canonicalArguments: arguments,
            signingInput: Data())
        XCTAssertEqual(try AstralDeep.ConsentPrompt.pending(canonicalAction: runtimeCard.canonicalAction, canonicalArguments: runtimeCard.canonicalArguments).digest, hash(action))
    }
}
