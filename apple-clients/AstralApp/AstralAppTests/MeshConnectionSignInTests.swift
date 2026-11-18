// Verifies the connection sign-in driver with a fake browser session: it opens the Kernel's URL, passes the callback through verbatim and cancels open flows.
// Also checks the attention text, the plain-text refusals and that all three entitlement files declare both associated domains.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class MeshConnectionSignInTests: XCTestCase {
    private static let guarded = "https://guarded.example/mcp"

    private final class FakeSession: MeshWebAuthSession {
        var started = false
        var cancelled = false
        let canStart: Bool
        init(canStart: Bool = true) { self.canStart = canStart }
        func start() -> Bool {
            started = true
            return canStart
        }
        func cancel() { cancelled = true }
    }

    private final class Browser {
        var openedURL: URL?
        var session = FakeSession()
        var complete: (@MainActor (Result<URL, MeshWebAuthFailure>) -> Void)?
        var respond: ((URL) -> Result<URL, MeshWebAuthFailure>?)?

        lazy var factory: MeshWebAuthSessionFactory = { [unowned self] url, completion in
            openedURL = url
            complete = completion
            if let answer = respond?(url) {
                Task { @MainActor in completion(answer) }
            }
            return session
        }
    }

    private func guardedConnection(_ h: MeshRuntimeHarness) async throws -> MeshConnection {
        await h.runtime.open()
        h.kernel.connectionBook.registerServer(
            Self.guarded, .init(issuer: "https://issuer.example", scopes: ["read"]))
        let proposal = try await h.runtime.proposeConnection(endpoint: Self.guarded, name: "Guarded", local: false)
        return try await h.runtime.approveConnection(proposal: proposal.proposal, flow: "private", toolNames: [])
    }

    private func state(in url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
    }

    func testBeginOpensTheKernelURLAndTheCallbackReachesCompleteVerbatim() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        let connection = try await guardedConnection(h)
        let browser = Browser()
        var sent = ""
        browser.respond = { [unowned self] url in
            sent = ConnectionCallback.redirectURL + "?state=" + state(in: url) + "&code=opaque-code%2B1"
            return .success(URL(string: sent)!)
        }
        let model = MeshConnectionSignIn(
            service: h.runtime, availability: .available, makeSession: browser.factory)
        await model.signIn(connection: connection.id)
        XCTAssertEqual(browser.openedURL?.host, "issuer.example")
        XCTAssertTrue(browser.session.started)
        XCTAssertEqual(model.phase, .signedIn(toolsPending: false))
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.connections.first?.thisDevice.state, "signed_in")
        XCTAssertFalse(model.phase.description.contains("opaque-code"))
        XCTAssertFalse(sent.isEmpty)
    }

    func testTheCallbackStringIsHandedOverUnchanged() async {
        let service = RecordingSignInService()
        let browser = Browser()
        let callback = ConnectionCallback.redirectURL + "?code=a%20b&state=s#frag"
        browser.respond = { _ in .success(URL(string: callback)!) }
        let model = MeshConnectionSignIn(service: service, availability: .available, makeSession: browser.factory)
        await model.signIn(connection: "c1")
        XCTAssertEqual(service.completed, [callback])
        XCTAssertTrue(service.cancelled.isEmpty)
    }

    func testCancelCallsCancelConnectionSignIn() async throws {
        let service = RecordingSignInService()
        let browser = Browser()
        browser.respond = { _ in .failure(.cancelled) }
        let model = MeshConnectionSignIn(service: service, availability: .available, makeSession: browser.factory)
        await model.signIn(connection: "c1")
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(service.cancelled, ["flow-1"])
        XCTAssertTrue(service.completed.isEmpty)
    }

    func testCancelFromTheAppClosesTheSessionAndTheFlow() async throws {
        let service = RecordingSignInService()
        let browser = Browser()
        let model = MeshConnectionSignIn(service: service, availability: .available, makeSession: browser.factory)
        let running = Task { await model.signIn(connection: "c1") }
        while model.phase != .waiting { await Task.yield() }
        model.cancel()
        await running.value
        XCTAssertTrue(browser.session.cancelled)
        XCTAssertEqual(service.cancelled, ["flow-1"])
        XCTAssertEqual(model.phase, .cancelled)
    }

    func testAForeignCallbackIsRefusedAndNeverCompleted() async {
        let service = RecordingSignInService()
        let browser = Browser()
        browser.respond = { _ in .success(URL(string: "https://evil.example/oauth/callback?code=x&state=s")!) }
        let model = MeshConnectionSignIn(service: service, availability: .available, makeSession: browser.factory)
        await model.signIn(connection: "c1")
        XCTAssertTrue(service.completed.isEmpty)
        XCTAssertEqual(service.cancelled, ["flow-1"])
        guard case .failed(let text) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertFalse(text.contains("evil.example"))
    }

    func testASessionThatCannotStartFails() async {
        let service = RecordingSignInService()
        let browser = Browser()
        browser.session = FakeSession(canStart: false)
        let model = MeshConnectionSignIn(service: service, availability: .available, makeSession: browser.factory)
        await model.signIn(connection: "c1")
        XCTAssertEqual(service.cancelled, ["flow-1"])
        guard case .failed = model.phase else { return XCTFail("expected a failure") }
    }

    func testAnOldSystemShowsThePlainRefusalWithoutBeginning() async {
        let service = RecordingSignInService()
        let browser = Browser()
        let model = MeshConnectionSignIn(
            service: service, availability: .unavailable(code: "connection.os_too_old"), makeSession: browser.factory)
        await model.signIn(connection: "c1")
        XCTAssertEqual(model.phase, .failed(KernelMapping.failureText(code: "connection.os_too_old")))
        XCTAssertEqual(service.begun, 0)
        XCTAssertNil(browser.openedURL)
    }

    func testKernelRefusalsReadAsPlainText() async {
        let service = RecordingSignInService()
        service.beginError = KernelMapping.refusal("connection.local_elsewhere")
        let model = MeshConnectionSignIn(
            service: service, availability: .available, makeSession: Browser().factory)
        await model.signIn(connection: "c1")
        XCTAssertEqual(model.phase, .failed("This local server can only be used on the device that added it."))
        let codes = [
            "connection.iss_mismatch", "connection.iss_missing", "oauth.state_mismatch", "connection.no_client_id",
        ]
        for code in codes {
            XCTAssertFalse(KernelMapping.failureText(code: code).contains(code), code)
        }
    }

    func testAttentionTextIsShortAndPerReason() {
        XCTAssertEqual(
            MeshConnectionAttentionFacts.text(reason: "scope"), "Needs more permissions. Review them to continue.")
        XCTAssertEqual(MeshConnectionAttentionFacts.text(reason: "expired"), "Your sign-in ended. Sign in again.")
        XCTAssertEqual(MeshConnectionAttentionFacts.text(reason: nil), "Needs you to sign in again.")
    }

    func testAttentionFactsComeOnlyFromTheKernelFlag() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        let connection = try await guardedConnection(h)
        XCTAssertNil(MeshConnectionAttentionFacts(connection))
        let flagged = MeshConnectionTestSupport.with(connection, here: "needs_attention", others: [])
        let facts = try XCTUnwrap(MeshConnectionAttentionFacts(flagged))
        XCTAssertEqual(facts.id, connection.id)
        XCTAssertEqual(MeshConnectionAttentionFacts.all([connection, flagged]).count, 1)
    }

    func testAllThreeEntitlementFilesDeclareBothAssociatedDomains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["AstralApp-iOS", "AstralApp-macOS", "AstralApp-DirectDownload"] {
            let data = try Data(contentsOf: root.appendingPathComponent(name + ".entitlements"))
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let domains = try XCTUnwrap(plist["com.apple.developer.associated-domains"] as? [String], name)
            XCTAssertTrue(domains.contains("applinks:astraldeep.github.io"), name)
            XCTAssertTrue(domains.contains("webcredentials:astraldeep.github.io"), name)
        }
    }
}

extension MeshConnectionSignIn.Phase {
    fileprivate var description: String { String(describing: self) }
}

@MainActor
private final class RecordingSignInService: MeshConnectionSignInService {
    var begun = 0
    var completed: [String] = []
    var cancelled: [String] = []
    var beginError: Error?

    func beginConnectionSignIn(id: String, redirect: MeshSignInRedirect) async throws -> MeshSignInStart {
        begun += 1
        if let beginError { throw beginError }
        return MeshSignInStart(
            flow: "flow-\(begun)", authorizationURL: "https://issuer.example/authorize?state=s",
            redirectURI: ConnectionCallback.redirectURL, userCode: nil, verificationURI: nil,
            verificationURIComplete: nil, intervalSeconds: nil, expiresMs: 1)
    }

    func completeConnectionSignIn(flow: String, redirectURL: String) async throws -> MeshConnectionState {
        completed.append(redirectURL)
        return MeshConnectionState(connection: "c1", state: "signed_in", reason: nil, toolsPending: false)
    }

    func cancelConnectionSignIn(flow: String) async throws { cancelled.append(flow) }
}
