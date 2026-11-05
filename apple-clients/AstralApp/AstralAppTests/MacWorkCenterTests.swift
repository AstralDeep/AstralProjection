// Verifies Work operation parsing, authenticated request boundaries, and signed-out owner fencing.
// These tests exercise the native Mac convenience surface without replacing server state authority.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacWorkCenterTests: XCTestCase {
        private let operation = "66666666-6666-4666-8666-666666666666"

        private func operationJSON(
            id: String? = nil, revision: Double = 4, disposition: String = "active"
        ) -> JSONValue {
            .object([
                "id": .string(id ?? operation), "revision": .number(revision), "title": .string("Work"),
                "disposition": .string(disposition), "phase": .string("run"), "usage": .object([:]),
            ])
        }

        func testParsesServerOperationAndDerivesSafeControls() throws {
            let operation = try XCTUnwrap(
                MacWorkOperation(
                    json: JSONValue.parse(
                        Data(
                            #"{"id":"66666666-6666-4666-8666-666666666666","revision":4,"title":"Scheduled review","disposition":"paused","phase":"waiting","created_at":null,"updated_at":"2026-11-04T12:00:00+00:00","next_wake_at":"2026-11-04T13:00:00+00:00","safe_error_code":null,"usage":{"spent":{"tokens":120}}}"#
                                .utf8))))
            XCTAssertEqual(operation.revision, 4)
            XCTAssertTrue(operation.canResume)
            XCTAssertFalse(operation.canPause)
            XCTAssertTrue(operation.canCancel)
            XCTAssertEqual(operation.nextWakeAt, "2026-11-04T13:00:00+00:00")
        }

        func testRejectsMalformedIdentityAndRevision() {
            for pair in [("66666666-6666-4666-8666-66666666666x", 1), (operation, 0), (operation, 1.5)] {
                let payload: JSONValue = .object([
                    "id": .string(pair.0), "revision": .number(pair.1), "title": .string("Work"),
                    "disposition": .string("active"), "phase": .string("run"), "usage": .object([:]),
                ])
                XCTAssertNil(MacWorkOperation(json: payload))
            }
        }

        func testUnknownDispositionNeverEnablesControls() throws {
            let item = try XCTUnwrap(MacWorkOperation(json: operationJSON(disposition: "future_state")))
            XCTAssertFalse(item.canPause)
            XCTAssertFalse(item.canResume)
            XCTAssertFalse(item.canCancel)
            XCTAssertTrue(MacWorkFilter.all.includes(item))
            XCTAssertFalse(MacWorkFilter.active.includes(item))
        }

        func testStatusFiltersGroupAuthoritativeDispositions() throws {
            let active = try XCTUnwrap(MacWorkOperation(json: operationJSON(disposition: "awaiting_event")))
            let paused = try XCTUnwrap(MacWorkOperation(json: operationJSON(disposition: "paused")))
            let failed = try XCTUnwrap(MacWorkOperation(json: operationJSON(disposition: "failed")))
            let blocked = try XCTUnwrap(MacWorkOperation(json: operationJSON(disposition: "budget_blocked")))
            XCTAssertTrue(MacWorkFilter.active.includes(active))
            XCTAssertTrue(MacWorkFilter.paused.includes(paused))
            XCTAssertTrue(MacWorkFilter.completed.includes(failed))
            XCTAssertTrue(MacWorkFilter.attention.includes(blocked))
        }

        func testControlReceiptRequiresMatchingIdentityAndAdvancedAppliedRevision() throws {
            let applied: JSONValue = .object(["operation": operationJSON(revision: 5), "applied": .bool(true)])
            let replay: JSONValue = .object(["operation": operationJSON(), "applied": .bool(false)])
            XCTAssertEqual(
                MacWorkControlReceipt(json: applied, expectedId: operation, expectedRevision: 4)?.operation.revision,
                5)
            XCTAssertNotNil(MacWorkControlReceipt(json: replay, expectedId: operation, expectedRevision: 4))
            XCTAssertNil(
                MacWorkControlReceipt(
                    json: .object([
                        "operation": operationJSON(id: "77777777-7777-4777-8777-777777777777", revision: 5),
                        "applied": .bool(true),
                    ]),
                    expectedId: operation, expectedRevision: 4))
            XCTAssertNil(
                MacWorkControlReceipt(
                    json: .object(["operation": operationJSON(revision: 4), "applied": .bool(true)]),
                    expectedId: operation, expectedRevision: 4))
            XCTAssertNil(
                MacWorkControlReceipt(
                    json: .object(["operation": operationJSON(revision: 3), "applied": .bool(false)]),
                    expectedId: operation, expectedRevision: 4))
        }

        func testResultPresentationUsesBoundedReadableFields() throws {
            let passage: JSONValue = .object([
                "id": .string("p001"), "text": .string(String(repeating: "evidence ", count: 500)),
            ])
            let content: JSONValue = .object([
                "version": .number(1), "scope": .string("one_page_excerpts"),
                "disposition": .string("evidence"),
                "source": .object([
                    "title": .string("Research source"), "requested_url": .string("https://example.test/article"),
                    "private_digest": .string(String(repeating: "a", count: 64)),
                ]),
                "passages": .array([passage]),
            ])
            let response: JSONValue = .object([
                "id": .string(operation), "revision": .number(5),
                "result": .object([
                    "version": .number(1), "available": .bool(true), "reason": .null, "content": content,
                ]),
            ])
            let presentation = try XCTUnwrap(
                MacWorkResultPresentation(json: response, operationId: operation, minimumRevision: 4))
            XCTAssertEqual(presentation.fields.map(\.label), ["Summary", "Source", "URL", "Excerpt 1 · p001"])
            XCTAssertEqual(presentation.fields[0].value, "Evidence found")
            XCTAssertEqual(presentation.fields[3].value.count, 4000)
            XCTAssertFalse(presentation.fields.contains(where: { $0.label.contains("digest") }))
            XCTAssertNil(MacWorkResultPresentation(json: response, operationId: operation, minimumRevision: 6))
        }

        func testWorkRequestSendsBearerAndRevisionFencedControlBody() async throws {
            let expectedBody: JSONValue = .object([
                "expected_revision": .number(4),
                "submission_id": .string("f9f8a6e3-ec18-4d7c-b57d-403091ca52b8"),
            ])
            let client = RestClient(
                serverBase: URL(string: "https://astral.example")!, tokenProvider: { "owner-token" },
                transport: { request in
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-token")
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.url?.path, "/api/work/v1/operations/\(self.operation)/pause")
                    XCTAssertEqual(try? JSONValue.parse(request.httpBody ?? Data()), expectedBody)
                    return (409, Data(#"{"error":"assignment_revision_conflict"}"#.utf8))
                })
            let (status, json) = try await client.workOperationsRequest(
                "POST", operation + "/pause", body: expectedBody)
            XCTAssertEqual(status, 409)
            XCTAssertEqual(json["error"]?.stringValue, "assignment_revision_conflict")
        }

        func testWorkRequestRejectsUntrustedPathBeforeTransport() async {
            let client = RestClient(
                serverBase: URL(string: "https://astral.example")!, tokenProvider: { "owner-token" },
                transport: { _ in
                    XCTFail("invalid path must not reach transport")
                    return (200, Data())
                })
            do {
                _ = try await client.workOperationsRequest("POST", "../other", body: .object([:]))
                XCTFail("path traversal should be rejected")
            } catch {}
        }

        func testWorkRequestRequiresAuthenticationAndRejectsTokenQuery() async {
            let client = RestClient(
                serverBase: URL(string: "https://astral.example")!, tokenProvider: { nil },
                transport: { _ in
                    XCTFail("unauthenticated Work must not reach transport")
                    return (200, Data())
                })
            do {
                _ = try await client.workOperationsRequest("GET")
                XCTFail("Work reads require the authenticated session")
            } catch {}

            let authenticated = RestClient(
                serverBase: URL(string: "https://astral.example")!, tokenProvider: { "owner-token" },
                transport: { _ in
                    XCTFail("token query must be rejected")
                    return (200, Data())
                })
            do {
                _ = try await authenticated.workOperationsRequest(
                    "GET", queryItems: [URLQueryItem(name: "token", value: "must-not-leak")])
                XCTFail("credentials must not be sent in the query")
            } catch {}
        }

        func testSignedOutWorkCenterDoesNotIssueRequests() async {
            let model = AppModel(tokenStore: InMemoryTokenStore())
            model.restTransportOverride = { _ in
                XCTFail("signed-out Work must not issue requests")
                return (200, Data())
            }
            let store = MacWorkCenterStore(model: model)
            await store.refresh()
            XCTAssertTrue(store.operations.isEmpty)
            XCTAssertNil(store.selected)
        }

        func testSignOutClearsLoadedSelectionAndResultState() async throws {
            let issuer = "https://iam.example.test/realms/astral"
            let claims: JSONValue = .object([
                "iss": .string(issuer), "sub": .string("work-owner"), "azp": .string("astraldeep-macos"),
                "exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ])
            let tokenStore = InMemoryTokenStore()
            tokenStore.save(
                StoredTokens(
                    from: TokenSet(
                        accessToken: "fixture." + PKCE.base64url(try claims.encoded()) + ".signature",
                        refreshToken: nil, expiresIn: 3600)))
            let suite = "MacWorkCenterSignOutTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set("https://server.example.test", forKey: "serverBase")
            let model = AppModel(tokenStore: tokenStore, defaults: defaults)
            await model.bootstrap()
            let row = operationJSON()
            model.restTransportOverride = { request in
                switch request.url?.path {
                case "/api/work/v1/operations":
                    return (200, (try? JSONValue.object(["operations": .array([row])]).encoded()) ?? Data())
                case "/api/work/v1/operations/\(self.operation)":
                    return (200, (try? JSONValue.object(["operation": row]).encoded()) ?? Data())
                case "/api/work/v1/operations/\(self.operation)/result":
                    let response: JSONValue = .object([
                        "id": .string(self.operation), "revision": .number(4),
                        "result": .object([
                            "version": .number(1), "available": .bool(true), "reason": .null,
                            "content": .object([
                                "version": .number(1), "scope": .string("one_page_excerpts"),
                                "disposition": .string("insufficient_evidence"),
                                "source": .object([
                                    "title": .string("Saved source"), "requested_url": .string("https://example.test"),
                                ]),
                                "passages": .array([]),
                            ]),
                        ]),
                    ])
                    return (200, (try? response.encoded()) ?? Data())
                default: return (404, Data())
                }
            }
            let store = MacWorkCenterStore(model: model)
            await store.refresh()
            guard let item = store.operations.first else { return XCTFail("expected operation row") }
            await store.select(item)
            XCTAssertNotNil(store.selected)
            XCTAssertNotNil(store.result)
            store.signedOut()
            XCTAssertTrue(store.operations.isEmpty)
            XCTAssertNil(store.selected)
            XCTAssertNil(store.result)
            XCTAssertFalse(store.loading)
            await model.signOut(revokeRemote: false)
            defaults.removePersistentDomain(forName: suite)
        }

        func testScopedRestRejectsRetiredOwnerAndServerBeforeTransport() async throws {
            let issuer = "https://iam.example.test/realms/astral"
            let claims: JSONValue = .object([
                "iss": .string(issuer), "sub": .string("work-owner"), "azp": .string("astraldeep-macos"),
                "exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ])
            let access = "fixture." + PKCE.base64url(try claims.encoded()) + ".signature"
            let tokenStore = InMemoryTokenStore()
            tokenStore.save(StoredTokens(from: TokenSet(accessToken: access, refreshToken: nil, expiresIn: 3600)))
            let suite = "MacWorkCenterTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set("https://server.example.test", forKey: "serverBase")
            let model = AppModel(tokenStore: tokenStore, defaults: defaults)
            await model.bootstrap()
            XCTAssertTrue(model.signedIn)
            let counter = WorkRequestCounter()
            model.restTransportOverride = { _ in
                await counter.increment()
                return (200, Data(#"{"operations":[]}"#.utf8))
            }

            let account = ConversationAccount(issuer: issuer, subject: "work-owner")!
            let capturedOwner = model.downloadOwner
            let capturedServer = model.serverBase
            let ownerScoped = model.scopedRest(owner: capturedOwner, server: capturedServer)
            model.bindConversationAccount(ConversationAccount(issuer: issuer, subject: "another-owner")!)
            do {
                _ = try await ownerScoped.authenticatedRequest("GET", "api/work/v1/operations")
                XCTFail("retired owner request should fail before transport")
            } catch {}

            model.bindConversationAccount(account)
            let serverScoped = model.scopedRest(owner: model.downloadOwner, server: model.serverBase)
            model.serverBaseText = "https://new-server.example.test"
            do {
                _ = try await serverScoped.authenticatedRequest("GET", "api/work/v1/operations")
                XCTFail("retired server request should fail before transport")
            } catch {}
            let requestCount = await counter.count
            XCTAssertEqual(requestCount, 0)
            await model.signOut(revokeRemote: false)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private actor WorkRequestCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }
#endif
