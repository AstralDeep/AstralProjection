import Foundation
import XCTest

@testable import AstralCore

final class ComponentActionRequestTests: XCTestCase {
    private let base = URL(string: "https://astral.example.test")!

    func testComponentShareUsesOnlyFixedEndpointAndExplicitScopeOnce() async throws {
        let count = ComponentRequestCounter()
        let client = RestClient(
            serverBase: base, tokenProvider: { "synthetic" },
            transport: { request in
                await count.increment()
                XCTAssertEqual(request.url?.absoluteString, "https://astral.example.test/api/share")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                XCTAssertEqual(
                    try JSONValue.parse(request.httpBody!),
                    .object([
                        "chat_id": .string("chat"), "scope": .string("component"),
                        "component_id": .string("saved/table"),
                    ]))
                return (201, Data(#"{"share_url":"/share/synthetic_123"}"#.utf8))
            })
        let url = try await client.shareComponent(chatId: "chat", componentId: "saved/table")
        XCTAssertEqual(url.absoluteString, "https://astral.example.test/share/synthetic_123")
        let calls = await count.value
        XCTAssertEqual(calls, 1)
    }

    func testComponentShareDenialAndUncertainResponseNeverRetry() async throws {
        for status in [403, 409, 503] {
            let count = ComponentRequestCounter()
            let client = RestClient(
                serverBase: base, tokenProvider: { "synthetic" },
                transport: { _ in
                    await count.increment()
                    return (status, Data(#"{"error":"phi_blocked","detail":"PRIVATE"}"#.utf8))
                })
            do {
                _ = try await client.shareComponent(chatId: "chat", componentId: "saved")
                XCTFail("Denied component share accepted")
            } catch {
                XCTAssertEqual(error as? WorkspaceShareError, status == 403 ? .phiBlocked : .refused(status: status))
            }
            let calls = await count.value
            XCTAssertEqual(calls, 1)
        }
        let count = ComponentRequestCounter()
        let client = RestClient(
            serverBase: base, tokenProvider: { "synthetic" },
            transport: { _ in
                await count.increment()
                throw URLError(.networkConnectionLost)
            })
        do {
            _ = try await client.shareComponent(chatId: "chat", componentId: "saved")
            XCTFail("Uncertain mint")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let calls = await count.value
        XCTAssertEqual(calls, 1)
    }

    func testComponentCSVEncodesOneSegmentAndRequiresFreshCredential() async throws {
        let client = RestClient(serverBase: base, tokenProvider: { "synthetic" })
        let request = try await client.componentCSVRequest(chatId: "chat&other=bad", componentId: "a/b?c#d%2f")
        let parts = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.percentEncodedPath, "/api/export/component/a%2Fb%3Fc%23d%252f.csv")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "chat_id", value: "chat&other=bad")])
        XCTAssertNil(parts.fragment)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        for credential: String? in [nil, ""] {
            let anonymous = RestClient(serverBase: base, tokenProvider: { credential })
            do {
                _ = try await anonymous.componentCSVRequest(chatId: "chat", componentId: "saved")
                XCTFail("Anonymous CSV")
            } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        }
    }

    func testComponentOperationsRejectMalformedIdentityWithoutCredentialOrNetwork() async {
        let client = RestClient(
            serverBase: base,
            tokenProvider: {
                XCTFail("Invalid identity reached credential lookup")
                return nil
            })
        for identity in ["", String(repeating: "x", count: 257)] {
            do {
                _ = try await client.componentCSVRequest(chatId: "chat", componentId: identity)
                XCTFail("Invalid CSV identity")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badURL) }
            do {
                _ = try await client.shareComponent(chatId: "chat", componentId: identity)
                XCTFail("Invalid Share identity")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badURL) }
        }
    }

    func testComponentCSVActualWriterIsPrivateAndDenialsProduceNoFile() async throws {
        let configuration = NoStoreHTTP.configuration()
        configuration.protocolClasses = [ComponentCSVProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RestClient(serverBase: base, tokenProvider: { "synthetic" }, downloadSession: session)
        let file = try await client.downloadComponentCSV(chatId: "chat", componentId: "golden")
        defer { RestClient.removeTemporaryDownload(file) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "label,value\nAlpha,2\n")
        XCTAssertEqual(file.lastPathComponent, "astraldeep-table.csv")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber)?.intValue, 0o700)
        for identity in ["denied", "redirect", "oversize"] {
            do {
                _ = try await client.downloadComponentCSV(chatId: "chat", componentId: identity)
                XCTFail("Invalid response produced file")
            } catch {
                XCTAssertEqual(
                    (error as? URLError)?.code, identity == "oversize" ? .dataLengthExceedsMaximum : .badServerResponse)
            }
        }
    }

    func testComponentSocketRequiresEstablishedConnectionAndClosedAction() async {
        let client = WSClient(url: URL(string: "ws://127.0.0.1:9/ws")!)
        let identity = ClientOperationIdentity.fresh()
        for action in ["component_refine", "component_restore", "delete_everything"] {
            let frame = Outbound.uiEvent(
                action: action, sessionId: "11111111-1111-4111-8111-111111111111",
                payload: .object(["component_id": .string("saved")]),
                submissionId: identity.submissionId, requestGeneration: identity.requestGeneration)
            let sent = await client.sendCurrentComponentEvent(frame) {
                XCTFail("Disconnected socket must refuse before invoking a context callback")
                return true
            }
            XCTAssertFalse(sent)
        }
        let malformed = await client.sendCurrentComponentEvent("{}") { true }
        XCTAssertFalse(malformed)
        await client.stop()
    }
}

private actor ComponentRequestCounter {
    var value = 0
    func increment() { value += 1 }
}

private final class ComponentCSVProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let status = path == "denied.csv" ? 403 : path == "redirect.csv" ? 307 : 200
        let fields = path == "oversize.csv" ? ["Content-Length": String(64 * 1024 * 1024 + 1)] : [:]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("label,value\nAlpha,2\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
