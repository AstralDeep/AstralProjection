// Covers the outcome-unknown flow end to end with synthetic jobs: disconnect builds the actionable card and
// persists it, each decision sends exactly one closed intent on the reconnected host, repeated taps are ignored,
// failed delivery keeps the card for retry, a confirmed acknowledgment clears card, record and host snapshot, a
// relaunch restores it only as a stale non-actionable banner, and another account never sees it.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacOutcomeUnknownTests: XCTestCase {
        private var suites: [String] = []
        private let sessionID = UUID().uuidString.lowercased()

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private final class Channel {
            var frames: [JSONValue] = []
            func send(_ text: String) -> Bool {
                guard let json = try? JSONValue.parse(Data(text.utf8)) else { return false }
                frames.append(json)
                return true
            }
            func decisions() -> [JSONValue] {
                frames.filter { $0["action"] == .string("computer_event") }.compactMap { $0["payload"] }
                    .filter { $0["event"] == .string("outcome_ack") }
            }
        }

        private struct Fixture {
            let host: MacComputerHost
            let commands: MacComputerCommands
            let channel: Channel
            let defaults: UserDefaults
            let store: OutcomeUnknownStore
            let suite: String
            let root: URL

            func close() {
                host.applicationWillTerminate()
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }

        private func fixture() throws -> Fixture {
            let suite = "MacOutcomeUnknownTests." + UUID().uuidString
            suites.append(suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let grants = MacComputerWorkspaceGrantIO(
                chooseDirectories: { [root] },
                resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
                makeBookmark: { Data($0.path.utf8) }, startAccess: { _ in true }, stopAccess: { _ in })
            let files = MacComputerFiles(defaults: defaults, grants: grants)
            files.bind("outcome-owner")
            files.choose()
            let commands = MacComputerCommands(
                spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                loginPath: { "/usr/bin:/bin" })
            let channel = Channel()
            let host = MacComputerHost(
                available: true, defaults: defaults, files: files, driver: MacComputerTaskDriver(),
                monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in }, commands: commands)
            host.bind(owner: "outcome-owner") { channel.send($0) }
            host.setEnabled(true)
            return Fixture(
                host: host, commands: commands, channel: channel, defaults: defaults,
                store: OutcomeUnknownStore(defaults: defaults), suite: suite, root: root)
        }

        private func reconnect(_ fixture: Fixture, _ model: AppModel) {
            _ = model.continuity.beginConnection(UUID().uuidString.lowercased())
            model.connected = true
            fixture.host.bind(owner: "outcome-owner") { fixture.channel.send($0) }
        }

        private func startBackgroundJob(_ fixture: Fixture) async throws -> String {
            let id = "creq_" + String(repeating: "7", count: 32)
            let request = try XCTUnwrap(
                InboundFrame.parse(
                    String(
                        decoding: JSONValue.object([
                            "type": .string("computer_request"), "request_id": .string(id),
                            "session_id": .string(sessionID), "verb": .string("run_command"),
                            "args": .object([
                                "argv": .array([.string("echo")]), "cwd": .string(fixture.root.path),
                                "background": .bool(true), "timeout_s": .number(3600),
                            ]),
                            "deadline_ms": .number(600000),
                        ]).encoded(), as: UTF8.self)))
            fixture.host.consume(request)
            var jobId: String?
            for _ in 0..<2000 {
                jobId = fixture.commands.registry.all.first?.id
                if jobId != nil { break }
                await Task.yield()
            }
            return try XCTUnwrap(jobId)
        }

        private func session(on fixture: Fixture) throws -> InboundFrame {
            let json = JSONValue.object([
                "type": .string("computer_session"), "session_id": .string(sessionID),
                "host_id": .string(try XCTUnwrap(fixture.host.descriptor).hostId), "state": .string("active"),
                "controller_label": .string("Outcome controller"),
            ])
            return try XCTUnwrap(InboundFrame.parse(String(decoding: json.encoded(), as: UTF8.self)))
        }

        private func receiveOutcomeAck(
            _ fixture: Fixture, _ model: AppModel, decision: String, incarnation: String? = nil,
            connection: String? = nil
        ) {
            model.handleFrame(InboundFrame(name: "computer_host", payload: .object([
                "host_id": .string(fixture.host.hostIdentifier),
                "outcome_ack": .object([
                    "decision": .string(decision),
                    "incarnation_id": .string(incarnation ?? fixture.host.incarnationId),
                    "connection_generation": .string(connection ?? model.continuity.connectionGeneration ?? ""),
                ]),
            ])))
        }

        private func account(_ subject: String) throws -> ConversationAccount {
            try XCTUnwrap(ConversationAccount(issuer: "https://sandbox.example", subject: subject))
        }

        private func scope(_ model: AppModel, _ account: ConversationAccount) -> String {
            model.serverBase.absoluteString + "|" + account.locatorStorageKey
        }

        private func waitUntil(
            _ condition: @autoclosure () throws -> Bool, tries: Int = 2000
        ) async throws -> Bool {
            for _ in 0..<tries {
                if try condition() { return true }
                await Task.yield()
            }
            return try condition()
        }

        private func boundModel(_ fixture: Fixture, _ owner: ConversationAccount) -> AppModel {
            let model = AppModel(
                outcomeUnknownStore: fixture.store, tokenStore: InMemoryTokenStore(),
                defaults: fixture.defaults, computerHost: fixture.host)
            model.signedIn = true
            model.bindConversationAccount(owner)
            fixture.host.bind(owner: "outcome-owner") { fixture.channel.send($0) }
            fixture.host.setEnabled(true)
            return model
        }

        private func assertClosedIntent(_ payload: JSONValue) {
            let frame = ComputerHostOutbound.frame(
                action: "computer_event",
                payload: [
                    "host_id": payload["host_id"]!, "event": payload["event"]!,
                    "decision": payload["decision"]!, "incarnation_id": payload["incarnation_id"]!,
                ])
            XCTAssertTrue(ComputerHostOutbound.isValid(frame))
        }

        func testStoreBoundsTheJobInventoryAndRejectsPersistedOutputContent() throws {
            let suite = "MacOutcomeUnknownTests." + UUID().uuidString
            suites.append(suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let store = OutcomeUnknownStore(defaults: defaults)
            let jobs = (0..<OutcomeUnknownRecord.maximumJobs).map { index in
                OutcomeUnknownRecordJob(
                    id: String(format: "%08x-a111-4111-8111-111111111111", index), state: "running",
                    exitCode: nil, signal: nil, outputBytes: index)
            }
            let record = OutcomeUnknownRecord(
                hostId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                incarnationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", jobs: jobs)
            let key = OutcomeUnknownStore.key(scope: "test-owner")

            XCTAssertTrue(store.save(record, key: key))
            XCTAssertEqual(store.load(key: key), record)
            XCTAssertFalse(
                store.save(
                    OutcomeUnknownRecord(
                        hostId: record.hostId, incarnationId: record.incarnationId, jobs: jobs + [jobs[0]]), key: key))
            XCTAssertEqual(store.load(key: key), record)

            let encoded = try XCTUnwrap(defaults.string(forKey: key))
            var object = try XCTUnwrap(JSONValue.parse(Data(encoded.utf8)).objectValue)
            var entries = try XCTUnwrap(object["jobs"]?.arrayValue)
            var first = try XCTUnwrap(entries[0].objectValue)
            first["output"] = .string("private output")
            entries[0] = .object(first)
            object["jobs"] = .array(entries)
            defaults.set(String(decoding: try JSONValue.object(object).encoded(), as: UTF8.self), forKey: key)

            XCTAssertNil(store.load(key: key))
        }

        func testDisconnectBuildsActionableCardAndAcknowledgeSendsExactlyOneIntent() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let model = boundModel(fixture, owner)
            fixture.host.consume(try session(on: fixture))
            let job = try await startBackgroundJob(fixture)
            XCTAssertNil(model.outcomeUnknownCard)
            await model.handle(.disconnected(reason: "server restart"))
            let card = try XCTUnwrap(model.outcomeUnknownCard)
            XCTAssertEqual(card.jobs.map(\.id), [job])
            XCTAssertEqual(card.jobs.first?.state, "running")
            XCTAssertFalse(card.restored)
            XCTAssertTrue(model.outcomeUnknownCardActionable)
            let stored = try XCTUnwrap(
                fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            XCTAssertEqual(stored.incarnationId, fixture.host.incarnationId)
            XCTAssertEqual(stored.jobs.map(\.id), [job])
            reconnect(fixture, model)
            model.decideOutcomeUnknown("acknowledge")
            let sent = try await waitUntil(
                model.outcomeUnknownCard?.decision == "acknowledge"
                    && model.outcomeUnknownCard?.delivery == .pending && fixture.channel.decisions().count == 1)
            XCTAssertTrue(sent)
            XCTAssertNotNil(model.outcomeUnknownCard)
            XCTAssertNotNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            let decisions = fixture.channel.decisions()
            XCTAssertEqual(decisions.count, 1)
            XCTAssertEqual(decisions.first?["decision"], .string("acknowledge"))
            XCTAssertEqual(decisions.first?["incarnation_id"], .string(fixture.host.incarnationId))
            for payload in decisions { assertClosedIntent(payload) }
            receiveOutcomeAck(fixture, model, decision: "discard")
            XCTAssertNotNil(model.outcomeUnknownCard, "a conflicting receipt cannot clear the pending decision")
            receiveOutcomeAck(fixture, model, decision: "acknowledge", incarnation: UUID().uuidString.lowercased())
            XCTAssertNotNil(model.outcomeUnknownCard, "a receipt for another incarnation cannot clear the card")
            receiveOutcomeAck(
                fixture, model, decision: "acknowledge",
                connection: UUID().uuidString.lowercased())
            XCTAssertNotNil(model.outcomeUnknownCard, "a receipt from another connection cannot clear the card")
            receiveOutcomeAck(fixture, model, decision: "acknowledge")
            let acknowledged = try await waitUntil(model.outcomeUnknownCard == nil)
            XCTAssertTrue(acknowledged)
            XCTAssertNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            XCTAssertTrue(fixture.host.uncertainJobs.isEmpty)
            model.decideOutcomeUnknown("discard")
            XCTAssertEqual(fixture.channel.decisions().count, 1, "a resolved card never sends again")
        }

        func testDiscardSendsExactlyOneIntentAndClearsTheCard() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let model = boundModel(fixture, owner)
            fixture.host.consume(try session(on: fixture))
            _ = try await startBackgroundJob(fixture)
            await model.handle(.disconnected(reason: "server restart"))
            reconnect(fixture, model)
            model.decideOutcomeUnknown("discard")
            let sent = try await waitUntil(
                model.outcomeUnknownCard?.decision == "discard"
                    && model.outcomeUnknownCard?.delivery == .pending && fixture.channel.decisions().count == 1)
            XCTAssertTrue(sent)
            receiveOutcomeAck(fixture, model, decision: "discard")
            let discarded = try await waitUntil(model.outcomeUnknownCard == nil)
            XCTAssertTrue(discarded)
            let decisions = fixture.channel.decisions()
            XCTAssertEqual(decisions.count, 1)
            XCTAssertEqual(decisions.first?["decision"], .string("discard"))
            for payload in decisions { assertClosedIntent(payload) }
        }

        func testFailedDeliveryKeepsTheCardWithRetry() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let model = boundModel(fixture, owner)
            fixture.host.consume(try session(on: fixture))
            _ = try await startBackgroundJob(fixture)
            await model.handle(.disconnected(reason: "server restart"))
            model.decideOutcomeUnknown("acknowledge")
            let failed = try await waitUntil(model.outcomeUnknownCard?.delivery == .failed)
            XCTAssertTrue(
                failed,
                "an intent that cannot reach the server keeps the card on retry")
            XCTAssertEqual(fixture.channel.decisions().count, 0)
            XCTAssertNotNil(model.outcomeUnknownCard)
            XCTAssertNotNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            reconnect(fixture, model)
            model.retryOutcomeUnknown()
            let sent = try await waitUntil(
                model.outcomeUnknownCard?.decision == "acknowledge"
                    && model.outcomeUnknownCard?.delivery == .pending && fixture.channel.decisions().count == 1)
            XCTAssertTrue(sent)
            receiveOutcomeAck(fixture, model, decision: "acknowledge")
            let retried = try await waitUntil(model.outcomeUnknownCard == nil)
            XCTAssertTrue(retried)
            XCTAssertEqual(fixture.channel.decisions().count, 1)
            XCTAssertNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            XCTAssertTrue(fixture.host.uncertainJobs.isEmpty)
        }

        func testMissingServerReceiptKeepsDecisionRetryableUntilReceiptArrives() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let model = boundModel(fixture, owner)
            fixture.host.consume(try session(on: fixture))
            _ = try await startBackgroundJob(fixture)
            await model.handle(.disconnected(reason: "server restart"))
            reconnect(fixture, model)
            let timeout = AsyncStream<Void>.makeStream()
            model.outcomeAckWait = {
                for await _ in timeout.stream { break }
            }
            model.decideOutcomeUnknown("discard")
            let sent = try await waitUntil(
                model.outcomeUnknownCard?.decision == "discard"
                    && model.outcomeUnknownCard?.delivery == .pending && fixture.channel.decisions().count == 1)
            XCTAssertTrue(sent)
            timeout.continuation.yield(())
            let timedOut = try await waitUntil(model.outcomeUnknownCard?.delivery == .failed)
            XCTAssertTrue(timedOut)
            XCTAssertNotNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
            model.retryOutcomeUnknown()
            let retried = try await waitUntil(fixture.channel.decisions().count == 2)
            XCTAssertTrue(retried)
            XCTAssertNotNil(model.outcomeUnknownCard)
            receiveOutcomeAck(fixture, model, decision: "discard")
            XCTAssertNil(model.outcomeUnknownCard)
            XCTAssertNil(fixture.store.load(key: OutcomeUnknownStore.key(scope: scope(model, owner))))
        }

        func testCardControlsExposeAccessibleNamesAndStableIdentifiers() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let model = boundModel(fixture, owner)
            fixture.host.consume(try session(on: fixture))
            _ = try await startBackgroundJob(fixture)
            await model.handle(.disconnected(reason: "server restart"))
            XCTAssertNotNil(model.outcomeUnknownCard)
            let mount = SurfaceMount(MacOutcomeUnknownCardView(), model: model, size: CGSize(width: 560, height: 260))
            defer { mount.close() }
            try await mount.settle()
            let tree = try mount.accessibility
            let identifiers = tree.compactMap(\.identifier)
            for required in [
                "outcome-unknown-card", "outcome-unknown-title", "outcome-unknown-job-0",
                "outcome-unknown-inspect-0", "outcome-unknown-discard", "outcome-unknown-acknowledge",
            ] {
                XCTAssertTrue(identifiers.contains(required), "missing stable identifier \(required)")
            }
            let acknowledge = try XCTUnwrap(tree.first { $0.identifier == "outcome-unknown-acknowledge" })
            XCTAssertEqual(acknowledge.label, "Acknowledge and continue")
            let discard = try XCTUnwrap(tree.first { $0.identifier == "outcome-unknown-discard" })
            XCTAssertEqual(discard.label, "Discard")
            XCTAssertFalse(identifiers.contains("outcome-unknown-retry"), "retry appears only after a failed delivery")
        }

        func testRelaunchRestoresTheCardOnlyAsAStaleNonActionableBanner() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let owner = try account("owner-a")
            let probe = boundModel(fixture, owner)
            let key = OutcomeUnknownStore.key(scope: scope(probe, owner))
            XCTAssertTrue(
                fixture.store.save(
                    OutcomeUnknownRecord(
                        hostId: UUID().uuidString.lowercased(),
                        incarnationId: UUID().uuidString.lowercased(),
                        jobs: [
                            OutcomeUnknownRecordJob(
                                id: UUID().uuidString.lowercased(), state: "running", exitCode: nil,
                                signal: nil, outputBytes: 4096)
                        ]), key: key))
            let model = boundModel(fixture, owner)
            let card = try XCTUnwrap(model.outcomeUnknownCard, "the restored card explains the waiting chat")
            XCTAssertTrue(card.restored)
            XCTAssertNotEqual(card.incarnationId, fixture.host.incarnationId)
            XCTAssertFalse(model.outcomeUnknownCardActionable)
            let before = fixture.channel.decisions().count
            model.decideOutcomeUnknown("acknowledge")
            model.decideOutcomeUnknown("discard")
            XCTAssertEqual(fixture.channel.decisions().count, before, "a stale incarnation is never actionable")
            XCTAssertNil(model.outcomeUnknownCard?.decision)
        }

        func testAnotherAccountNeverSeesTheStoredCard() async throws {
            let fixture = try fixture()
            defer { fixture.close() }
            let ownerA = try account("owner-a")
            let ownerB = try account("owner-b")
            let probe = boundModel(fixture, ownerA)
            let key = OutcomeUnknownStore.key(scope: scope(probe, ownerA))
            XCTAssertTrue(
                fixture.store.save(
                    OutcomeUnknownRecord(
                        hostId: UUID().uuidString.lowercased(),
                        incarnationId: UUID().uuidString.lowercased(), jobs: []), key: key))
            let model = boundModel(fixture, ownerB)
            XCTAssertNil(model.outcomeUnknownCard)
            XCTAssertFalse(model.outcomeUnknownCardActionable)
            let before = fixture.channel.decisions().count
            model.decideOutcomeUnknown("acknowledge")
            XCTAssertEqual(fixture.channel.decisions().count, before)
        }
    }
#endif
