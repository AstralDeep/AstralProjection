// Checks that every connection record kind the kernel signs parses into a plain summary with its security details.
// Each record uses the kernel's canonical field set, and altered, extra, missing or mismatched input must fail closed.

import AstralKernel
import CryptoKit
import XCTest

@testable import AstralDeep

final class ConsentConnectionTests: XCTestCase {
    private let id = "44c3d55c24475a6459b19b5879e3936a"
    private let device = contactMeshId("c")
    private let toolHash = contactMeshId("a")
    private let pin = String(repeating: "A", count: 43)

    private func hash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func input(_ record: Data, digest: String? = nil, consentDevice: String? = nil) -> Data {
        let body: String =
            #"{"clock":{"ms":5,"n":0},"device":"\#(consentDevice ?? device)","digest":"\#(digest ?? hash(record))","#
            + #""kind":"connection","v":1}"#
        return Data("astral.consent/v1\n".utf8) + Data(body.utf8)
    }

    private func show(_ text: String, digest: String? = nil, consentDevice: String? = nil) throws
        -> AstralDeep.ConsentPrompt
    {
        let record = Data(text.utf8)
        let signing = input(record, digest: digest, consentDevice: consentDevice)
        let prompt = AstralKernel.ConsentPrompt(
            kind: .connection, title: "ignored", target: "x", canonicalAction: record, canonicalArguments: Data(),
            signingInput: signing, digest: hash(record), untrustedSources: [], labels: [], requiresBiometry: true,
            batch: 1)
        return try KernelHostSigner.display(for: prompt, message: signing)
    }

    private var mcpOAuth: String {
        #"{"auth":{"client_id":null,"issuer":"https://auth.research.example","#
            + #""resource":"https://mcp.research.example/mcp","scheme":"oauth","scopes":["a","b"]},"#
            + #""device":null,"egress":["auth.research.example","#
            + #""mcp.research.example"],"endpoint":"https://mcp.research.example/mcp","flow":"private","id":"\#(id)","#
            + #""kind":"mcp-http","local":false,"name":"Research","#
            + #""tools":[{"hash":"\#(toolHash)","name":"search"}],"v":1}"#
    }

    private var mcpNone: String {
        #"{"auth":{"client_id":null,"issuer":null,"resource":null,"scheme":"none","scopes":[]},"device":"\#(device)","#
            + #""egress":["127.0.0.1:8123"],"endpoint":"http://127.0.0.1:8123/mcp","flow":"private","id":"\#(id)","#
            + #""kind":"mcp-http","local":true,"name":"Local","tools":[],"v":1}"#
    }

    private var agent: String {
        #"{"auth":{"client_id":null,"issuer":null,"resource":null,"scheme":"key","scopes":[]},"card":{"#
            + #""extended_hash":null,"hash":"\#(toolHash)","origin":"https://agent.example.org","signer":"\#(pin)"},"#
            + #""card_url":"https://agent.example.org/.well-known/agent-card.json","egress":["agent.example.org"],"#
            + #""flow":"phi","id":"\#(id)","kind":"a2a","name":"Fixture Agent","#
            + #""tools":[{"hash":"\#(toolHash)","name":"ask_fixture_agent"}],"v":1}"#
    }

    private var stdio: String {
        #"{"args":["--root","/tmp"],"command":"/usr/local/bin/files","device":"\#(device)","egress":[],"#
            + #""env":["FILES_TOKEN"],"flow":"private","id":"\#(id)","kind":"mcp-stdio","#
            + #""name":"Files","tools":[],"v":1}"#
    }

    private var api: String {
        #"{"egress":["api.example.org"],"endpoint":"https://api.example.org/v1","flow":"private","id":"\#(id)","#
            + #""key":{"format":"Bearer {key}","header":"Authorization","item":"connection.key.\#(id)"},"#
            + #""kind":"http-api","name":"Lab API","tools":[],"v":1}"#
    }

    private var model: String {
        #"{"egress":["models.lab.example"],"endpoint":"https://models.lab.example/v1","flow":"phi","id":"\#(id)","#
            + #""key":{"item":"model.provider.lab-models"},"kind":"model","name":"Lab Models","v":1}"#
    }

