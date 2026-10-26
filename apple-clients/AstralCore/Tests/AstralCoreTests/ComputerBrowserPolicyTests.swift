// Exercises the browser pane policy: exact URL acceptance and origin normalization shared with the server,
// secret-field detection and redaction, and the consequential-control classifier.

@testable import AstralCore
import XCTest

final class ComputerBrowserPolicyTests: XCTestCase {
    private func rejected(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ComputerBrowserPolicy.navigableURL(text), text, file: file, line: line) {
            XCTAssertEqual(($0 as? ComputerHostError)?.code, "url_rejected", file: file, line: line)
        }
        XCTAssertNil(ComputerBrowserPolicy.origin(of: text), text, file: file, line: line)
    }

    private func field(
        _ tag: String = "input", type: String = "text", name: String = "", id: String = "",
        autocomplete: String = ""
    ) -> ComputerBrowserElement {
        ComputerBrowserElement(tag: tag, type: type, nameAttribute: name, idAttribute: id, autocomplete: autocomplete)
    }

    func testAcceptsPlainHttpAndHttpsAndNormalizesOrigins() throws {
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://example.org/form?q=1#top"), "https://example.org")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "HTTPS://Example.ORG/Path"), "https://example.org")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "http://example.org:80/"), "http://example.org")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://example.org:443"), "https://example.org")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "http://example.org:443/"), "http://example.org:443")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://example.org:80/"), "https://example.org:80")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://example.org:8443/x"), "https://example.org:8443")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "http://127.0.0.1:5000/a"), "http://127.0.0.1:5000")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "http://[::1]:8080/a"), "http://[::1]:8080")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://[2001:DB8::1]/"), "https://[2001:db8::1]")
        XCTAssertEqual(ComputerBrowserPolicy.origin(of: "https://example.org:/"), "https://example.org")
        let url = try ComputerBrowserPolicy.navigableURL("https://example.org/a?b=c")
        XCTAssertEqual(url.absoluteString, "https://example.org/a?b=c")
        XCTAssertTrue(ComputerBrowserPolicy.isNavigable(url))
        XCTAssertEqual(
            ComputerBrowserPolicy.origin(scheme: "HTTP", host: "LOCALHOST", port: 3000), "http://localhost:3000")
        XCTAssertNil(ComputerBrowserPolicy.origin(scheme: "https", host: "example.org", port: 0))
        XCTAssertNil(ComputerBrowserPolicy.origin(scheme: "https", host: "", port: nil))
        XCTAssertNil(ComputerBrowserPolicy.origin(scheme: "ftp", host: "example.org", port: nil))
        XCTAssertNil(ComputerBrowserPolicy.origin(scheme: "https", host: "a@b", port: nil))
    }

    func testRefusesOtherSchemesCredentialsAndLookalikeTricks() {
        for text in [
            "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "blob:https://example.org/1",
            "ftp://example.org/", "astral://open", "about:blank", "ws://example.org/", "https:example.org",
            "https:///path", "https://", "", "example.org", "//example.org/",
        ] {
            rejected(text)
        }
        rejected("https://good.example\\@evil.example/")
        rejected("https://good.example\\evil.example/")
        rejected("https://user@example.org/")
        rejected("https://user:secret@example.org/")
        rejected("https://@example.org/")
        rejected("https://example.org@evil.example/")
        rejected("https://exa\tmple.org/")
        rejected("https://example.org/a\nb")
        rejected("https://example.org/a b")
        rejected("https://example.org/\u{0}")
        rejected("https://example.org/\u{7F}")
        rejected("https://ex%61mple.org/")
        rejected("https://bücher.example/")
        for bidi: UInt32 in [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            rejected("https://example.org/\(String(Unicode.Scalar(bidi)!))gro.live")
            XCTAssertTrue(ComputerBrowserPolicy.bidiOrFormat(Unicode.Scalar(bidi)!))
        }
        rejected("https://example.org:99999/")
        rejected("https://example.org/" + String(repeating: "a", count: 4100))
        XCTAssertFalse(ComputerBrowserPolicy.isNavigable(URL(string: "file:///tmp")!))
    }

    func testSecretFieldsByTypeAutocompleteAndIdentifier() {
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(type: "password")))
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(type: "PASSWORD")))
        for token in [
            "one-time-code", "cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year",
            "section-pay billing cc-number",
            "current-password", "new-password",
        ] {
            XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(autocomplete: token)), token)
        }
        for name in [
            "password", "user_password", "newPassword", "passwd", "otp", "otpCode", "OTPCode", "cvv", "card_cvc",
            "card", "cardNumber", "creditCardNumber", "payment-card", "CVV2",
        ] {
            XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(name: name)), name)
            XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(id: name)), name)
        }
        for name in ["email", "discard", "footprint", "hotpot", "scorecard", "username"] {
            XCTAssertFalse(ComputerBrowserPolicy.isSecret(field(name: name)), name)
        }
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(field(name: "cardholder")))
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(field("textarea", type: "", name: "otp")))
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(field("select", type: "", autocomplete: "cc-exp-month")))
        XCTAssertTrue(
            ComputerBrowserPolicy.isSecret(ComputerBrowserElement(tag: "div", idAttribute: "card", editable: true)))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(field(autocomplete: "cc-name")))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(field(autocomplete: "email")))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(field(type: "checkbox", name: "remember_password")))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(field(type: "submit", name: "card")))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(field("button", type: "", id: "pay-card")))
        XCTAssertFalse(ComputerBrowserPolicy.isSecret(ComputerBrowserElement(tag: "div", idAttribute: "card")))
        XCTAssertEqual(ComputerBrowserPolicy.identifier("creditCardNumber"), "credit card number")
        XCTAssertEqual(ComputerBrowserPolicy.identifier("OTPCode"), "otpcode")
    }

    func testRedactionReplacesEverySecretValue() {
        XCTAssertEqual(ComputerBrowserPolicy.displayValue("hunter2", for: field(type: "password")), "<redacted>")
        XCTAssertEqual(ComputerBrowserPolicy.displayValue("", for: field(autocomplete: "one-time-code")), "<redacted>")
        XCTAssertEqual(ComputerBrowserPolicy.displayValue("4111", for: field(name: "cardNumber")), "<redacted>")
        XCTAssertEqual(ComputerBrowserPolicy.displayValue("Ada", for: field(name: "first_name")), "Ada")
        XCTAssertEqual(ComputerBrowserPolicy.redacted, "<redacted>")
    }

    func testConsequentialControls() {
        let submit = ComputerBrowserElement(
            tag: "button", type: "submit", label: "Continue", inForm: true, formHasSecret: true)
        XCTAssertTrue(ComputerBrowserPolicy.isConsequential(submit))
        XCTAssertTrue(
            ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "button", label: "Next", inForm: true, formHasSecret: true)))
        XCTAssertTrue(
            ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "input", type: "image", inForm: true, formHasSecret: true)))
        XCTAssertFalse(
            ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "button", type: "submit", label: "Continue", inForm: true)))
        XCTAssertFalse(
            ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "button", type: "button", label: "Show", inForm: true, formHasSecret: true))
        )
        XCTAssertFalse(
            ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "button", type: "submit", label: "Go", formHasSecret: true)))
        for words in [
            "Buy now", "PAY", "Purchase", "Place order", "Checkout", "Delete account", "Remove", "Send",
            "Transfer funds",
            "Confirm payment", "confirm   payment", "Pay-now", "(order)",
        ] {
            XCTAssertTrue(
                ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "button", label: words)), words)
            XCTAssertTrue(ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "a", text: words)), words)
        }
        for words in ["Payment history", "Repay", "Ordering guide", "Sender", "Confirm", "Removed items", "Next"] {
            XCTAssertFalse(
                ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "button", label: words)), words)
        }
        XCTAssertTrue(
            ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "input", autocomplete: "cc-name")))
        XCTAssertTrue(
            ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "input", autocomplete: "billing cc-type"))
        )
        XCTAssertFalse(
            ComputerBrowserPolicy.isConsequential(ComputerBrowserElement(tag: "input", autocomplete: "email")))
        XCTAssertTrue(ComputerBrowserPolicy.isSubmit(ComputerBrowserElement(tag: "button")))
        XCTAssertFalse(ComputerBrowserPolicy.isSubmit(ComputerBrowserElement(tag: "button", type: "reset")))
        XCTAssertTrue(ComputerBrowserPolicy.isSubmit(ComputerBrowserElement(tag: "input", type: "submit")))
        XCTAssertFalse(ComputerBrowserPolicy.isSubmit(ComputerBrowserElement(tag: "a")))
    }

    func testElementDescriptorsDecodeBoundedAndRejectMissingTags() throws {
        let element = try XCTUnwrap(
            ComputerBrowserElement(
                json: .object([
                    "tag": .string("INPUT"), "type": .string("Password"), "name_attr": .string("pw"),
                    "id_attr": .string("x"), "autocomplete": .string("Current-Password"),
                    "label": .string(String(repeating: "L", count: 2000)), "text": .string("t"),
                    "in_form": .bool(true), "form_has_secret": .bool(true), "editable": .bool(false),
                ])))
        XCTAssertEqual(element.tag, "input")
        XCTAssertEqual(element.type, "password")
        XCTAssertEqual(element.autocomplete, "current-password")
        XCTAssertEqual(element.label.count, 1000)
        XCTAssertTrue(element.inForm && element.formHasSecret)
        XCTAssertTrue(ComputerBrowserPolicy.isSecret(element))
        XCTAssertNil(ComputerBrowserElement(json: .object(["type": .string("text")])))
        XCTAssertNil(ComputerBrowserElement(json: .string("input")))
        XCTAssertEqual(ComputerBrowserElement(json: .object(["tag": .string("a")]))?.label, "")
    }

    func testScriptRulesCarryTheSamePatternsSwiftEnforces() throws {
        let rules = ComputerBrowserPolicy.scriptRules
        XCTAssertEqual(rules["redacted"], .string("<redacted>"))
        XCTAssertEqual(rules["identifier_pattern"]?.stringValue, ComputerBrowserPolicy.identifierPattern)
        XCTAssertEqual(rules["consequential_pattern"]?.stringValue, ComputerBrowserPolicy.consequentialPattern)
        XCTAssertEqual(rules["secret_types"], .array([.string("password")]))
        XCTAssertEqual(
            rules["secret_autocomplete"], .array(["cc-csc", "cc-number", "one-time-code"].map(JSONValue.string)))
        XCTAssertEqual(rules["non_field_types"]?.arrayValue?.count, ComputerBrowserPolicy.nonFieldTypes.count)
        for key in ["identifier_pattern", "consequential_pattern", "camel_pattern"] {
            XCTAssertNoThrow(try NSRegularExpression(pattern: try XCTUnwrap(rules[key]?.stringValue)), key)
        }
        let data = try rules.encoded()
        XCTAssertEqual(try JSONValue.parse(data), rules)
    }
}
