import XCTest

@testable import AstralCore

final class WorkspaceAction088Tests: XCTestCase {
    private let base = URL(string: "https://astral.example.test")!

    func testOnlyClosedWorkspaceDescriptorsEnterTheOrderedInteractiveModel() throws {
        let good: JSONValue = .object([
            "key": .string("export"), "kind": .string("workspace_action"),
            "operation": .string("export_canvas"), "context": .string("live_canvas"),
            "label": .string("Export page"), "icon": .string("download"),
        ])
        var rows = [good]
        var share = good.objectValue!
        share["key"] = .string("share")
        share["operation"] = .string("share_canvas")
        share["label"] = .string("Share page")
        share["icon"] = .string("share")
        rows.append(.object(share))
        for (key, value): (String, JSONValue) in [
            ("context", .string("anywhere")), ("context", .null),
            ("operation", .string("delete_everything")), ("operation", .number(1)),
            ("action", .object(["surface": .string("admin_tools")])), ("action", .null),
            ("operation", .string("share_canvas")), ("label", .null), ("icon", .null),
            ("url", .string("https://foreign.test")), ("token", .null), ("payload", .object([:])),
        ] {
            var bad = good.objectValue!
            bad[key] = value
            rows.append(.object(bad))
        }
        rows.append(.object(["key": .string("future"), "kind": .string("future_action")]))
        let model = try XCTUnwrap(ChromeMenuModel.fromJSON(.object(["version": .number(2), "topbar": .array(rows)])))
        XCTAssertEqual(model.topbarActions.map(\.key), ["export", "share"])
        XCTAssertEqual(model.topbarActions.compactMap(\.workspaceAction), [.exportCanvas, .shareCanvas])
        XCTAssertTrue(model.topbarActions.allSatisfy { $0.action == nil })
    }

