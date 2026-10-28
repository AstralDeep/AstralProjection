// Verifies settings controls preserve authoritative state and recover honestly from unavailable transport.
// Uses AppModel's normal reducers and action submission without live credentials or chat queries.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class SettingsControlTests: XCTestCase {
    func testSafetyControlsAreNeverSubmittedOffline() {
        let model = model()
        model.screen = .surface
        model.pendingSurfaceKey = "safety"
        model.connected = false
        var frames: [String] = []
        model.outboundTap = { frames.append($0) }
        for action in SafetySurfaceRequest.actions {
            let payload: JSONValue = .object(["surface": .string("safety"), "expected_revision": .number(7)])
            model.sendEvent(action, payload)
        }
        XCTAssertTrue(frames.isEmpty)
        XCTAssertNotNil(model.surfaceFailureMessage)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }

    func testSettledSafetyRequiresExplicitCurrentReadAfterConnectionOrAuthenticationLoss() async throws {
        for transition in ["disconnect", "authentication", "registration", "owner"] {
            let model = model()
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            model.openSurface("safety")
            let original = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
            let reply = safetySurface(original)
            model.handleFrame(reply)
            XCTAssertNotNil(model.pendingSurface, transition)
            XCTAssertNil(model.surfaceFailureMessage, transition)
            let staleControls = SafetySurfaceRequest.actions.map { action in
                var fields: [String: JSONValue] = ["surface": .string("safety")]
                if action == "chrome_safety_resume" { fields["expected_revision"] = .number(7) }
                let payload = JSONValue.object(fields)
                return { model.sendEvent(action, payload) }
            }
            switch transition {
            case "disconnect": await model.handle(.disconnected(reason: "Synthetic disconnect"))
            case "authentication": model.handleFrame(InboundFrame(name: "auth_required", payload: .object([:])))
            case "registration":
                XCTAssertTrue(model.beginConversationConnection("22222222-2222-4222-8222-222222222222"))
            default:
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            }
            XCTAssertNil(model.pendingSurface, transition)
            model.handleFrame(reply)
            XCTAssertNil(model.pendingSurface, transition)
            XCTAssertTrue(model.beginConversationConnection("33333333-3333-4333-8333-333333333333"))
            let beforeReconnect = sent.count
            await model.handle(.connected)
            XCTAssertEqual(sent.count, beforeReconnect, transition)
            for control in staleControls { control() }
            XCTAssertEqual(sent.count, beforeReconnect, transition)
            XCTAssertNil(model.pendingSurface, transition)
            model.openSurface("safety")
            XCTAssertEqual(sent.count, beforeReconnect + 1, transition)
            XCTAssertEqual(sent.last?["action"], .string("chrome_open"), transition)
            let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
            XCTAssertNotEqual(current, original, transition)
            for control in staleControls { control() }
            XCTAssertEqual(sent.count, beforeReconnect + 1, transition)
            model.handleFrame(reply)
            var uncorrelated = safetySurface(current).payload.objectValue!
            uncorrelated.removeValue(forKey: "request_generation")
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(uncorrelated)))
            var appended = safetySurface(current).payload.objectValue!
            appended["mode"] = .string("append")
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(appended)))
            XCTAssertNil(model.pendingSurface, transition)
            model.handleFrame(safetySurface(current))
            XCTAssertNotNil(model.pendingSurface, transition)
            XCTAssertNil(model.surfaceFailureMessage, transition)
            model.sendEvent("chrome_safety_verify", .object(["surface": .string("safety")]))
            XCTAssertEqual(sent.count, beforeReconnect + 2, transition)
            XCTAssertEqual(sent.last?["action"], .string("chrome_safety_verify"), transition)
        }
    }

    func testSafetyReadFailureCannotAuthorizeARetainedControl() throws {
        let model = model()
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("safety")
        let initial = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(safetySurface(initial))
        model.sendEvent(
            "chrome_safety_resume", .object(["surface": .string("safety"), "expected_revision": .number(7)]))
        let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        var failed = safetySurface(request).payload.objectValue!
        failed["components"] = .array([
            .object(["type": .string("alert"), "variant": .string("error"), "message": .string("Status unavailable")])
        ])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(failed)))
        XCTAssertEqual(model.pendingSurface?.components.map(\.type), ["alert"])
        model.sendEvent("chrome_safety_stop", .object(["surface": .string("safety")]))
        XCTAssertEqual(sent.count, 2)
        model.retryPendingSurface()
        XCTAssertEqual(sent.last?["action"], .string("chrome_open"))
        let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        model.handleFrame(safetySurface(current))
        model.sendEvent("chrome_safety_stop", .object(["surface": .string("safety")]))
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent.last?["action"], .string("chrome_safety_stop"))
    }

    func testSafetyRefusalAndTimeoutRetireControlsAndRecoverThroughExplicitRead() throws {
        for failure in ["refusal", "timeout"] {
            for settled in [false, true] {
                let model = model()
                model.connected = true
                XCTAssertTrue(model.beginConversationConnection("11111111-1111-4111-8111-111111111111"))
                model.mandatorySurface = true
                var sent: [JSONValue] = []
                model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
                model.openSurface("safety")
                if settled {
                    let initial = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
                    model.handleFrame(safetySurface(initial))
                    model.sendEvent("chrome_safety_stop", .object(["surface": .string("safety")]))
                    XCTAssertNotNil(model.pendingSurface)
                }
                let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
                let submission = try XCTUnwrap(sent.last?["submission_id"]?.stringValue)
                if failure == "timeout" {
                    model.failSafetyRequest(generation: nil)
                    model.failSafetyRequest(generation: "11111111-1111-4111-8111-111111111111")
                    XCTAssertEqual(model.safetyRequestGeneration, request)
                    model.failSafetyRequest(generation: request)
                } else {
                    model.handleFrame(
                        InboundFrame(
                            name: "error",
                            payload: .object([
                                "type": .string("error"), "submission_id": .string(submission),
                                "accepted": .bool(false), "code": .string("operation_failed"),
                                "message": .string("Status unavailable"), "retryable": .bool(true),
                                "retry_after_ms": .null,
                            ])))
                }
                XCTAssertNil(model.pendingSurface, failure)
                XCTAssertNil(model.safetyRequestGeneration, failure)
                XCTAssertNotNil(model.surfaceFailureMessage, failure)
                XCTAssertNil(model.localOperationSubmissions[submission], failure)
                XCTAssertTrue(model.mandatorySurface)
                model.handleFrame(safetySurface(request))
                XCTAssertNil(model.pendingSurface, failure)
                let beforeRetry = sent.count
                model.sendEvent("chrome_safety_verify", .object(["surface": .string("safety")]))
                XCTAssertEqual(sent.count, beforeRetry, failure)
                model.retryPendingSurface()
                XCTAssertEqual(sent.count, beforeRetry + 1, failure)
                XCTAssertEqual(sent.last?["action"], .string("chrome_open"), failure)
                let current = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
                XCTAssertNotEqual(current, request, failure)
                model.failSafetyRequest(generation: request)
                model.handleFrame(safetySurface(request))
                XCTAssertNil(model.pendingSurface, failure)
                XCTAssertEqual(model.safetyRequestGeneration, current, failure)
                model.handleFrame(safetySurface(current))
                XCTAssertNotNil(model.pendingSurface, failure)
                XCTAssertNil(model.surfaceFailureMessage, failure)
                model.sendEvent("chrome_safety_verify", .object(["surface": .string("safety")]))
                XCTAssertEqual(sent.count, beforeRetry + 2, failure)
            }
        }
    }

    private func safetySurface(_ generation: String) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("safety"),
                "title": .string("Emergency stop"), "region": .string("modal"),
                "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": .string(generation),
                "components": .array([
                    .object([
                        "type": .string("button"), "label": .string("Verify stopped work"),
                        "action": .string("chrome_safety_verify"),
                        "payload": .object(["surface": .string("safety")]),
                    ])
                ]),
            ]))
    }

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
        XCTAssertEqual(model.connectionStripLabel, "Couldn't connect.")
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

    private func rgb(_ color: Color) -> [Int] {
        let resolved = color.resolve(in: EnvironmentValues())
        return [resolved.red, resolved.green, resolved.blue].map { Int(($0 * 255).rounded()) }
    }

    func testGraphiteIsTheBakedDefaultAndEveryPresetOwnsItsSurface2() {
        let theme = ThemeStore()
        XCTAssertEqual(theme.palette, .graphite)
        XCTAssertEqual(theme.colorScheme, .dark)
        let graphite = AstralPalette.graphite
        XCTAssertEqual(
            [graphite.bg, graphite.surface, graphite.surface2, graphite.primary, graphite.secondary].map(rgb),
            [[18, 18, 20], [27, 27, 31], [35, 35, 40], [124, 58, 237], [110, 110, 120]])
        XCTAssertEqual(
            [graphite.accent, graphite.text, graphite.muted].map(rgb),
            [[167, 139, 250], [236, 236, 239], [147, 147, 155]])
        XCTAssertEqual(
            [graphite.success, graphite.warning, graphite.error, graphite.info].map(rgb),
            [[94, 194, 143], [212, 169, 74], [225, 114, 114], [154, 140, 242]])
        XCTAssertEqual([graphite.onError, graphite.fieldBorder].map(rgb), [[18, 18, 20], [110, 110, 117]])
        XCTAssertEqual(graphite.border, Color.white.opacity(0.08))
        theme.apply(preset: "midnight")
        XCTAssertEqual(theme.palette, .midnight)
        XCTAssertEqual(
            [theme.palette.bg, theme.palette.surface, theme.palette.surface2, theme.palette.primary].map(rgb),
            [[15, 18, 33], [26, 30, 46], [30, 35, 56], [99, 102, 241]])
        XCTAssertEqual(
            [theme.palette.secondary, theme.palette.accent, theme.palette.text, theme.palette.muted].map(rgb),
            [[139, 92, 246], [6, 182, 212], [243, 244, 246], [156, 163, 175]])
        var surfaces = [rgb(graphite.surface2)]
        for preset in ["midnight", "daylight", "ocean", "sunset", "forest"] {
            theme.apply(preset: preset)
            XCTAssertFalse(surfaces.contains(rgb(theme.palette.surface2)), preset)
            surfaces.append(rgb(theme.palette.surface2))
            XCTAssertEqual(
                rgb(theme.palette.onError), preset == "daylight" ? [255, 255, 255] : rgb(theme.palette.bg), preset)
        }
        theme.apply(preset: "retired")
        XCTAssertEqual(theme.palette, .graphite)
    }

    func testDaylightOwnsDarkStatusTextAndALightDangerLabel() {
        let theme = ThemeStore()
        theme.apply(preset: "daylight")
        let palette = theme.palette
        XCTAssertEqual(
            [palette.success, palette.warning, palette.error, palette.info].map(rgb),
            [[20, 119, 57], [149, 91, 6], [185, 28, 28], [67, 56, 202]])
        XCTAssertEqual([palette.onError, palette.fieldBorder].map(rgb), [[255, 255, 255], [127, 138, 155]])
        XCTAssertEqual([palette.muted, palette.accent].map(rgb), [[88, 102, 123], [6, 117, 144]])
        XCTAssertEqual(AstralPalette.daylight, palette)
    }

    private func linear(_ byte: Int) -> Double {
        let unit = Double(byte) / 255
        return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
    }

    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double {
            0.2126 * linear(Int(c[0].rounded())) + 0.7152 * linear(Int(c[1].rounded()))
                + 0.0722 * linear(Int(c[2].rounded()))
        }
        let pair = [luminance(a), luminance(b)]
        return (pair.max()! + 0.05) / (pair.min()! + 0.05)
    }

    private func channels(_ color: Color) -> [Double] { rgb(color).map(Double.init) }

    private func tinted(_ color: Color, over base: Color) -> [Double] {
        zip(channels(color), channels(base)).map { $0 * 0.14 + $1 * 0.86 }
    }

    func testEveryPresetKeepsTextAtFourAndAHalfAndBoundariesAtThreeToOne() {
        let theme = ThemeStore()
        for preset in ["graphite", "midnight", "daylight", "ocean", "sunset", "forest"] {
            theme.apply(preset: preset)
            let p = theme.palette
            let surfaces = [p.bg, p.surface, p.surface2]
            for (role, color) in [
                ("text", p.text), ("muted", p.muted), ("accent", p.accent), ("success", p.success),
                ("warning", p.warning), ("error", p.error), ("info", p.info),
            ] {
                for surface in surfaces {
                    XCTAssertGreaterThanOrEqual(contrast(channels(color), channels(surface)), 4.5, "\(preset) \(role)")
                }
            }
            for base in [p.bg, p.surface] {
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.muted), tinted(p.muted, over: base)), 4.5, "\(preset) neutral badge")
            }
            for (role, color) in [("success", p.success), ("warning", p.warning), ("error", p.error), ("info", p.info)]
            {
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(color), tinted(color, over: p.surface)), 4.5, "\(preset) \(role) badge")
            }
            XCTAssertGreaterThanOrEqual(contrast(channels(p.onError), channels(p.error)), 4.5, "\(preset) danger label")
            for surface in surfaces {
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.fieldBorder), channels(surface)), 3, "\(preset) field border")
            }
        }
    }

    private func tinted(_ color: Color, over base: Color, opacity: Double) -> [Double] {
        zip(channels(color), channels(base)).map { $0 * opacity + $1 * (1 - opacity) }
    }

    func testRendererContrastPairsHoldInEveryPreset() {
        let theme = ThemeStore()
        for preset in ["graphite", "midnight", "daylight", "ocean", "sunset", "forest"] {
            theme.apply(preset: preset)
            let p = theme.palette
            let surfaces = [p.bg, p.surface, p.surface2]
            XCTAssertGreaterThanOrEqual(contrast(channels(p.onError), channels(p.error)), 4.5, "\(preset) danger fill")
            for base in [p.bg, p.surface] {
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.error), tinted(p.error, over: base, opacity: 0.12)), 4.5,
                    "\(preset) compact danger label")
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.error), tinted(p.text, over: base, opacity: 0.06)), 4.5,
                    "\(preset) destructive settings label")
            }
            for surface in surfaces {
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.fieldBorder), channels(surface)), 3, "\(preset) field border")
                XCTAssertGreaterThanOrEqual(
                    contrast(channels(p.readablePrimary), channels(surface)), 4.5, "\(preset) primary text")
                XCTAssertEqual(
                    AstralPalette.contrast(p.readablePrimary, surface),
                    contrast(channels(p.readablePrimary), channels(surface)), accuracy: 0.01, preset)
            }
            XCTAssertEqual(p.textVariant(nil), p.readablePrimary, preset)
            XCTAssertEqual(p.textVariant("primary"), p.readablePrimary, preset)
            XCTAssertEqual(p.variant(nil), p.primary, "fills keep the primary role")
            for variant in ["error", "danger", "warning", "success", "info", "accent"] {
                XCTAssertEqual(p.textVariant(variant), p.variant(variant), "\(preset) \(variant)")
            }
        }
    }

    func testPrimaryTextSwitchesToAccentOnlyInPresetsWherePrimaryFails() {
        let theme = ThemeStore()
        for (preset, usesAccent) in [
            ("graphite", true), ("midnight", true), ("daylight", false), ("ocean", false), ("sunset", false),
            ("forest", false),
        ] {
            theme.apply(preset: preset)
            let p = theme.palette
            XCTAssertEqual(p.readablePrimary, usesAccent ? p.accent : p.primary, preset)
        }
    }

    func testColorsOnlyThemeDerivesAppleExtrasWhileNamedPresetsKeepTheirOwn() {
        let dark = ThemeStore()
        dark.apply(preset: "midnight")
        dark.applyPreferences(
            .object([
                "preferences": .object([
                    "theme": .object([
                        "colors": .object([
                            "bg": .string("#101010"), "surface": .string("#202020"), "primary": .string("#123ABC"),
                            "secondary": .string("#445566"), "text": .string("#F0F0F0"), "muted": .string("#909090"),
                            "accent": .string("#00AA88"),
                        ])
                    ])
                ])
            ]))
        XCTAssertEqual(rgb(dark.palette.surface2), [41, 41, 41])
        XCTAssertEqual(dark.palette.border, Color(hex: 0xF0F0F0).opacity(0.08))
        XCTAssertEqual(dark.palette.success, AstralPalette.graphite.success)
        XCTAssertEqual(dark.palette.info, AstralPalette.graphite.info)
        XCTAssertEqual(dark.palette.error, AstralPalette.graphite.error)
        XCTAssertEqual(dark.palette.onError, AstralPalette.graphite.onError)
        XCTAssertEqual(dark.palette.fieldBorder, AstralPalette.graphite.fieldBorder)
        let light = ThemeStore()
        light.apply(
            spec: .object(["bg": .string("#F0F0F0"), "surface": .string("#FFFFFF"), "text": .string("#202020")]))
        XCTAssertEqual(light.colorScheme, .light)
        XCTAssertEqual(light.palette.success, AstralPalette.daylight.success)
        XCTAssertEqual(light.palette.error, AstralPalette.daylight.error)
        XCTAssertEqual(light.palette.onError, AstralPalette.daylight.onError)
        XCTAssertEqual(light.palette.fieldBorder, AstralPalette.daylight.fieldBorder)
        XCTAssertEqual(rgb(light.palette.surface2), [245, 245, 245])
        XCTAssertEqual(light.palette.border, Color(hex: 0x202020).opacity(0.08))
        let explicit = ThemeStore()
        explicit.apply(
            spec: .object(["colors": .object(["surface": .string("#202020"), "surface2": .string("#303030")])]))
        XCTAssertEqual(rgb(explicit.palette.surface2), [48, 48, 48])
        let supplied = ThemeStore()
        supplied.apply(
            spec: .object([
                "colors": .object([
                    "bg": .string("#F0F0F0"), "error": .string("#AA0000"), "on_error": .string("#FFFFFF"),
                    "field_border": .string("#808080"),
                ])
            ]))
        XCTAssertEqual(rgb(supplied.palette.error), [170, 0, 0])
        XCTAssertEqual(rgb(supplied.palette.onError), [255, 255, 255])
        XCTAssertEqual(rgb(supplied.palette.fieldBorder), [128, 128, 128])
        XCTAssertEqual(supplied.palette.success, AstralPalette.daylight.success)
        let delivered = ThemeStore()
        delivered.apply(preset: "midnight")
        delivered.applyPreferences(
            .object([
                "preferences": .object([
                    "theme": .object([
                        "preset": .string("graphite"),
                        "colors": .object(["bg": .string("#121214"), "surface": .string("#1B1B1F")]),
                    ])
                ])
            ]))
        XCTAssertEqual(delivered.palette, .graphite)
        let stored = ThemeStore()
        stored.applyPreferences(.object(["preferences": .object(["theme": .object(["preset": .string("midnight")])])]))
        XCTAssertEqual(stored.palette, .midnight)
        let unrelated = ThemeStore()
        unrelated.apply(preset: "midnight")
        unrelated.applyPreferences(.object(["type": .string("user_preferences"), "preferences": .object([:])]))
        XCTAssertEqual(unrelated.palette, .midnight)
    }

    func testBannerStateCarriesAnIconAndNotOnlyItsHue() {
        XCTAssertEqual(BannerBar(text: "Failed", isError: true, onDismiss: {}).symbol, "xmark.octagon.fill")
        XCTAssertEqual(
            BannerBar(text: "Careful", isError: false, isWarning: true, onDismiss: {}).symbol,
            "exclamationmark.triangle.fill")
        XCTAssertEqual(BannerBar(text: "Saved", isError: false, onDismiss: {}).symbol, "info.circle.fill")
    }

    func testUnsolicitedWrongSurfaceCannotApplyThemeButPreferenceUpdatesCan() throws {
        let model = model()
        model.openSurface("llm")
        model.handleFrame(try themeSurface("ocean"))
        XCTAssertEqual(model.themeStore.palette, .graphite)
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

    #if os(iOS)
        func testSettingsTextInputRetainsEditsAcrossLongSurfaceScrolling() async throws {
            let model = model()
            model.connected = true
            let filler = (0..<24).map { index in
                AstralComponent(
                    type: "text",
                    raw: .object([
                        "type": .string("text"),
                        "content": .string(
                            "Section \(index): " + String(repeating: "Surface instructions. ", count: 20)),
                    ]))
            }
            let form = AstralComponent(
                type: "param_picker",
                raw: .object([
                    "type": .string("param_picker"), "title": .string("Enrollment"),
                    "fields": .array([
                        .object([
                            "name": .string("label"), "label": .string("Device name"),
                            "kind": .string("text"), "default": .string("Original"),
                        ])
                    ]),
                ]))
            model.pendingSurface = AppModel.SurfaceContent(
                surfaceKey: "mesh", title: "Mesh devices", components: filler + [form])
            let controller = UIHostingController(
                rootView: SurfaceView(embedded: true).environment(model).environment(model.themeStore))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = controller
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
                (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
            }
            func layout() async {
                for _ in 0..<4 {
                    await Task.yield()
                    window.layoutIfNeeded()
                    controller.view.layoutIfNeeded()
                }
            }
            await layout()
            let scroll = try XCTUnwrap(
                descendants(controller.view, UIScrollView.self).first { $0.contentSize.height > $0.bounds.height })
            for _ in 0..<3 {
                scroll.setContentOffset(
                    CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
                await layout()
            }
            let field = try XCTUnwrap(descendants(controller.view, UITextField.self).first { $0.text == "Original" })
            XCTAssertTrue(field.becomeFirstResponder())
            field.text = "Retained device label"
            field.sendActions(for: .editingChanged)
            field.resignFirstResponder()
            await layout()
            for offset in [scroll.contentSize.height - scroll.bounds.height, 0, scroll.contentSize.height / 2, 0] {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, offset)), animated: false)
                await layout()
                XCTAssertEqual(field.text, "Retained device label")
            }
            let notice = AstralComponent(
                type: "alert",
                raw: .object([
                    "type": .string("alert"), "message": .string("Inventory updated"),
                ]))
            model.pendingSurface = AppModel.SurfaceContent(
                surfaceKey: "mesh", title: "Mesh devices", components: [notice] + filler + [form])
            await layout()
            XCTAssertEqual(
                descendants(controller.view, UITextField.self).first { $0.text == "Retained device label" }?.text,
                "Retained device label")
        }
    #endif

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
        XCTAssertEqual(model.themeStore.palette, .graphite)
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
