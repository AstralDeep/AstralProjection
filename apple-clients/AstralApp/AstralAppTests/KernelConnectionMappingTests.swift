// Verifies the connection records, sign-in values, change event, error texts and signing prompt that map the generated kernel types onto the host's.
// The connection consent prompt is checked against the exact canonical record and signing input the kernel signs.

import AstralKernel
import CryptoKit
import XCTest

@testable import AstralDeep

final class KernelConnectionMappingTests: XCTestCase {
    private static let id = String(repeating: "ab", count: 16)
    private static let device = "sha256:" + String(repeating: "c", count: 64)
    private static let toolHash = "sha256:" + String(repeating: "d", count: 64)

    private func hash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func record(name: String = "Research", scheme: String = "oauth", flow: String = "private") -> Data {
        let issuer = scheme == "oauth" ? #""https://issuer.example""# : "null"
        let resource = scheme == "oauth" ? #""https://mcp.example/mcp""# : "null"
        let scopes = scheme == "oauth" ? #"["read"]"# : "[]"
        let text: String =
            #"{"auth":{"client_id":null,"issuer":\#(issuer),"resource":\#(resource),"#
            + #""scheme":"\#(scheme)","scopes":\#(scopes)},"#
            + #""device":null,"egress":["issuer.example","mcp.example"],"endpoint":"https://mcp.example/mcp","#
            + #""flow":"\#(flow)","id":"\#(Self.id)","kind":"mcp-http","local":false,"name":"\#(name)","#
            + #""tools":[{"hash":"\#(Self.toolHash)","name":"search"}],"v":1}"#
        return Data(text.utf8)
    }

    private func signingInput(for record: Data, kind: String = "connection", digest: String? = nil) -> Data {
        let consent: String =
            #"{"clock":{"ms":5,"n":0},"device":"\#(Self.device)","digest":"\#(digest ?? hash(record))","#
            + #""kind":"\#(kind)","v":1}"#
        return Data("astral.consent/v1\n".utf8) + Data(consent.utf8)
    }

    private func prompt(record: Data, input: Data, kind: ConsentKind = .connection) -> AstralKernel.ConsentPrompt {
        AstralKernel.ConsentPrompt(
            kind: kind, title: "Research", target: "Research at https://mcp.example/mcp", canonicalAction: record,
            canonicalArguments: Data(), signingInput: input, digest: hash(record), untrustedSources: [], labels: [],
            requiresBiometry: true, batch: 1)
    }

    func testConnectionPromptShowsTheRecordAndBindsToTheSigningInput() throws {
        let body = record()
        let input = signingInput(for: body)
        let shown = try KernelHostSigner.display(for: prompt(record: body, input: input), message: input)
        XCTAssertEqual(shown.actionTitle, "Connect Research")
        XCTAssertEqual(shown.effect, "connection.approve")
        XCTAssertEqual(shown.target, "Research at https://mcp.example/mcp")
        XCTAssertTrue(shown.requiresBiometry)
        XCTAssertTrue(shown.isBound(to: input))
        XCTAssertFalse(shown.isBound(to: input + Data([0])))
        XCTAssertEqual(shown.digest, hash(body))
        for line in ["Issuer: https://issuer.example", "Scopes: read", "Tools: search", "Data class: private"] {
            XCTAssertTrue(shown.arguments.contains(line), line)
        }
    }

    func testAnOpenConnectionPromptSaysThereIsNoSignIn() throws {
        let body = record(scheme: "none")
        let input = signingInput(for: body)
        let shown = try KernelHostSigner.display(for: prompt(record: body, input: input), message: input)
        XCTAssertTrue(shown.arguments.contains("Sign-in: none"))
        XCTAssertFalse(shown.arguments.contains("Issuer:"))
    }

    private func refused(_ body: Data, _ input: Data, message: Data? = nil, line: UInt = #line) {
        let shown = prompt(record: body, input: input)
        XCTAssertThrowsError(try KernelHostSigner.display(for: shown, message: message ?? input), line: line)
    }

