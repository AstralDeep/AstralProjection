// Verifies ordinary SDUI forms display and submit one consistent set of server defaults and edits.
// ParameterForm feeds the Apple settings renderer while guidance retains its stricter request validator.

@testable import AstralCore
import XCTest

final class ParameterFormTests: XCTestCase {
    private func form(_ fields: String, actions: String = "") throws -> ParameterForm {
        let value = try JSONValue.parse(Data("{\"type\":\"param_picker\",\"fields\":\(fields)\(actions)}".utf8))
        return try XCTUnwrap(ParameterForm(component: AstralComponent(json: value)!))
    }

    func testSavedSelectUsesValueAndLabelAndRetainsMissingSavedChoice() throws {
        let form = try form(
            #"[{"name":"provider","kind":"select","default":"custom","options":[{"value":"openai","label":"OpenAI"},{"value":"custom","label":"Custom endpoint"}]},{"name":"model","kind":"select","default":"saved-model","options":["other-model"]}]"#
        )
        XCTAssertEqual(form.stringValue(form.fields[0], values: [:]), "custom")
        XCTAssertEqual(form.options(form.fields[0]).last?.label, "Custom endpoint")
        XCTAssertEqual(form.options(form.fields[1]).last?.value, "saved-model")
        XCTAssertEqual(form.collected(values: [:], flags: [:])["provider"], .string("custom"))
        XCTAssertEqual(form.collected(values: [:], flags: [:])["model"], .string("saved-model"))
    }

    func testFirstOptionWithoutDefaultDisplaysAndSubmitsTheSameValue() throws {
        let form = try form(#"[{"name":"mode","kind":"select","options":["first","second"]}]"#)
        XCTAssertEqual(form.stringValue(form.fields[0], values: [:]), "first")
        XCTAssertEqual(form.collected(values: [:], flags: [:])["mode"], .string("first"))
    }

    func testChecklistDefaultsAndIndividualEditsRoundTripWithoutLosingOtherSelections() throws {
        let form = try form(
            #"[{"name":"tools","kind":"checklist","default":["read","write"],"options":[{"value":"read","label":"Read files"},"write","run"]}]"#
        )
        XCTAssertTrue(form.selected(form.fields[0], option: "read", flags: [:]))
        XCTAssertEqual(form.collected(values: [:], flags: [:])["tools"], .array([.string("read"), .string("write")]))
        XCTAssertEqual(
            form.collected(values: [:], flags: ["tools.read": false, "tools.run": true])["tools"],
            .array([.string("write"), .string("run")]))
    }

    func testSavedChecklistChoicesMissingFromTheCatalogRemainVisibleAndSubmitted() throws {
        let form = try form(
            #"[{"name":"tools","kind":"checklist","default":["read","saved-tool"],"options":[{"value":"read","label":"Read files"}]}]"#
        )
        XCTAssertEqual(form.options(form.fields[0]).map(\.value), ["read", "saved-tool"])
        XCTAssertEqual(form.options(form.fields[0]).last?.label, "saved-tool")
        XCTAssertEqual(
            form.collected(values: [:], flags: [:])["tools"], .array([.string("read"), .string("saved-tool")]))
    }

    func testActionDescriptorsWithMissingOrBlankLabelsStayUnavailable() throws {
        let form = try form(
            "[]",
            actions:
                #","actions":[{"action":"chrome_llm_models"},{"label":" ","action":"chrome_llm_test"},{"label":"Load models","action":"chrome_llm_models"}]"#
        )
        XCTAssertEqual(form.actions.map(\.available), [false, false, true])
        XCTAssertEqual(form.actions.map(\.label), ["Unavailable action", "Unavailable action", "Load models"])
    }

    func testBothVisibilityConditionsUseDefaultsAndEditedTypedValues() throws {
        let form = try form(
            #"[{"name":"mode","kind":"select","default":"automatic","options":["automatic","manual"]},{"name":"enabled","kind":"boolean","default":true},{"name":"detail","kind":"text","visible_when":{"mode":"manual","enabled":true}},{"name":"legacy","kind":"text","visible_when":{"field":"mode","equals":"manual"}}]"#
        )
        XCTAssertFalse(form.visible(form.fields[2], values: [:], flags: [:]))
        XCTAssertTrue(form.visible(form.fields[2], values: ["mode": "manual"], flags: [:]))
        XCTAssertFalse(form.visible(form.fields[2], values: ["mode": "manual"], flags: ["enabled": false]))
        XCTAssertTrue(form.visible(form.fields[3], values: ["mode": "manual"], flags: [:]))
    }

    func testActionsKeepDistinctRoutingAndMalformedActionIsUnavailable() throws {
        let form = try form(
            "[]",
            actions:
                #","actions":[{"label":"Load models","action":"chrome_llm_models"},{"label":"Test connection","action":"chrome_llm_test"},{"label":"Save","action":"chrome_llm_save"},{"label":"Save TypeSafe key","action":"chrome_typesafe_save"},{"label":"Missing action"}]"#
        )
        XCTAssertEqual(
            form.actions.map(\.label),
            ["Load models", "Test connection", "Save", "Save TypeSafe key", "Missing action"])
        XCTAssertEqual(
            form.actions.map(\.action),
            ["chrome_llm_models", "chrome_llm_test", "chrome_llm_save", "chrome_typesafe_save", nil])
        XCTAssertFalse(form.actions.last!.available)
        XCTAssertTrue(form.actions.prefix(4).allSatisfy(\.available))
    }

    func testBlankPasswordsNeverAdoptServerDefaultsAndNumbersRemainTyped() throws {
        let form = try form(
            #"[{"name":"api_key","kind":"password","default":"must-not-display"},{"name":"count","kind":"number","default":3},{"name":"title","label":"Title","kind":"text","required":true}]"#
        )
        XCTAssertEqual(form.stringValue(form.fields[0], values: [:]), "")
        XCTAssertEqual(form.collected(values: [:], flags: [:])["api_key"], .string(""))
        XCTAssertEqual(form.collected(values: ["count": "4.5"], flags: [:])["count"], .number(4.5))
        XCTAssertEqual(form.validationMessage(values: [:], flags: [:]), "Title is required.")
        XCTAssertEqual(
            form.validationMessage(values: ["title": "Ready", "count": "NaN"], flags: [:]),
            "count must be a valid number.")
        XCTAssertNil(form.validationMessage(values: ["title": "Ready", "count": "4.5"], flags: [:]))
    }
}
