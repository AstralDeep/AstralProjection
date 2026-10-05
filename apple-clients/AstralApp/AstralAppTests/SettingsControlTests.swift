// Verifies settings controls preserve authoritative state and recover honestly from unavailable transport.
// Uses AppModel's normal reducers and action submission without live credentials or chat queries.

import AstralCore
@testable import AstralDeep
import SwiftUI
import XCTest

@MainActor
final class SettingsControlTests: XCTestCase {
    func testUncertainGuidanceWriteRetryReturnsToListAndKeepsOfflineFailureVisible() {
        let model = model()
        model.screen = .surface
        model.pendingSurfaceKey = "guidance"
        model.pendingSurfaceParams = .object(["mode": .string("new")])
        model.guidanceFailed = true
        model.surfaceFailureMessage = "The write could not be confirmed."
        model.retryPendingSurface()
        XCTAssertEqual(model.pendingSurfaceParams, .object(["mode": .string("list")]))
        XCTAssertTrue(model.guidanceFailed)
        XCTAssertNotNil(model.surfaceFailureMessage)
        XCTAssertNil(model.guidanceState.generation)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }

    private func model() -> AppModel {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.signedIn = true
        return model
    }

    private func themeSurface(_ preset: String) throws -> InboundFrame {
        try XCTUnwrap(
            InboundFrame.parse(
                "{\"type\":\"chrome_surface\",\"surface_key\":\"theme\",\"title\":\"Theme\",\"mode\":\"replace\",\"components\":[{\"type\":\"theme_apply\",\"preset\":\"\(preset)\"}]}"
            ))
    }

    func testFirstConnectionNeverLooksLikeAConfirmedEmptyAccount() async {
        let model = model()
        XCTAssertEqual(model.connectionStripLabel, "Connecting…")
        await model.handle(.disconnected(reason: "Connection refused"))
        XCTAssertEqual(model.connectionStripLabel, "Couldn't connect. Check your connection and retry.")
        await model.handle(.connected)
        XCTAssertNil(model.connectionStripLabel)
        await model.handle(.disconnected(reason: "Connection lost"))
        XCTAssertEqual(model.connectionStripLabel, "Reconnecting…")
    }

