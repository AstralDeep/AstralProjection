import AstralCore
import Network
import XCTest

@testable import AstralDeep

@MainActor
final class WorkspaceExportPipeline088Tests: XCTestCase {
    private func withModel(
        authorizationStatus: Int = 200,
        presentationStatus: Int = 200,
        body: (AppModel, WorkspaceExportLoopback) async throws -> Void
    ) async throws {
        let server = try WorkspaceExportLoopback(
            authorizationStatus: authorizationStatus, presentationStatus: presentationStatus)
        server.start()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port)
        let suite = "WorkspaceExportPipeline088.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://127.0.0.1:\(port.rawValue)", forKey: "serverBase")
        let store = InMemoryTokenStore()
        store.save(StoredTokens(from: TokenSet(accessToken: server.token, refreshToken: nil, expiresIn: 3600)))
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: store, defaults: defaults)
        await model.bootstrap()
        model.activeChatId = "11111111-1111-4111-8111-111111111111"
        model.canvas = [
            AstralComponent(
                type: "text",
                raw: .object([
                    "content": .string("Visible pipeline result"), "title": .string("PRIVATE_UNUSED_TITLE"),
                    "_source_params": .object(["token": .string("PRIVATE_UNUSED_TOKEN")]),
                ]))
        ]
        model.chromeMenu = ChromeMenuModel.fromJSON(
            try JSONValue.parse(
                Data(
                    #"{"version":2,"topbar":[{"key":"export","kind":"workspace_action","label":"Export page","icon":"download","operation":"export_canvas","context":"live_canvas"}]}"#
                        .utf8)))
        model.canvasCapture.setWindow(CGSize(width: 320, height: 700))
        model.canvasCapture.setCanvas(CGSize(width: 296, height: 480), palette: .midnight)
        do {
            try await body(model, server)
            await model.signOut(revokeRemote: false)
        } catch {
            await model.signOut(revokeRemote: false)
            throw error
        }
        XCTAssertNil(store.load())
    }

    func testProductionAuthorizationCapturePostWebKitAndPrivateFilePipeline() async throws {
        try await withModel { model, server in
            let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
            let file = try await model.downloadWorkspaceCanvas(context)
            defer { RestClient.removeTemporaryDownload(file) }
            let html = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(html.contains("Visible pipeline result"))
            XCTAssertTrue(html.contains("data:font/woff2;base64,"))
            XCTAssertTrue(html.contains("script-src 'none'"))
            XCTAssertFalse(html.contains("<script"))
            XCTAssertFalse(html.contains("AUTHORIZATION_ONLY_HTML"))
            XCTAssertFalse(html.contains("PRIVATE_UNUSED"))
            XCTAssertEqual(server.methods, ["GET", "POST"])
            XCTAssertTrue(server.authorizationHeaders.allSatisfy { $0 == "Bearer \(server.token)" })
            let capture = try JSONValue.parse(XCTUnwrap(server.capture))
            XCTAssertEqual(capture["components"]?.arrayValue?.first?["content"], .string("Visible pipeline result"))
            XCTAssertEqual(capture["viewport"]?["width"], .number(296))
            XCTAssertFalse(String(decoding: try XCTUnwrap(server.capture), as: UTF8.self).contains("PRIVATE_UNUSED"))
            XCTAssertFalse(model.workspaceActionInFlight(.exportCanvas))
        }
    }

    func testAuthorizationRefusalNeverCapturesPostsOrCreatesAnOfflineFile() async throws {
        try await withModel(authorizationStatus: 403) { model, server in
            let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
            do {
                let file = try await model.downloadWorkspaceCanvas(context)
                RestClient.removeTemporaryDownload(file)
                XCTFail("Denied authorization created a file")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(server.methods, ["GET"])
            XCTAssertNil(server.capture)
            XCTAssertFalse(model.workspaceActionInFlight(.exportCanvas))
        }
    }

    func testPresentationRefusalDoesNotFallBackToAuthorizationHTML() async throws {
        try await withModel(presentationStatus: 409) { model, server in
            let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
            do {
                let file = try await model.downloadWorkspaceCanvas(context)
                RestClient.removeTemporaryDownload(file)
                XCTFail("Denied presentation fell back to static authorization HTML")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(server.methods, ["GET", "POST"])
            XCTAssertFalse(model.workspaceActionInFlight(.exportCanvas))
        }
    }
}

/// Test-only HTTP peer. Real client transports and WebKit run unchanged; no
/// global URLProtocol, user defaults, Keychain, IdP or external host is used.
private final class WorkspaceExportLoopback: @unchecked Sendable {
    let ready = XCTestExpectation(description: "workspace export loopback ready")
    let listener: NWListener
    let token =
        "fixture." + Data(#"{"iss":"https://issuer.invalid","sub":"fixture"}"#.utf8).base64EncodedString() + ".fixture"
    private let queue = DispatchQueue(label: "astral.workspace-export.loopback")
    private let authorizationStatus: Int
    private let presentationStatus: Int
    private var connections: [NWConnection] = []
    private var observedMethods: [String] = []
    private var observedAuthorization: [String] = []
    private var observedCapture: Data?

    init(authorizationStatus: Int, presentationStatus: Int) throws {
        self.authorizationStatus = authorizationStatus
        self.presentationStatus = presentationStatus
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var methods: [String] { queue.sync { observedMethods } }
    var authorizationHeaders: [String] { queue.sync { observedAuthorization } }
    var capture: Data? { queue.sync { observedCapture } }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var request = accumulated
            request.append(data ?? Data())
            guard request.count < 1024 * 1024 else {
                connection.cancel()
                return
            }
            if let boundary = request.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let fields = Dictionary(
                    lines.dropFirst().compactMap { line -> (String, String)? in
                        guard let colon = line.firstIndex(of: ":") else { return nil }
                        return (
                            line[..<colon].lowercased(),
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        )
                    }, uniquingKeysWith: { first, _ in first })
                let length = Int(fields["content-length"] ?? "0") ?? 0
                guard length >= 0, length < 1024 * 1024 else {
                    connection.cancel()
                    return
                }
                if request.count >= boundary.upperBound + length {
                    self.respond(
                        connection, firstLine: lines[0], headers: fields,
                        body: request.subdata(in: boundary.upperBound..<(boundary.upperBound + length)))
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, accumulated: request) }
        }
    }

    private func respond(_ connection: NWConnection, firstLine: String, headers: [String: String], body: Data) {
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        var status = 404
        var response = Data()
        if path.hasPrefix("/api/export/canvas/") {
            observedMethods.append(method)
            observedAuthorization.append(headers["authorization"] ?? "")
            status = method == "GET" ? authorizationStatus : presentationStatus
            if method == "GET" { response = Data("AUTHORIZATION_ONLY_HTML".utf8) }
            if method == "POST" {
                observedCapture = body
                if let capture = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let viewport = capture["viewport"], let theme = capture["theme"]
                {
                    response =
                        (try? JSONSerialization.data(withJSONObject: [
                            "version": CanvasExportPolicy.version, "viewport": viewport, "theme": theme,
                            "html": "<div class=\"dynamic-renderer\"><p>Visible pipeline result</p></div>",
                        ])) ?? Data()
                }
            }
        }
        let header =
            "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(response.count)\r\nX-Astral-Render-Revision: 0\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