    func testEveryKindShowsAPlainSummaryAndItsDetails() throws {
        let cases: [(String, String, [String])] = [
            (
                mcpOAuth, "Connect Research, a tool server at mcp.research.example",
                ["Sign-in: OAuth", "Issuer: https://auth.research.example", "Scopes: a, b", "Tools: search"]
            ),
            (
                mcpNone, "Connect Local, a tool server on this device",
                ["Sign-in: none", "Tools: none listed", "Data class: private"]
            ),
            (
                agent, "Connect Fixture Agent, an agent at agent.example.org",
                ["Sign-in: pasted key", "Card signer pin: " + pin, "Data class: phi", "Tools: ask_fixture_agent"]
            ),
            (
                stdio, "Run Files on this Mac",
                [
                    "Command: /usr/local/bin/files --root /tmp", "Secrets passed: FILES_TOKEN (values never shown)",
                    "Reaches: nothing",
                ]
            ),
            (
                api, "Connect Lab API, an API at api.example.org",
                ["Key sent as: Authorization: Bearer {key}", "Key: sealed, never shown here"]
            ),
            (
                model, "Connect Lab Models, a model at models.lab.example",
                ["Key: sealed, never shown here", "Data class: phi", "Reaches: models.lab.example"]
            ),
        ]
        for (text, summary, details) in cases {
            let shown = try show(text)
            XCTAssertEqual(shown.summaryLine, summary)
            XCTAssertEqual(shown.effect, "connection.approve")
            XCTAssertEqual(shown.digest, hash(Data(text.utf8)))
            XCTAssertTrue(shown.requiresBiometry)
            XCTAssertTrue(shown.arguments.hasSuffix("Record: " + text))
            for line in details { XCTAssertTrue(shown.arguments.contains(line), line) }
        }
    }

    func testAnotherDeviceIsNamedWhenTheServerRunsElsewhere() throws {
        let shown = try show(stdio, consentDevice: contactMeshId("d"))
        XCTAssertEqual(shown.summaryLine, "Run Files on another device in your mesh")
        XCTAssertTrue(shown.arguments.contains("Runs on: " + device))
    }

    func testKeyedKindsNeverCarryASecretAndRefuseARecordThatDoes() throws {
        for text in [api, model, agent] {
            let shown = try show(text)
            XCTAssertFalse((shown.summaryLine + shown.target + shown.arguments).contains("sk-live-secret"))
        }
        let leaked = #"{"api_key":"sk-live-secret","# + String(model.dropFirst())
        XCTAssertThrowsError(try show(leaked))
        let apiLeak = api.replacingOccurrences(of: #""v":1}"#, with: #""v":1,"zz":"sk-live-secret"}"#)
        XCTAssertThrowsError(try show(apiLeak))
    }

    func testAnExtraOrMissingFieldFailsClosedForEveryKind() throws {
        for text in [mcpOAuth, mcpNone, agent, stdio, api, model] {
            XCTAssertThrowsError(try show(text.replacingOccurrences(of: #""v":1}"#, with: #""v":1,"zz":1}"#)))
            XCTAssertThrowsError(try show(text.replacingOccurrences(of: #","v":1}"#, with: "}")))
        }
    }

    func testBadValuesAndKindsFailClosed() throws {
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: #""kind":"model""#, with: #""kind":"other""#)))
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)))
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: #""v":1"#, with: #""v":true"#)))
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: "https://models", with: "http://models")))
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: "model.provider.", with: "other.")))
        XCTAssertThrowsError(try show(model.replacingOccurrences(of: #""phi""#, with: #""public""#)))
        XCTAssertThrowsError(try show(api.replacingOccurrences(of: "connection.key." + id, with: "connection.key.x")))
        XCTAssertThrowsError(try show(api.replacingOccurrences(of: "Bearer {key}", with: "Bearer")))
        XCTAssertThrowsError(try show(agent.replacingOccurrences(of: pin, with: "short")))
        XCTAssertThrowsError(try show(agent.replacingOccurrences(of: "https://agent.example.org\"", with: "x\"")))
        XCTAssertThrowsError(try show(mcpOAuth.replacingOccurrences(of: #""device":null"#, with: #""device":"x""#)))
        XCTAssertThrowsError(try show(mcpNone.replacingOccurrences(of: #""local":true"#, with: #""local":1"#)))
        XCTAssertThrowsError(try show(stdio.replacingOccurrences(of: device, with: "nope")))
    }

    func testADigestMismatchFailsClosed() throws {
        for text in [mcpOAuth, agent, stdio, api, model] {
            XCTAssertThrowsError(try show(text, digest: contactMeshId("e")))
        }
    }

    func testAnUnreadableRequestIsExplainedInPlainWords() {
        let failure = KernelMapping.error(
            KernelError.State(code: "signer.failed", message: "consent.unreadable: nothing was signed"))
        let text = (failure as? MeshKernelError)?.message
        XCTAssertEqual(text, "This app can't show that request, so nothing was signed. (consent.unreadable)")
    }
}
