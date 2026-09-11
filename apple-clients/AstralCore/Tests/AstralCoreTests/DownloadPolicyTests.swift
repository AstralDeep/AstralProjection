import XCTest

@testable import AstralCore

final class DownloadPolicyTests: XCTestCase {
    private let origin = URL(string: "https://astral.example.test")!

    func testAuthorizationRequiresExactOrigin() async throws {
        let client = RestClient(serverBase: origin, tokenProvider: { "owner-token" })
        for url in ["/api/export/canvas/chat.html", "https://astral.example.test:443/export"] {
            let request = try await client.downloadRequest(from: url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-token")
        }
        for url in ["https://files.example.test/file", "https://astral.example.test:444/file"] {
            let request = try await client.downloadRequest(from: url)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        for url in [
            "http://astral.example.test/file", "https://user:password@astral.example.test/file", "file:///private/file",
            "data:text/plain,no",
        ] {
            do {
                _ = try await client.downloadRequest(from: url)
                XCTFail("Unsafe download URL must be rejected")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badURL) }
        }
    }

    func testLocalHTTPRetainsExactPortBoundaryAndMissingTokenStaysAbsent() async throws {
        let client = RestClient(serverBase: URL(string: "http://localhost:8001")!, tokenProvider: { "local-token" })
        let own = try await client.downloadRequest(from: "/file")
        XCTAssertEqual(own.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
        let other = try await client.downloadRequest(from: "http://localhost:8002/file")
        XCTAssertNil(other.value(forHTTPHeaderField: "Authorization"))
        let anonymous = RestClient(serverBase: origin, tokenProvider: { nil })
        let request = try await anonymous.downloadRequest(from: "/file")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRedirectsCannotLeakBearerOrDowngradeAndPublicCDNRemainsUsable() throws {
        var authenticated = NoStoreHTTP.request(url: origin.appendingPathComponent("export"))
        authenticated.setValue("Bearer owner-token", forHTTPHeaderField: "Authorization")
        for destination in [
            "https://evil.example.test/file", "https://astral.example.test:444/file", "http://astral.example.test/file",
            "https://user@astral.example.test/file",
        ] {
            XCTAssertNil(DownloadPolicy.redirect(URLRequest(url: URL(string: destination)!), from: authenticated))
        }
        let same = try XCTUnwrap(
            DownloadPolicy.redirect(URLRequest(url: origin.appendingPathComponent("final")), from: authenticated))
        XCTAssertEqual(same.value(forHTTPHeaderField: "Authorization"), "Bearer owner-token")
        let publicRequest = NoStoreHTTP.request(url: URL(string: "https://github.com/assets/file")!)
        var redirect = URLRequest(url: URL(string: "https://objects.githubusercontent.com/file")!)
        redirect.setValue("Bearer inherited-token", forHTTPHeaderField: "Authorization")
        let safe = try XCTUnwrap(DownloadPolicy.redirect(redirect, from: publicRequest))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(safe.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(
            DownloadPolicy.redirect(
                URLRequest(url: URL(string: "http://public.example.test/file")!), from: publicRequest))
        XCTAssertNil(
            DownloadPolicy.redirect(URLRequest(url: origin), from: URLRequest(url: URL(string: "file:///tmp/x")!)))
    }

    func testRedirectDelegateRefusesCredentialedCrossOriginRequest() {
        var original = URLRequest(url: origin)
        original.setValue("Bearer private-token", forHTTPHeaderField: "Authorization")
        let delegate = DownloadRedirectDelegate(original: original)
        let session = URLSession(configuration: NoStoreHTTP.configuration())
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let completion = expectation(description: "redirect policy applied")
        delegate.urlSession(
            session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://evil.example.test")!)
        ) { result in
            XCTAssertNil(result)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
    }

    func testDownloadResponseSavesOnlyPrivateConfinedFilenameAndDenialThrows() async throws {
        let config = NoStoreHTTP.configuration()
        config.protocolClasses = [DownloadFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = RestClient(serverBase: origin, tokenProvider: { "owner-token" }, downloadSession: session)
        let file = try await client.downloadFile(from: "/download", suggestedFilename: "../../confined.csv")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "confined.csv")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "exported fixture")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let parent = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(parent[.posixPermissions] as? Int, 0o700)
        do {
            _ = try await client.downloadFile(from: "/oversize")
            XCTFail("Declared downloads larger than64MiB must be rejected")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        do {
            _ = try await client.downloadFile(from: "/denied")
            XCTFail("Authorization denial must not create a successful download")
        } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
    }

    func testFilenameCannotEscapePrivateTemporaryDirectory() {
        XCTAssertEqual(DownloadPolicy.filename("../../private/report.csv"), "report.csv")
        XCTAssertEqual(DownloadPolicy.filename("C:\\private\\report.csv"), "report.csv")
        XCTAssertEqual(DownloadPolicy.filename("\r\nreport\u{0000}:unsafe.csv"), "reportunsafe.csv")
        for name in ["", "/", ".", "..", "../../"] {
            XCTAssertEqual(DownloadPolicy.filename(name), "download")
        }
        XCTAssertEqual(DownloadPolicy.filename(String(repeating: "x", count: 500)).count, 180)
    }
}

private final class DownloadFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-token")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: request.url?.path == "/denied" ? 403 : 200,
            httpVersion: nil,
            headerFields: [
                "Content-Disposition": "attachment; filename=export.csv",
                "Content-Length": request.url?.path == "/oversize" ? "67108865" : "16",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("exported fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