    func testAcceptedThemeSurfaceAndReplacementApplyWithoutMountingARenderer() throws {
        let model = model()
        model.connected = true
        model.openSurface("theme")
        model.handleFrame(try themeSurface("daylight"))
        let expected = ThemeStore()
        expected.apply(preset: "daylight")
        XCTAssertEqual(model.themeStore.palette, expected.palette)
        model.sendEvent("chrome_theme_preset", .object(["preset": .string("ocean")]))
        model.handleFrame(try themeSurface("ocean"))
        expected.apply(preset: "ocean")
        XCTAssertEqual(model.themeStore.palette, expected.palette)
        model.sendEvent("chrome_theme_preset", .object(["preset": .string("forest")]))
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    #"{"type":"chrome_surface","surface_key":"theme","title":"Theme","mode":"replace","components":[{"type":"alert","variant":"error","message":"Failed to save theme"}]}"#
                )))
        XCTAssertEqual(model.themeStore.palette, expected.palette)
    }

    func testSurfaceEchoRejectsStaleWrongSurfaceAndResponsesAfterCloseOrDisconnect() async throws {
        let model = model()
        model.connected = true
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("theme")
        let first = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.retryPendingSurface()
        let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        func reply(_ generation: String) throws -> InboundFrame {
            let frame = try themeSurface("ocean")
            var payload = frame.payload.objectValue!
            payload["request_generation"] = .string(generation)
            return InboundFrame(name: frame.name, payload: .object(payload))
        }
        model.handleFrame(try reply(first))
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(try reply(current))
        let accepted = try XCTUnwrap(model.pendingSurface)
        model.handleFrame(try reply(first))
        XCTAssertEqual(model.pendingSurface, accepted)
        model.openSurface("llm")
        model.handleFrame(try reply(current))
        XCTAssertNil(model.pendingSurface)
        XCTAssertNil(model.errorBanner)
        model.handleFrame(
            InboundFrame(
                name: "chrome_surface",
                payload: .object([
                    "surface_key": .string(""), "components": .array([]), "request_generation": .string(first),
                ])))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "llm")
        model.openSurface("theme")
        let closing = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.closeSurface()
        model.handleFrame(try reply(closing))
        XCTAssertNil(model.pendingSurface)
        XCTAssertNil(model.errorBanner)
        model.openSurface("theme")
        let disconnecting = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        await model.handle(.disconnected(reason: "Synthetic failure"))
        model.handleFrame(try reply(disconnecting))
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.surfaceFailureMessage, "The connection was lost. Reconnect and retry this screen.")
    }

    func testCustomColorSubmissionWaitsForAcceptedThemeAndCannotDuplicateOrUseInvalidColors() throws {
        let model = model()
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("theme")
        model.handleFrame(try themeSurface("midnight"))
        sent = []
        XCTAssertFalse(model.saveThemeColor(key: "primary", value: "bad"))
        XCTAssertFalse(model.saveThemeColor(key: "unknown", value: "#123ABC"))
        XCTAssertTrue(model.saveThemeColor(key: "primary", value: "#123ABC"))
        XCTAssertFalse(model.saveThemeColor(key: "primary", value: "#123ABC"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["payload"]?["theme"]?["color_value"], .string("#123ABC"))
        XCTAssertEqual(model.themeStore.palette, .midnight)
        XCTAssertTrue(model.paramPickerPending(action: "save_theme"))
    }

    func testSystemAppearanceFollowsAcceptedBackgroundInsteadOfAlwaysUsingDarkControls() {
        let theme = ThemeStore()
        XCTAssertEqual(theme.colorScheme, .dark)
        theme.apply(preset: "daylight")
        XCTAssertEqual(theme.colorScheme, .light)
        theme.apply(spec: .object(["color_key": .string("bg"), "color_value": .string("#101010")]))
        XCTAssertEqual(theme.colorScheme, .dark)
    }

    func testUnsolicitedWrongSurfaceCannotApplyThemeButPreferenceUpdatesCan() throws {
        let model = model()
        model.openSurface("llm")
        model.handleFrame(try themeSurface("ocean"))
        XCTAssertEqual(model.themeStore.palette, .midnight)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(#"{"type":"user_preferences","theme":{"preset":"forest"}}"#)))
        let expected = ThemeStore()
        expected.apply(preset: "forest")
        XCTAssertEqual(model.themeStore.palette, expected.palette)
    }

    func testProviderActionsRejectUnavailableTransportWithoutClaimingSubmission() {
        for action in ["chrome_llm_models", "chrome_llm_test", "chrome_llm_save", "chrome_typesafe_save"] {
            let model = model()
            var frames: [String] = []
            model.outboundTap = { frames.append($0) }
            XCTAssertFalse(
                model.submitParamPicker(action: action, fields: ["provider": .string("custom")], payload: [:]))
            XCTAssertTrue(frames.isEmpty, action)
        }
    }

    func testServerButtonsCanNavigateBetweenOrdinarySettingsSurfaces() throws {
        let model = model()
        model.connected = true
        model.openSurface("agents")
        let parameters: JSONValue = .object(["mode": .string("drafts")])
        model.emit("chrome_open", payload: ["surface": .string("drafts"), "params": parameters])
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "drafts")
        XCTAssertEqual(model.pendingSurfaceParams, parameters)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    #"{"type":"chrome_surface","surface_key":"drafts","title":"Drafts","components":[{"type":"text","content":"Available drafts"}]}"#
                )))
        XCTAssertEqual(model.pendingSurface?.title, "Drafts")
        XCTAssertNil(model.errorBanner)
        model.mandatorySurface = true
        model.emit("chrome_open", payload: ["surface": .string("theme")])
        XCTAssertEqual(model.pendingSurfaceKey, "drafts")
    }

    func testCompletedSupersededActionDoesNotBlockTheOnlyCurrentLegacyReply() throws {
        let model = model()
        model.connected = true
        let connection = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(model.beginConversationConnection(connection))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("theme")
        model.handleFrame(try themeSurface("midnight"))
        model.sendEvent("chrome_theme_preset", .object(["preset": .string("forest")]))
        let first = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.sendEvent(
            "save_theme",
            .object(["theme": .object(["color_key": .string("primary"), "color_value": .string("#123ABC")])]))
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"22222222-2222-4222-8222-222222222222",
                    "action":"chrome_theme_preset","surface":"theme","chat_id":null,
                    "connection_generation":"\(connection)","request_generation":"\(first)",
                    "sequence":1,"state":"completed","phase":"completed","label":"Theme saved",
                    "terminal":true,"retryable":false,"error":null,"retry_after_ms":null,
                    "updated_at":"2026-10-05T18:00:00Z"}
                    """)))
        model.handleFrame(try themeSurface("ocean"))
        let expected = ThemeStore()
        expected.apply(preset: "ocean")
        XCTAssertEqual(model.themeStore.palette, expected.palette)
    }

    func testSettingsFormAndColorIdentitySurviveInsertedServerNotices() throws {
        let controls = AstralComponent.list(
            from: try JSONValue.parse(
                Data(
                    ##"[{"type":"color_picker","color_key":"primary","value":"#123ABC"},{"type":"param_picker","fields":[{"name":"provider","kind":"select"}]}]"##
                        .utf8)))
        let initial = SurfaceView.componentKeys(controls)
        let notice = AstralComponent(
            type: "alert", raw: .object(["type": .string("alert"), "message": .string("Save refused")]))
        XCTAssertEqual(Array(SurfaceView.componentKeys([notice] + controls).dropFirst()), initial)
    }

    func testOwnedValidationErrorDoesNotShowCompletedAfterTransportTerminal() throws {
        let model = model()
        model.connected = true
        let connection = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(model.beginConversationConnection(connection))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("llm")
        model.handleFrame(
            try XCTUnwrap(InboundFrame.parse(#"{"type":"chrome_surface","surface_key":"llm","components":[]}"#)))
        XCTAssertTrue(
            model.submitParamPicker(action: "chrome_llm_models", fields: ["provider": .string("openai")], payload: [:]))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"chrome_surface","surface_key":"llm","request_generation":"\(request)",
                    "components":[{"type":"alert","variant":"error","message":"An API key is required to load models."}]}
                    """)))
        XCTAssertFalse(model.paramPickerPending(action: "chrome_llm_models"))
        let operation = "22222222-2222-4222-8222-222222222222"
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"\(operation)","action":"chrome_llm_models",
                    "surface":"llm","chat_id":null,"connection_generation":"\(connection)","request_generation":"\(request)",
                    "sequence":1,"state":"completed","phase":"completed","label":"Completed","terminal":true,
                    "retryable":false,"error":null,"retry_after_ms":null,"updated_at":"2026-10-05T18:00:00Z"}
                    """)))
        XCTAssertEqual(model.operationStatuses[operation]?.state, "completed")
        XCTAssertNil(model.paramPickerStatus(action: "chrome_llm_models"))
        XCTAssertFalse(model.paramPickerCompleted(action: "chrome_llm_models"))
    }

    func testCustomColorRepaintsOnlyOnCurrentAcceptedResultAndEndsPendingWithoutLifecycleFrame() throws {
        let model = model()
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("theme")
        model.handleFrame(try themeSurface("midnight"))
        XCTAssertTrue(model.saveThemeColor(key: "primary", value: "#123ABC"))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"chrome_surface","surface_key":"theme","request_generation":"\(request)",
                    "components":[{"type":"theme_apply","colors":{"primary":"#123ABC"}}]}
                    """)))
        XCTAssertEqual(model.themeStore.palette.primary, Color(cssHex: "#123ABC"))
        XCTAssertFalse(model.paramPickerPending(action: "save_theme"))
        XCTAssertNil(model.paramPickerStatus(action: "save_theme"))
    }

    func testThemeFailureKeepsTheLoadedColorControlsAndTheirStateIdentity() throws {
        let model = model()
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("theme")
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    ##"{"type":"chrome_surface","surface_key":"theme","components":[{"type":"color_picker","color_key":"primary","value":"#6366F1"}]}"##
                )))
        let previous = try XCTUnwrap(model.pendingSurface?.components.first)
        XCTAssertTrue(model.saveThemeColor(key: "primary", value: "#123ABC"))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"chrome_surface","surface_key":"theme","request_generation":"\(request)",
                    "components":[{"type":"alert","variant":"error","message":"The color could not be saved."}]}
                    """)))
        XCTAssertEqual(model.pendingSurface?.components.last, previous)
        XCTAssertEqual(model.themeStore.palette, .midnight)
        XCTAssertFalse(model.paramPickerPending(action: "save_theme"))
        XCTAssertNil(model.paramPickerStatus(action: "save_theme"))
    }

    func testLatestQueuedOrdinaryReadRebindsToTheRegisteredConnection() async throws {
        let model = model()
        var sent: [String] = []
        model.outboundTap = { sent.append($0) }
        model.openSurface("theme")
        let first = try XCTUnwrap(QueuedOperationReplay(frameText: try XCTUnwrap(sent.last)))
        model.retryPendingSurface()
        let latest = try XCTUnwrap(QueuedOperationReplay(frameText: try XCTUnwrap(sent.last)))
        await model.handle(.disconnected(reason: "Offline"))
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
        XCTAssertTrue(model.replayQueuedOperation(first))
        var reply = try themeSurface("daylight").payload.objectValue!
        reply["request_generation"] = .string(first.identity.requestGeneration)
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(reply)))
        XCTAssertNil(model.pendingSurface)
        XCTAssertTrue(model.replayQueuedOperation(latest))
        reply["request_generation"] = .string(latest.identity.requestGeneration)
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(reply)))
        XCTAssertNotNil(model.pendingSurface)
        XCTAssertNil(model.surfaceFailureMessage)
    }

    func testSavedProviderWarningSurvivesModalCloseWithoutBecomingAFailedSave() throws {
        let model = model()
        model.connected = true
        let connection = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(model.beginConversationConnection(connection))
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(#"{"type":"chrome_surface","mode":"mandatory","surface_key":"llm","components":[]}"#)
            ))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        XCTAssertTrue(
            model.submitParamPicker(action: "chrome_llm_save", fields: ["provider": .string("custom")], payload: [:]))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"22222222-2222-4222-8222-222222222222",
                    "action":"chrome_llm_save","surface":"llm_settings","chat_id":null,
                    "connection_generation":"\(connection)","request_generation":"\(request)",
                    "sequence":1,"state":"completed","phase":"completed","label":"Provider settings saved",
                    "terminal":true,"retryable":false,"error":null,"retry_after_ms":null,"updated_at":"2026-10-05T18:00:00Z"}
                    """)))
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertEqual(model.screen, .chat)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    #"{"type":"notification","title":"Provider settings saved","body":"Connection test failed: provider unavailable. Your saved settings remain available.","level":"warning"}"#
                )))
        XCTAssertEqual(model.llmFirstLoginOperation?.state, .completed)
        XCTAssertEqual(model.llmFirstLoginOperation?.presentedLabel, "Provider settings saved")
        XCTAssertEqual(
            model.errorBanner,
            "Provider settings saved: Connection test failed: provider unavailable. Your saved settings remain available."
        )
        XCTAssertFalse(model.bannerIsError)
        XCTAssertTrue(model.bannerIsWarning)
        model.errorBanner = "An unrelated notice"
        XCTAssertFalse(model.bannerIsWarning)
    }

    private func completedProviderSave() throws -> (AppModel, String) {
        let model = model()
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        model.connected = true
        let connection = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(model.beginConversationConnection(connection))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("llm")
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    #"{"type":"chrome_surface","surface_key":"llm","title":"AI provider","components":[{"type":"param_picker","fields":[{"name":"endpoint","kind":"text","default":"https://provider.example.test"}]}]}"#
                )))
        XCTAssertTrue(
            model.submitParamPicker(action: "chrome_llm_save", fields: ["provider": .string("custom")], payload: [:]))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"22222222-2222-4222-8222-222222222222",
                    "action":"chrome_llm_save","surface":"llm_settings","chat_id":null,
                    "connection_generation":"\(connection)","request_generation":"\(request)",
                    "sequence":1,"state":"completed","phase":"completed","label":"Provider settings saved",
                    "terminal":true,"retryable":false,"error":null,"retry_after_ms":null,"updated_at":"2026-10-05T18:00:00Z"}
                    """)))
        XCTAssertEqual(model.llmFirstLoginOperation?.state, .completed)
        XCTAssertEqual(model.screen, .surface)
        XCTAssertFalse(model.mandatorySurface)
        return (model, request)
    }

    private func ordinaryClose(_ generation: String) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "region": .string("modal"), "mode": .string("replace"), "surface_key": .string(""),
                "title": .string(""), "admin_only": .bool(false), "components": .array([]),
                "request_generation": .string(generation),
            ]))
    }

    func testCurrentCorrelatedProviderCloseAfterCompletedSaveDismissesAndRetiresOwnership() throws {
        let (model, request) = try completedProviderSave()
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.pendingSurfaceKey, "")
        XCTAssertEqual(model.pendingSurfaceParams, .object([:]))
        XCTAssertNil(model.surfaceFailureMessage)
        model.openSurface("llm")
        let reopened = model.pendingSurface
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "llm")
        XCTAssertEqual(model.pendingSurface, reopened)
    }

    func testDelayedProviderCloseCannotDismissNewThemeBeforeOrAfterItsResponse() throws {
        let (model, request) = try completedProviderSave()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        let params: JSONValue = .object(["editor": .string("custom")])
        model.openSurface("theme", params: params)
        let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        XCTAssertNotEqual(current, request)
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "theme")
        XCTAssertEqual(model.pendingSurfaceParams, params)
        XCTAssertNil(model.pendingSurface)
        var reply = try themeSurface("ocean").payload.objectValue!
        reply["request_generation"] = .string(current)
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(reply)))
        let accepted = try XCTUnwrap(model.pendingSurface)
        let palette = model.themeStore.palette
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurface, accepted)
        XCTAssertEqual(model.themeStore.palette, palette)
    }

    func testDelayedProviderCloseCannotDismissReopenedProviderDraft() throws {
        let (model, request) = try completedProviderSave()
        let loaded = try XCTUnwrap(model.pendingSurface)
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        let params: JSONValue = .object(["editor": .string("reopened")])
        model.openSurface("llm", params: params)
        let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        XCTAssertNotEqual(current, request)
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "llm")
        XCTAssertEqual(model.pendingSurfaceParams, params)
        XCTAssertEqual(model.pendingSurface, loaded)
        model.handleFrame(
            InboundFrame(
                name: "chrome_surface",
                payload: .object([
                    "surface_key": .string("llm"), "title": .string("AI provider"),
                    "request_generation": .string(current), "components": .array(loaded.components.map(\.raw)),
                ])))
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurface, loaded)
    }

    func testCorrelatedBlankCloseRejectsEveryNoncanonicalShapeWithoutConsumingTheCurrentRequest() throws {
        let (model, request) = try completedProviderSave()
        let loaded = model.pendingSurface
        let changes: [(String, JSONValue?)] = [
            ("surface_key", nil), ("surface_key", .null), ("title", nil), ("title", .string("Notice")),
            ("region", nil), ("region", .string("canvas")), ("mode", nil), ("mode", .string("mandatory")),
            ("mode", .string("append")), ("admin_only", nil), ("admin_only", .bool(true)),
            ("admin_only", .null), ("components", nil), ("components", .null),
            ("components", .array([.null])), ("selection", .null), ("selection", .object([:])),
            ("request_generation", .null), ("request_generation", .string("invalid")),
            ("request_generation", .string(request + " ")),
        ]
        for (key, value) in changes {
            var payload = ordinaryClose(request).payload.objectValue!
            payload[key] = value
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
            XCTAssertEqual(model.screen, .surface, "\(key): \(String(describing: value))")
            XCTAssertEqual(model.pendingSurface, loaded)
            XCTAssertEqual(model.pendingSurfaceKey, "llm")
        }
        model.handleFrame(ordinaryClose(request))
        XCTAssertEqual(model.screen, .chat)
    }

    func testCorrelatedProviderCloseCannotCrossOwnerConnectionNavigationOrPrivateSurfaceFences() async throws {
        for transition in [
            "account", "connection", "signed_out", "disconnect", "navigation", "guidance", "work", "mandatory",
        ] {
            let (model, request) = try completedProviderSave()
            switch transition {
            case "account":
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            case "connection":
                XCTAssertTrue(model.beginConversationConnection("33333333-3333-4333-8333-333333333333"))
            case "signed_out": model.signedIn = false
            case "disconnect": await model.handle(.disconnected(reason: "Synthetic disconnect"))
            case "navigation": model.goTo(.history)
            case "mandatory": model.mandatorySurface = true
            default: model.pendingSurfaceKey = transition
            }
            let screen = model.screen
            let surface = model.pendingSurface
            let key = model.pendingSurfaceKey
            let mandatory = model.mandatorySurface
            model.handleFrame(ordinaryClose(request))
            XCTAssertEqual(model.screen, screen, transition)
            XCTAssertEqual(model.pendingSurface, surface, transition)
            XCTAssertEqual(model.pendingSurfaceKey, key, transition)
            XCTAssertEqual(model.mandatorySurface, mandatory, transition)
        }
    }
}