    func testPHIDenialHasOnlyTheClosedPublicExplanation() async {
        for (status, body, expected): (Int, String, WorkspaceShareError) in [
            (403, #"{"error":"phi_blocked","detail":"do not echo private detail"}"#, .phiBlocked),
            (404, #"{"error":"phi_blocked"}"#, .refused(status: 404)),
            (403, #"{"error":"other","detail":"private"}"#, .refused(status: 403)),
        ] {
            let client = RestClient(
                serverBase: base, tokenProvider: { "synthetic" },
                transport: { _ in
                    (status, Data(body.utf8))
                })
            do {
                _ = try await client.shareCanvas(chatId: "chat")
                XCTFail("Denied")
            } catch { XCTAssertEqual(error as? WorkspaceShareError, expected) }
        }
    }

    func testRealStreamingTransportBoundsDeclaredAndUnknownLengthResponses() async throws {
        let config = NoStoreHTTP.configuration()
        config.protocolClasses = [WorkspaceFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["exact", "declared", "streamed", "redirect"] {
            let request = NoStoreHTTP.request(url: base.appendingPathComponent(path), method: "POST")
            do {
                let (status, data) = try await WorkspaceRequestPolicy.response(request, session: session)
                if path == "exact" {
                    XCTAssertEqual(data.count, 16 * 1024)
                    XCTAssertEqual(status, 201)
                } else if path == "redirect" {
                    XCTAssertEqual(status, 307)
                } else {
                    XCTFail("Oversize response accepted")
                }
            } catch {
                XCTAssertTrue(["declared", "streamed"].contains(path))
                XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
            }
        }
        let cancelled = Task {
            try await WorkspaceRequestPolicy.response(NoStoreHTTP.request(url: base), session: session)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled request accepted")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testShareUsesOneAuthenticatedJSONPostAndResolvesOnlyTheReturnedLocalLink() async throws {
        let count = RequestCount()
        let client = RestClient(
            serverBase: base, tokenProvider: { "synthetic-token" },
            transport: { request in
                await count.increment()
                XCTAssertEqual(request.url?.absoluteString, "https://astral.example.test/api/share")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(
                    try JSONValue.parse(request.httpBody!),
                    .object(["chat_id": .string("chat"), "scope": .string("canvas")]))
                return (201, Data(#"{"share_url":"/share/synthetic-token_123"}"#.utf8))
            })
        let url = try await client.shareCanvas(chatId: "chat")
        XCTAssertEqual(url.absoluteString, "https://astral.example.test/share/synthetic-token_123")
        let calls = await count.value
        XCTAssertEqual(calls, 1)
    }

    func testDenialsAndUncertainMintAreNeverRetried() async {
        for status in [401, 403, 404, 409, 422, 500] {
            let count = RequestCount()
            let client = RestClient(
                serverBase: base, tokenProvider: { "synthetic" },
                transport: { _ in
                    await count.increment()
                    return (status, Data(#"{"error":"refused"}"#.utf8))
                })
            do {
                _ = try await client.shareCanvas(chatId: "chat")
                XCTFail("A denial must not become a share link")
            } catch { XCTAssertEqual(error as? WorkspaceShareError, .refused(status: status)) }
            let calls = await count.value
            XCTAssertEqual(calls, 1)
        }
        let count = RequestCount()
        let uncertain = RestClient(
            serverBase: base, tokenProvider: { "synthetic" },
            transport: { _ in
                await count.increment()
                throw URLError(.networkConnectionLost)
            })
        do {
            _ = try await uncertain.shareCanvas(chatId: "chat")
            XCTFail("An uncertain POST must remain uncertain")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let calls = await count.value
        XCTAssertEqual(calls, 1)
    }

    func testShareRefusesMissingCredentialMalformedAndOversizeResponses() async {
        let anonymous = RestClient(
            serverBase: base, tokenProvider: { nil },
            transport: { _ in
                XCTFail("Missing credentials must not start a request")
                return (201, Data())
            })
        do {
            _ = try await anonymous.shareCanvas(chatId: "chat")
            XCTFail("Anonymous share")
        } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        for data in [Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: 16 * 1024 + 1)] {
            let client = RestClient(serverBase: base, tokenProvider: { "synthetic" }, transport: { _ in (201, data) })
            do {
                _ = try await client.shareCanvas(chatId: "chat")
                XCTFail("Invalid response")
            } catch {}
        }
    }

    func testShareLinkRejectsForeignOriginsCredentialsRoutesAndEncodedTokens() throws {
        for raw in [
            "https://foreign.example.test/share/token", "https://astral.example.test:444/share/token",
            "http://astral.example.test/share/token", "https://user@astral.example.test/share/token",
            "/api/share/token", "/share/", "/share/token/extra", "/share/%74oken", "/share/token?x=1",
            "/share/token#anchor", "/share/token\n", "file:///share/token",
            "/share/" + String(repeating: "x", count: 257),
        ] {
            XCTAssertThrowsError(try WorkspaceRequestPolicy.shareURL(raw, relativeTo: base), raw)
        }
        XCTAssertEqual(
            try WorkspaceRequestPolicy.shareURL("https://astral.example.test:443/share/token", relativeTo: base).path,
            "/share/token")
    }

    func testMintRedirectDelegateRefusesEvenSameOriginReplay() {
        let session = URLSession(configuration: NoStoreHTTP.configuration())
        defer { session.invalidateAndCancel() }
        var request = NoStoreHTTP.request(url: base.appendingPathComponent("api/share"), method: "POST")
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request)
        let delegate = WorkspaceRedirectRefusal()
        let completed = expectation(description: "redirect refused")
        delegate.urlSession(
            session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: request
        ) { proposed in
            XCTAssertNil(proposed)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }
}

private final class WorkspaceFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let headers = path == "declared" ? ["Content-Length": "16385"] : [:]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: path == "redirect" ? 307 : 201,
            httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path != "declared" {
            client?.urlProtocol(
                self, didLoad: Data(repeating: 32, count: path == "streamed" ? 16 * 1024 + 1 : 16 * 1024))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RequestCount {
    var value = 0
    func increment() { value += 1 }
}
