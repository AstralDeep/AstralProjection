// Verifies scheduled run retries keep one owner-scoped submission identity after an uncertain response.
// The server remains the authority for materialization and execution.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacScheduledWorkCenterTests: XCTestCase {
        private let jobID = "6d12ed1e-7485-4a76-8e94-9827b049fce8"

        private actor Requests {
            var submissions: [String] = []
            func record(_ value: String) -> Int {
                submissions.append(value)
                return submissions.count
            }
        }

        private func signedInModel(defaults: UserDefaults) async throws -> AppModel {
            let issuer = "https://iam.example.test/realms/astral"
            let claims: JSONValue = .object([
                "iss": .string(issuer), "sub": .string("schedule-owner"), "azp": .string("astraldeep-macos"),
                "exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ])
            let tokenStore = InMemoryTokenStore()
            tokenStore.save(
                StoredTokens(
                    from: TokenSet(
                        accessToken: "fixture." + PKCE.base64url(try claims.encoded()) + ".signature",
                        refreshToken: nil, expiresIn: 3600)))
            defaults.set("https://server.example.test", forKey: "serverBase")
            let model = AppModel(tokenStore: tokenStore, defaults: defaults)
            await model.bootstrap()
            model.connected = true
            return model
        }

        private func listResponse() throws -> Data {
            try JSONValue.object([
                "jobs": .array([
                    .object([
                        "id": .string(jobID), "name": .string("Daily research"),
                        "instruction": .string("Review the latest results"), "status": .string("active"),
                        "schedule_kind": .string("interval"), "schedule_expr": .string("1d"),
                        "timezone": .string("America/New_York"),
                        "consented_scopes": .array([.string("tools:read")]),
                        "next_run_at": .null, "last_run_at": .null,
                    ])
                ])
            ]).encoded()
        }

        private func scheduleJob(status: String) throws -> ScheduledWorkJob {
            try XCTUnwrap(
                ScheduledWorkJob(
                    json: .object([
                        "id": .string(jobID), "name": .string("Daily research"),
                        "instruction": .string("Review the latest results"), "status": .string(status),
                        "schedule_kind": .string("cron"), "schedule_expr": .string("0 9 * * *"),
                        "timezone": .string("America/New_York"), "consented_scopes": .array([]),
                        "next_run_at": .number(1_800_000_000_000), "last_run_at": .null,
                    ])))
        }

        func testNextRunDateIsPresentedOnlyForActiveSchedules() throws {
            let active = try scheduleJob(status: "active")
            let disabled = try scheduleJob(status: "disabled")

            XCTAssertNotNil(MacScheduledWorkCenter.nextRunDateText(for: active))
            XCTAssertNil(MacScheduledWorkCenter.nextRunDateText(for: disabled))
        }

        func testUncertainRunReplaysSameSubmissionAndPersistsAcrossStoreRecreation() async throws {
            let suite = "MacScheduledWorkCenterTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = try await signedInModel(defaults: defaults)
            let requests = Requests()
            let list = try listResponse()
            let jobID = self.jobID
            model.restTransportOverride = { request in
                if request.url?.path == "/api/schedule" { return (200, list) }
                let body = try JSONValue.parse(request.httpBody ?? Data())
                let submission = try XCTUnwrap(body["submission_id"]?.stringValue)
                let count = await requests.record(submission)
                if count == 1 { throw URLError(.timedOut) }
                let response = try JSONValue.object([
                    "job_id": .string(jobID), "submission_id": .string(submission),
                    "occurrence_id": .string("86b9785a-b852-4547-80f0-0d33f52e9f84"),
                    "duplicate": .bool(true),
                ]).encoded()
                return (202, response)
            }
            let intentStore = MacScheduledRunIntentStore(defaults: defaults)
            let first = MacScheduledWorkStore(model: model, updateRequired: false, runIntents: intentStore)
            await first.refresh()
            first.selectedID = jobID
            let selected = try XCTUnwrap(first.selected)
            await first.control(.runNow(submissionId: UUID()), expected: selected)
            XCTAssertTrue(first.unresolvedRun(for: selected))
            XCTAssertTrue(first.error?.contains("same request") == true)

            let resumed = MacScheduledWorkStore(model: model, updateRequired: false, runIntents: intentStore)
            await resumed.refresh()
            resumed.selectedID = jobID
            let resumedJob = try XCTUnwrap(resumed.selected)
            XCTAssertTrue(resumed.unresolvedRun(for: resumedJob))
            await resumed.control(.runNow(submissionId: UUID()), expected: resumedJob)
            let submissions = await requests.submissions
            XCTAssertEqual(submissions.count, 2)
            XCTAssertEqual(submissions.first, submissions.last)
            XCTAssertFalse(resumed.unresolvedRun(for: resumedJob))
            XCTAssertEqual(resumed.notice, "Run queued. Refresh to follow its state.")
            await model.signOut(revokeRemote: false)
        }

        func testRunIntentIsFencedByOwnerAndServer() async throws {
            let suite = "MacScheduledRunIntentTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = try await signedInModel(defaults: defaults)
            let store = MacScheduledRunIntentStore(defaults: defaults)
            let owner = model.downloadOwner
            let server = model.serverBase
            let submission = UUID()
            XCTAssertTrue(store.save(submission, jobID: jobID, owner: owner, server: server))
            XCTAssertEqual(store.load(jobID: jobID, owner: owner, server: server), submission)
            XCTAssertNil(
                store.load(
                    jobID: jobID, owner: owner,
                    server: URL(string: "https://other.example.test")!))
            model.bindConversationAccount(
                ConversationAccount(
                    issuer: "https://iam.example.test/realms/astral", subject: "another-owner")!)
            XCTAssertNil(store.load(jobID: jobID, owner: model.downloadOwner, server: server))
            XCTAssertTrue(store.clear(jobID: jobID, owner: owner, server: server))
            XCTAssertNil(store.load(jobID: jobID, owner: owner, server: server))
            await model.signOut(revokeRemote: false)
        }

        func testUnreadablePendingIntentRefusesNewRunBeforeTransport() async throws {
            let suite = "MacScheduledRunCorruptionTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = try await signedInModel(defaults: defaults)
            let intentStore = MacScheduledRunIntentStore(defaults: defaults)
            XCTAssertTrue(
                intentStore.save(
                    UUID(), jobID: jobID,
                    owner: model.downloadOwner, server: model.serverBase))
            let key = try XCTUnwrap(
                defaults.dictionaryRepresentation().keys.first {
                    $0.hasPrefix("astraldeep.schedule.run_now.v1.")
                })
            defaults.set("damaged", forKey: key)
            let list = try listResponse()
            model.restTransportOverride = { request in
                if request.url?.path == "/api/schedule" { return (200, list) }
                XCTFail("a damaged run marker must not send a new submission")
                return (503, Data())
            }
            let store = MacScheduledWorkStore(model: model, updateRequired: false, runIntents: intentStore)
            await store.refresh()
            store.selectedID = jobID
            let job = try XCTUnwrap(store.selected)
            await store.control(.runNow(submissionId: UUID()), expected: job)
            XCTAssertTrue(store.unresolvedRun(for: job))
            XCTAssertTrue(store.error?.contains("No new request") == true)
            await model.signOut(revokeRemote: false)
        }
    }
#endif