    func testConnectionPromptRefusesAnythingTheRecordDoesNotBack() throws {
        let body = record()
        let input = signingInput(for: body)
        refused(body, input, message: Data("other".utf8))
        refused(body, signingInput(for: body, kind: "action"))
        refused(body, signingInput(for: body, digest: Self.toolHash))
        refused(record(flow: "open"), signingInput(for: record(flow: "open")))
        refused(Data(#"{"v":1}"#.utf8), signingInput(for: Data(#"{"v":1}"#.utf8)))
        let spaced = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: ",", with: ", ").utf8)
        refused(spaced, signingInput(for: spaced))
        let tampered = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "search", with: "wipe").utf8)
        refused(tampered, input)
    }

    func testConnectionInfoMapsEveryField() {
        let device = ConnectionDeviceState(
            device: Self.device, label: "Mac", state: "needs_attention", reason: "expired",
            issuer: "https://issuer.example", ms: 9)
        let other = ConnectionDeviceState(
            device: "sha256:" + String(repeating: "e", count: 64), label: "Phone", state: "signed_in", reason: nil,
            issuer: nil, ms: 3)
        let tool = ConnectionTool(name: "search", hash: Self.toolHash)
        let info = ConnectionInfo(
            id: Self.id, server: "cabababab", name: "Research", kind: "mcp-http", endpoint: "https://mcp.example/mcp",
            local: false, device: nil, scheme: "oauth", issuer: "https://issuer.example", scopes: ["read"],
            clientId: "client", flow: "private", egress: ["mcp.example"], tools: [tool], approvedBy: Self.device,
            approvedByRemovedDevice: true, unsupported: nil, supportedHere: true, thisDevice: device,
            attention: "expired", otherDevices: [other], pendingTools: [tool])
        let mapped = KernelMapping.connection(info)
        XCTAssertEqual(mapped.id, Self.id)
        XCTAssertEqual(mapped.server, "cabababab")
        XCTAssertEqual(mapped.tools, [MeshConnectionTool(name: "search", hash: Self.toolHash)])
        XCTAssertEqual(mapped.pendingTools?.map(\.name), ["search"])
        XCTAssertEqual(mapped.thisDevice.atMs, 9)
        XCTAssertEqual(mapped.thisDevice.reason, "expired")
        XCTAssertEqual(mapped.otherDevices.map(\.label), ["Phone"])
        XCTAssertEqual(mapped.clientId, "client")
        XCTAssertEqual(mapped.attention, "expired")
        XCTAssertTrue(mapped.approvedByRemovedDevice)
        XCTAssertTrue(mapped.supportedHere)
        XCTAssertNil(mapped.unsupported)
    }

    func testProposalAndStateMapEveryField() {
        let proposal = ConnectionProposal(
            proposal: "p", connection: Self.id, kind: "a2a", name: "Research",
            endpoint: "https://mcp.example/mcp", local: false,
            device: nil, scheme: "oauth", issuer: "https://issuer.example", issuerHost: "issuer.example",
            redirectHost: "astraldeep.github.io", scopes: ["read"], resource: "https://mcp.example/mcp",
            clientId: nil, tools: [], egress: ["issuer.example"], flowHint: "phi", replaces: Self.id, expiresMs: 77,
            card: ConnectionCard(
                url: "https://mcp.example/card", hash: "h", origin: "o", signer: "s", signed: true,
                extendedHash: nil, extendedPending: false, skills: ["ask"]),
            command: nil, args: [], envNames: [], keyHeader: "X-Key", keyFormat: "{key}", keyItem: "item",
            models: ["m"], keyRecipients: ["d"])
        let mapped = KernelMapping.connectionProposal(proposal)
        XCTAssertEqual(mapped.proposal, "p")
        XCTAssertEqual(mapped.issuerHost, "issuer.example")
        XCTAssertEqual(mapped.redirectHost, "astraldeep.github.io")
        XCTAssertEqual(mapped.flowHint, "phi")
        XCTAssertEqual(mapped.replaces, Self.id)
        XCTAssertEqual(mapped.expiresMs, 77)
        XCTAssertEqual(mapped.kind, "a2a")
        XCTAssertEqual(mapped.card?.signer, "s")
        XCTAssertEqual(mapped.keyHeader, "X-Key")
        XCTAssertEqual(mapped.models, ["m"])
        XCTAssertEqual(mapped.keyRecipients, ["d"])
        let state = KernelMapping.connectionState(
            ConnectionState(connection: Self.id, state: "signed_in", reason: nil, toolsPending: true))
        let expected = MeshConnectionState(connection: Self.id, state: "signed_in", reason: nil, toolsPending: true)
        XCTAssertEqual(state, expected)
    }

    func testSignInValuesMapBothWaysAndNeverPrintASecret() {
        let start = KernelMapping.signInStart(
            SignInStart(
                flow: "f1", authorizationUrl: "https://issuer.example/authorize?state=SECRETSTATE",
                redirectUri: "http://127.0.0.1:4000/callback", userCode: "WDJB-MJHT",
                verificationUri: "https://issuer.example/device", verificationUriComplete: nil, intervalS: 5,
                expiresMs: 9))
        XCTAssertEqual(start.flow, "f1")
        XCTAssertEqual(start.intervalSeconds, 5)
        XCTAssertEqual(start.userCode, "WDJB-MJHT")
        for text in [start.description, start.debugDescription, "\(start)", String(reflecting: start)] {
            XCTAssertFalse(text.contains("SECRETSTATE"))
            XCTAssertFalse(text.contains("WDJB"))
            XCTAssertTrue(text.contains("f1"))
        }
        XCTAssertEqual(KernelMapping.signInPoll(.pending(intervalS: 5)), .pending(intervalSeconds: 5))
        let done = ConnectionState(connection: Self.id, state: "signed_in", reason: nil, toolsPending: false)
        XCTAssertEqual(KernelMapping.signInPoll(.done(state: done)), .done(KernelMapping.connectionState(done)))
        XCTAssertEqual(KernelMapping.signInRedirect(.appLink), .appLink)
        XCTAssertEqual(KernelMapping.signInRedirect(.loopback(port: 4000)), .loopback(port: 4000))
        XCTAssertEqual(KernelMapping.signInRedirect(.loopbackV6(port: 4001)), .loopbackV6(port: 4001))
        XCTAssertEqual(KernelMapping.signInRedirect(.pasted), .pasted)
        XCTAssertEqual(KernelMapping.signInRedirect(.deviceCode), .deviceCode)
        XCTAssertEqual(KernelMapping.stepUpPlan(.review(scopes: ["a"])), .review(scopes: ["a"]))
        XCTAssertEqual(KernelMapping.stepUpPlan(.signIn(scopes: ["b"])), .signIn(scopes: ["b"]))
    }

    func testConnectionsChangedReachesTheHostAndIsNotAnEnrollmentSignal() {
        XCTAssertEqual(KernelMapping.changes(.connectionsChanged), [.connectionsChanged])
        XCTAssertFalse(KernelMapping.isEnrollmentComplete(.connectionsChanged))
    }

    func testConnectionRefusalsKeepTheirCodesAndReadAsPlainText() {
        for code in [
            "connection.keystore_unavailable", "connection.credential_unreadable", "connection.credential_unwritable",
            "connection.changed", "connection.egress_refused", "connection.step_up_unreviewed", "connection.unknown",
            "oauth.state_mismatch",
        ] {
            let error = KernelMapping.error(KernelError.State(code: code, message: "secret detail"))
            guard case MeshKernelError.refused(let got, let message) = error else { return XCTFail(code) }
            XCTAssertEqual(got, code)
            XCTAssertFalse(message.contains("secret detail"))
            XCTAssertFalse(message.contains("("), code)
        }
    }
}
