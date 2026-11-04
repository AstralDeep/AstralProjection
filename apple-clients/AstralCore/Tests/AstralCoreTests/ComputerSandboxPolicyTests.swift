// Exercises the command-sandbox policy purely: egress domain and binding validation, destination
// classification, proxy request parsing and decisions, placeholder swapping, scrubbing and violation parsing.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class ComputerSandboxPolicyTests: XCTestCase {
        private func domain(_ value: String) -> ComputerEgressDomain? { ComputerEgressDomain(value) }
        private func binding(_ placeholder: String, _ host: String, _ secret: String) -> ComputerEgressBinding? {
            ComputerEgressBinding(placeholder: placeholder, host: host, secret: secret)
        }
        private func policy(
            _ domains: [String] = [], _ bindings: [ComputerEgressBinding] = [], mode: ComputerSandboxMode = .enforce
        ) -> ComputerEgressPolicy {
            ComputerEgressPolicy(
                mode: mode, domains: domains.compactMap(domain), bindings: bindings)
        }

        func testDomainValidationAcceptsNamesAndSuffixWildcardsOnly() {
            for value in ["api.github.com", "example.COM", "*.example.com", "a.io", "xn--80ak6aa92e.com"] {
                XCTAssertNotNil(domain(value), value)
            }
            XCTAssertEqual(domain("Example.COM")?.value, "example.com")
            for value in [
                "", "*", "*.", ".", "a", "com", "*.com", "a..b", ".a.com", "a.com.", "-a.com", "a-.com",
                "a_b.com", "a b.com", "A.com", String(repeating: "a", count: 64) + ".com",
                String(repeating: "a.", count: 127) + "com", "a.com/\u{0065}", "a.com:443",
            ] {
                XCTAssertNil(domain(value), value)
            }
            XCTAssertTrue(domain("api.github.com")!.matches("API.GitHub.com"))
            XCTAssertFalse(domain("api.github.com")!.matches("github.com"))
            XCTAssertFalse(domain("api.github.com")!.matches("evil-api.github.com.example.io"))
            XCTAssertTrue(domain("*.github.com")!.matches("api.github.com"))
            XCTAssertTrue(domain("*.github.com")!.matches("a.b.github.com"))
            XCTAssertFalse(domain("*.github.com")!.matches("github.com"))
            XCTAssertFalse(domain("*.github.com")!.matches("xgithub.com"))
        }

        func testBindingValidationRequiresDistinctivePlaceholdersAndExactHosts() {
            XCTAssertNotNil(binding("ASTRAL_GITHUB_TOKEN", "api.github.com", "astral.egress.github"))
            XCTAssertNotNil(binding("ASTRAL_X1Y2Z3", "a.io", "Secret-Name_1"))
            for (placeholder, host, secret) in [
                ("TOKEN", "a.io", "s"), ("astral_token", "a.io", "s"), ("ASTRAL_OK", "*.a.io", "s"),
                ("ASTRAL_OK", "a.io", "with space"), ("ASTRAL_OK", "a.io", ""),
                ("ASTRAL_OK", "a.io", String(repeating: "s", count: 129)),
                ("ASTRAL_AB", "a.io", "s"), ("ASTRAL_OK", "a.io", "semi;colon"),
                (String(repeating: "A", count: 129), "a.io", "s"), ("OK_ASTRAL", "a.io", "s"),
            ] {
                XCTAssertNil(binding(placeholder, host, secret), "\(placeholder)|\(host)|\(secret)")
            }
        }

        func testConfigurationDecodesStrictlyAndFallsBackClosed() throws {
            let configuration = try XCTUnwrap(
                ComputerSandboxConfiguration(
                    mode: .enforce, domains: [domain("api.github.com")!],
                    bindings: [binding("ASTRAL_GITHUB_TOKEN", "api.github.com", "astral.egress.github")!]))
            let data = try JSONEncoder().encode(configuration)
            XCTAssertEqual(ComputerSandboxConfiguration.decoded(data), configuration)
            XCTAssertEqual(ComputerSandboxConfiguration.decoded(data).mode, .enforce)
            XCTAssertEqual(ComputerSandboxConfiguration.decoded(data).domains.first?.value, "api.github.com")
            XCTAssertEqual(
                ComputerSandboxConfiguration.decoded(data).bindings.first?.placeholder, "ASTRAL_GITHUB_TOKEN")
            XCTAssertEqual(
                ComputerSandboxConfiguration.decoded(Data("not json".utf8)), .fallback)
            XCTAssertEqual(
                ComputerSandboxConfiguration.decoded(Data("{\"mode\":\"enforce\",\"domains\":[\"bad_domain\"]}".utf8)),
                .fallback)
            XCTAssertEqual(
                ComputerSandboxConfiguration.decoded(Data("{\"mode\":\"off\"}".utf8)), .fallback)
            XCTAssertEqual(
                ComputerSandboxConfiguration.decoded(Data("{\"mode\":\"shadow\"}".utf8)), .fallback)
            XCTAssertNil(
                ComputerSandboxConfiguration(
                    mode: .enforce, domains: Array(repeating: domain("a.io")!, count: 2), bindings: []))
            XCTAssertNil(
                ComputerSandboxConfiguration(
                    mode: .shadow, domains: Array(repeating: domain("a.io")!, count: 65), bindings: []))
            XCTAssertNil(
                ComputerSandboxConfiguration(
                    mode: .shadow, domains: [],
                    bindings: Array(repeating: binding("ASTRAL_OK", "a.io", "s")!, count: 17)))
        }

        func testIPAddressParsingAndClassificationRefusesEveryNonPublicRoutableClass() throws {
            func parse(_ text: String) throws -> ComputerIPAddress { try XCTUnwrap(ComputerIPAddress.parse(text)) }
            XCTAssertEqual(try parse("127.0.0.1").addressClass, .loopback)
            XCTAssertEqual(try parse("10.1.2.3").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("172.16.0.9").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("172.31.255.1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("192.168.1.1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("100.64.0.1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("169.254.169.254").addressClass, .metadata)
            XCTAssertEqual(try parse("169.254.10.11").addressClass, .linkLocal)
            XCTAssertEqual(try parse("8.8.8.8").addressClass, .publicNetwork)
            XCTAssertEqual(try parse("0.0.0.0").addressClass, .unspecified)
            XCTAssertEqual(try parse("239.1.2.3").addressClass, .multicast)
            XCTAssertEqual(try parse("240.0.0.1").addressClass, .reserved)
            XCTAssertNil(ComputerIPAddress.parse("01.2.3.4"))
            XCTAssertNil(ComputerIPAddress.parse("1.2.3"))
            XCTAssertNil(ComputerIPAddress.parse("1.2.3.4.5"))
            XCTAssertNil(ComputerIPAddress.parse("a.b.c.d"))
            XCTAssertEqual(try parse("::1").addressClass, .loopback)
            XCTAssertEqual(try parse("::ffff:127.0.0.1").addressClass, .loopback)
            XCTAssertEqual(try parse("::ffff:10.0.0.1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("fe80::1").addressClass, .linkLocal)
            XCTAssertEqual(try parse("fc00::1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("fd12:3456::1").addressClass, .privateNetwork)
            XCTAssertEqual(try parse("ff02::1").addressClass, .multicast)
            XCTAssertEqual(try parse("::").addressClass, .unspecified)
            XCTAssertEqual(try parse("2606:4700::1111").addressClass, .publicNetwork)
            XCTAssertEqual(try parse("2001:4860:4860::8888").addressClass, .publicNetwork)
            XCTAssertEqual(try parse("2001:db8::1").addressClass, .publicNetwork)
            XCTAssertNil(ComputerIPAddress.parse("2001:db8::1::2"))
            XCTAssertNil(ComputerIPAddress.parse("12345::"))
            XCTAssertEqual(ComputerIPAddress.parse("[::1]")?.addressClass, .loopback)
        }

        func testAuthorityParsingCoversDefaultPortsAndRejectsExplicitZero() throws {
            XCTAssertEqual(
                ComputerEgressTarget.authority("api.github.com:443", defaultPort: 80),
                ComputerEgressTarget(host: "api.github.com", port: 443))
            XCTAssertEqual(
                ComputerEgressTarget.authority("localhost", defaultPort: 443),
                ComputerEgressTarget(host: "localhost", port: 443))
            XCTAssertEqual(
                ComputerEgressTarget.authority("[::1]:8443", defaultPort: 80),
                ComputerEgressTarget(host: "::1", port: 8443))
            XCTAssertEqual(
                ComputerEgressTarget.authority("[::1]", defaultPort: 443),
                ComputerEgressTarget(host: "::1", port: 443))
            XCTAssertNil(ComputerEgressTarget.authority("host:0", defaultPort: 80))
            XCTAssertNil(ComputerEgressTarget.authority("[::1]:0", defaultPort: 80))
            XCTAssertNil(ComputerEgressTarget.authority("", defaultPort: 80))
            XCTAssertNil(ComputerEgressTarget.authority("host:99999", defaultPort: 80))
            XCTAssertNil(ComputerEgressTarget.authority("host:name", defaultPort: 80))
            XCTAssertNil(ComputerEgressTarget.authority("a:b:c", defaultPort: 80))
        }

        func testRequestParsingSeparatesConnectAbsoluteAndOtherForms() throws {
            let connect = try XCTUnwrap(
                ComputerEgressRequest.parse("CONNECT api.github.com:443 HTTP/1.1\r\nX: y"))
            XCTAssertEqual(connect.form, .connect)
            XCTAssertEqual(connect.method, "CONNECT")
            XCTAssertEqual(connect.target, ComputerEgressTarget(host: "api.github.com", port: 443))
            let absolute = try XCTUnwrap(
                ComputerEgressRequest.parse("GET http://Api.GitHub.com:8443/a/b?q=1 HTTP/1.1\r\nHost: x\r\n"))
            XCTAssertEqual(absolute.form, .absolute)
            XCTAssertEqual(absolute.target, ComputerEgressTarget(host: "api.github.com", port: 8443))
            XCTAssertEqual(absolute.path, "/a/b?q=1")
            XCTAssertEqual(
                absolute.originFormRequestLine, "GET /a/b?q=1 HTTP/1.1\r\nHost: api.github.com:8443")
            let plain = try XCTUnwrap(ComputerEgressRequest.parse("GET http://example.com HTTP/1.1"))
            XCTAssertEqual(plain.target, ComputerEgressTarget(host: "example.com", port: 80))
            XCTAssertEqual(plain.path, "/")
            let other = try XCTUnwrap(ComputerEgressRequest.parse("GET /index.html HTTP/1.1\r\nHost: x"))
            XCTAssertEqual(other.form, .other)
            XCTAssertNil(other.target)
            XCTAssertNil(ComputerEgressRequest.parse(""))
            XCTAssertNil(ComputerEgressRequest.parse("CONNECT host HTTP/1.1 extra"))
            XCTAssertNil(ComputerEgressRequest.parse("GET http://host:0/ HTTP/1.1"))
            XCTAssertNil(ComputerEgressRequest.parse("GET http://host:0/ HTTP/1.1 extra header"))
            XCTAssertNil(
                ComputerEgressRequest.parse(String(repeating: "A", count: 20000) + " HTTP/1.1"))
        }

        func testEvaluationAppliesAllowlistThenResolvedDestinationThenBindings() throws {
            let token = "ASTRAL_GITHUB_TOKEN"
            let subject = policy(
                ["api.github.com", "example.com"],
                [binding(token, "api.github.com", "astral.egress.github")!])
            let head = "GET http://api.github.com/x HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n"
            let allowed = try XCTUnwrap(ComputerEgressRequest.parse(head))
            XCTAssertEqual(
                subject.evaluate(request: allowed, resolved: [ComputerIPAddress.parse("93.184.216.34")!]),
                ComputerEgressEvaluation(verdict: .allow(rule: "api.github.com"), placeholders: [token]))
            let unlisted = try XCTUnwrap(ComputerEgressRequest.parse("GET http://evil.example.io/ HTTP/1.1"))
            XCTAssertEqual(
                subject.evaluate(request: unlisted, resolved: []),
                ComputerEgressEvaluation(verdict: .refuse(.unlistedHost), placeholders: []))
            let listed = try XCTUnwrap(ComputerEgressRequest.parse("GET http://example.com/ HTTP/1.1"))
            for (resolved, expected) in [
                ([ComputerIPAddress.parse("10.1.2.3")!], ComputerEgressRefusal.privateDestination),
                ([ComputerIPAddress.parse("169.254.169.254")!], ComputerEgressRefusal.metadataDestination),
                ([ComputerIPAddress.parse("fe80::1")!], ComputerEgressRefusal.linkLocalDestination),
                ([ComputerIPAddress.parse("::1")!], ComputerEgressRefusal.loopbackDestination),
                ([ComputerIPAddress.parse("ff02::2")!], ComputerEgressRefusal.reservedDestination),
            ] {
                XCTAssertEqual(
                    subject.evaluate(request: listed, resolved: resolved).verdict, .refuse(expected),
                    String(resolved.count))
            }
            XCTAssertEqual(
                subject.evaluate(request: listed, resolved: []).verdict, .refuse(.unresolvableHost))
            let bound = try XCTUnwrap(ComputerEgressRequest.parse("GET http://example.com/ HTTP/1.1\r\nX: \(token)"))
            XCTAssertEqual(
                subject.evaluate(request: bound, resolved: [ComputerIPAddress.parse("93.184.216.34")!]).verdict,
                .refuse(.placeholderUnbound))
            let literal = try XCTUnwrap(ComputerEgressRequest.parse("CONNECT 10.0.0.5:443 HTTP/1.1"))
            XCTAssertEqual(
                subject.evaluate(request: literal, resolved: [ComputerIPAddress.parse("10.0.0.5")!]).verdict,
                .refuse(.unlistedHost))
            let other = try XCTUnwrap(ComputerEgressRequest.parse("GET /path HTTP/1.1"))
            XCTAssertEqual(
                subject.evaluate(request: other, resolved: []).verdict, .refuse(.malformedRequest))
        }

        func testPlaceholderSwappingIsBoundToTheHostAndNeverForwardsWithoutASecret() throws {
            let subject = policy(
                ["api.github.com"],
                [
                    binding("ASTRAL_GITHUB_TOKEN", "api.github.com", "astral.egress.github")!,
                    binding("ASTRAL_OTHER_TOKEN", "other.example.com", "astral.egress.other")!,
                ])
            let head = "GET / HTTP/1.1\r\nAuthorization: Bearer ASTRAL_GITHUB_TOKEN\r\n"
            let swapped = ComputerSandboxPolicy.swapPlaceholders(
                in: head, bindings: subject.bindings(for: "api.github.com"),
                resolving: { $0 == "astral.egress.github" ? "gh_secret_value" : nil })
            XCTAssertEqual(swapped.head, "GET / HTTP/1.1\r\nAuthorization: Bearer gh_secret_value\r\n")
            XCTAssertEqual(swapped.swapped, ["ASTRAL_GITHUB_TOKEN"])
            XCTAssertTrue(swapped.missing.isEmpty)
            let missing = ComputerSandboxPolicy.swapPlaceholders(
                in: head, bindings: subject.bindings(for: "api.github.com"), resolving: { _ in nil })
            XCTAssertEqual(missing.head, head)
            XCTAssertTrue(missing.swapped.isEmpty)
            XCTAssertEqual(missing.missing, ["ASTRAL_GITHUB_TOKEN"])
            let untouched = ComputerSandboxPolicy.swapPlaceholders(
                in: head, bindings: subject.bindings(for: "other.example.com"), resolving: { _ in "x" })
            XCTAssertEqual(untouched.head, head)
            let multiline = ComputerSandboxPolicy.swapPlaceholders(
                in: head, bindings: [binding("ASTRAL_GITHUB_TOKEN", "api.github.com", "line\nbreak")!],
                resolving: { _ in "line\nbreak" })
            XCTAssertEqual(multiline.head, head)
            XCTAssertEqual(multiline.missing, ["ASTRAL_GITHUB_TOKEN"])
        }

        func testScrubbingAndEnvironmentLeakDetectionCoverEveryPlaceholderSurface() {
            let placeholders = ["ASTRAL_GITHUB_TOKEN", "ASTRAL_LONGER_TOKEN_XXXX"]
            XCTAssertEqual(
                ComputerSandboxPolicy.scrub(
                    "token=ASTRAL_GITHUB_TOKEN done ASTRAL_LONGER_TOKEN_XXXX", placeholders: placeholders),
                "token=[astral:redacted] done [astral:redacted]")
            XCTAssertEqual(ComputerSandboxPolicy.scrub("clean output", placeholders: placeholders), "clean output")
            XCTAssertEqual(
                ComputerSandboxPolicy.leakedEnvironmentVariable(
                    ["HOME": "/Users/sam", "APP_FLAG": "ASTRAL_GITHUB_TOKEN"], placeholders: placeholders),
                "APP_FLAG")
            XCTAssertNil(
                ComputerSandboxPolicy.leakedEnvironmentVariable(
                    ["HOME": "/Users/sam", "APP_FLAG": "value"], placeholders: placeholders))
        }

        func testViolationParsingAttributesStandardSandboxDenialLines() {
            let text = [
                "noise before", "Sandbox: zsh(51231) deny(1) file-write-data /Users/sam/proj/out.txt",
                "Sandbox: git(51231) deny(3) file-read-data /Users/sam/proj/.env (2 more times)",
                "sandbox-exec: profile error: something", "Sandbox: sh(notapid) deny(1) file-write-data /x",
                "Sandbox: sh(51232) deny(x) file-write-data /x", "Sandbox: sh(51233) deny(1) /only-target",
            ].joined(separator: "\n")
            XCTAssertEqual(
                ComputerSandboxViolation.parse(text),
                [
                    ComputerSandboxViolation(
                        process: "zsh", pid: 51231, operation: "file-write-data", target: "/Users/sam/proj/out.txt"),
                    ComputerSandboxViolation(
                        process: "git", pid: 51231, operation: "file-read-data",
                        target: "/Users/sam/proj/.env (2 more times)"),
                ])
            XCTAssertEqual(
                ComputerSandboxViolation.parse("Sandbox: zsh(51231) deny(1) file-write-data /x\r").first?.target, "/x")
            XCTAssertTrue(ComputerSandboxViolation.parse("").isEmpty)
        }

        func testDecisionRecordsExposeDecisionRuleAndPlaceholdersWithoutBodies() throws {
            let target = try XCTUnwrap(ComputerEgressTarget(host: "api.github.com", port: 443))
            let allow = ComputerEgressDecision(
                target: target, verdict: .allow(rule: "api.github.com"), forwarded: true,
                placeholders: ["ASTRAL_GITHUB_TOKEN"])
            XCTAssertEqual(allow.decision, "allow")
            XCTAssertEqual(allow.rule, "api.github.com")
            XCTAssertEqual(allow.json["host"], .string("api.github.com"))
            XCTAssertEqual(allow.json["port"], .number(443))
            XCTAssertEqual(allow.json["decision"], .string("allow"))
            XCTAssertEqual(allow.json["rule"], .string("api.github.com"))
            XCTAssertEqual(allow.json["placeholders"], .array([.string("ASTRAL_GITHUB_TOKEN")]))
            let refuse = ComputerEgressDecision(
                target: target, verdict: .refuse(.unlistedHost), forwarded: false, placeholders: [])
            XCTAssertEqual(refuse.decision, "refuse")
            XCTAssertEqual(refuse.rule, "unlisted_host")
            XCTAssertNil(refuse.json["placeholders"])
            let observed = ComputerEgressDecision(
                target: target, verdict: .refuse(.privateDestination), forwarded: true, placeholders: [])
            XCTAssertEqual(observed.decision, "allow")
            XCTAssertEqual(observed.rule, "private_destination")
        }
    }
#endif
