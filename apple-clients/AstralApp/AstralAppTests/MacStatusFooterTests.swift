// Covers the Mac status footer: item wording, glyph and attention for every state, the usage tally fed by
// llm_usage_report and cleared on sign-out, its actions, and renders in the three reference themes.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacStatusFooterTests: XCTestCase {
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func usage(_ frames: [[String: JSONValue]]) -> LLMUsageTally {
            var tally = LLMUsageTally()
            for fields in frames {
                var payload = fields
                payload["type"] = .string("llm_usage_report")
                if let report = LLMUsageReport(frame: InboundFrame(name: "llm_usage_report", payload: .object(payload)))
                {
                    tally.record(report)
                }
            }
            return tally
        }

        private static let dispatch: [String: JSONValue] = [
            "feature": .string("chat_dispatch"), "model": .string("test-model"), "prompt_tokens": .number(3_210),
            "completion_tokens": .number(450), "total_tokens": .number(3_660), "outcome": .string("success"),
        ]

        private func host(available: Bool) throws -> MacComputerHost {
            let suite = "MacStatusFooterTests.\(UUID().uuidString)"
            suites.append(suite)
            return MacComputerHost(
                available: available, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                permissionProvider: { MacComputerPermissions(accessibility: false, screen: false, monitoring: false) })
        }

        private func model(host: MacComputerHost? = nil) throws -> AppModel {
            let suite = "MacStatusFooterTests.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults, computerHost: host)
            model.signedIn = true
            model.connected = true
            model.outboundTap = { _ in }
            return model
        }

        func testConnectionStatesUseDistinctGlyphsAndWords() {
            XCTAssertEqual(
                MacStatusFooterModel.connection(connected: true, everConnected: true, failed: true), .connected)
            XCTAssertEqual(
                MacStatusFooterModel.connection(connected: false, everConnected: true, failed: false), .reconnecting)
            XCTAssertEqual(
                MacStatusFooterModel.connection(connected: false, everConnected: false, failed: true), .offline)
            XCTAssertEqual(
                MacStatusFooterModel.connection(connected: false, everConnected: false, failed: false), .connecting)
            let items = [MacStatusFooterModel.Connection.connected, .connecting, .reconnecting, .offline].map {
                MacStatusFooterModel.items(connection: $0, usage: LLMUsageTally(), approvals: 0, computer: nil)
            }
            XCTAssertTrue(
                items.allSatisfy { $0.count == 1 && $0[0].kind == .connection && $0[0].label == "Connection" })
            XCTAssertEqual(items.map { $0[0].text }, ["Connected", "Connecting…", "Reconnecting…", "Offline"])
            XCTAssertEqual(Set(items.map { $0[0].symbol }).count, 4)
            XCTAssertEqual(items.map { $0[0].attention }, [false, false, true, true])
        }

        func testUsageApprovalsAndComputerItemsAppearOnlyWithTheirState() {
            let tally = usage([Self.dispatch])
            let items = MacStatusFooterModel.items(
                connection: .connected, usage: tally, approvals: 2,
                computer: .init(enabled: true, sessionState: "paused", statusLabel: "Computer task paused"))
            XCTAssertEqual(items.map(\.kind), [.connection, .model, .tokens, .approvals, .computer])
            XCTAssertEqual(items[1].text, "test-model")
            XCTAssertEqual(items[2].text, "3.2k context · 3.6k total")
            XCTAssertEqual(items[2].value, "Context 3,210 tokens, 3,660 tokens this session")
            XCTAssertEqual(items[3].text, "2 approvals waiting")
            XCTAssertTrue(items[3].attention)
            XCTAssertEqual(items[4].text, "Computer paused")
            XCTAssertEqual(items[4].value, "Computer task paused")
            let titleOnly = usage([
                [
                    "feature": .string("chat_title"), "model": .string("m"), "total_tokens": .number(80),
                    "outcome": .string("success"),
                ]
            ])
            let single = MacStatusFooterModel.items(
                connection: .connected, usage: titleOnly, approvals: 1,
                computer: .init(enabled: false, sessionState: nil, statusLabel: "Computer access is off"))
            XCTAssertEqual(single[2].text, "80 tokens")
            XCTAssertEqual(single[2].value, "80 tokens this session")
            XCTAssertEqual(single[3].text, "1 approval waiting")
            XCTAssertEqual(single[4].text, "Computer off")
            XCTAssertFalse(single[4].attention)
            let modelOnly = usage([["model": .string("m"), "outcome": .string("failure")]])
            XCTAssertEqual(
                MacStatusFooterModel.items(connection: .connected, usage: modelOnly, approvals: 0, computer: nil)
                    .map(\.kind), [.connection, .model])
            XCTAssertEqual(
                MacStatusFooterModel.items(
                    connection: .connected, usage: LLMUsageTally(), approvals: 0,
                    computer: .init(enabled: true, sessionState: "active", statusLabel: "Computer task active")
                ).last?.text, "Computer active")
            XCTAssertEqual(
                MacStatusFooterModel.items(
                    connection: .connected, usage: LLMUsageTally(), approvals: 0,
                    computer: .init(enabled: true, sessionState: nil, statusLabel: "on")
                ).last?.text, "Computer on")
        }

        func testTokenCountsAreCompact() {
            XCTAssertEqual(
                [0, 950, 1_000, 1_234, 9_999, 12_400, 999_999, 1_250_000, 12_000_000].map(
                    MacStatusFooterModel.compact),
                ["0", "950", "1k", "1.2k", "9.9k", "12k", "999k", "1.2M", "12M"])
        }

        func testUsageReportsFeedTheMacModelAndSignOutClearsThem() async throws {
            let model = try model()
            var payload = Self.dispatch
            payload["type"] = .string("llm_usage_report")
            model.handleFrame(InboundFrame(name: "llm_usage_report", payload: .object(payload)))
            XCTAssertEqual(model.llmUsage.model, "test-model")
            XCTAssertEqual(model.llmUsage.sessionTokens, 3_660)
            XCTAssertEqual(model.llmUsage.contextTokens, 3_210)
            XCTAssertNil(model.errorBanner)
            await model.signOut(revokeRemote: false)
            XCTAssertTrue(model.llmUsage.isEmpty)
        }

        func testFooterRendersEveryItemInEachThemeAndItsActionsOpenActivityAndControls() async throws {
            let host = try host(available: true)
            for preset in SurfaceFixtures.presets {
                let model = try model(host: host)
                var payload = Self.dispatch
                payload["type"] = .string("llm_usage_report")
                model.handleFrame(InboundFrame(name: "llm_usage_report", payload: .object(payload)))
                model.activeChatId = "footer-chat"
                model.handleFrame(
                    ActivityFrames.step(
                        "step-click", chat: "footer-chat", status: "in_progress", arguments: #"{"x":10,"y":20}"#))
                model.handleFrame(
                    ActivityFrames.step(
                        "step-click", chat: "footer-chat", status: "completed",
                        result: #"{"_data":{"status":"confirmation_required"}}"#))
                XCTAssertEqual(model.activity.filter { $0.approval == .waiting }.count, 1)
                var activity = 0
                let mount = SurfaceMount(
                    MacStatusFooter { activity += 1 }, model: model, size: CGSize(width: 900, height: 26),
                    preset: preset)
                defer { mount.close() }
                try await mount.settle()
                let text = try mount.text()
                for kept in ["Connected", "test-model", "3.2k context", "1 approval waiting", "Computer off"] {
                    XCTAssertTrue(text.contains(kept), "\(preset) missing \(kept): \(text)")
                }
                try mount.snapshot(self, name: "status_footer-\(preset)")
                try mount.click(text: "1 approval waiting")
                try await mount.settle()
                XCTAssertEqual(activity, 1, preset)
                host.controlsPresented = false
                try mount.click(text: "Computer off")
                try await mount.settle()
                XCTAssertTrue(host.controlsPresented, preset)
                host.controlsPresented = false
                model.connected = false
                model.everConnected = true
                try await mount.settle()
                XCTAssertTrue(try mount.text().contains("Reconnecting"), preset)
                try mount.snapshot(self, name: "status_footer_reconnecting-\(preset)")
            }
        }

        func testFooterSitsUnderTheComposerInTheWorkbench() async throws {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            model.outboundTap = { _ in }
            let fixture = try SurfaceFixtures.json("mac-workbench")
            let row = try XCTUnwrap(
                fixture["cases"]?.arrayValue?.first { $0["viewport"]?.arrayValue?.first?.numberValue == 1440 })
            model.handleFrame(
                InboundFrame(
                    name: "rote_config",
                    payload: .object([
                        "type": .string("rote_config"),
                        "device_profile": .object(["console": try XCTUnwrap(row["presentation"])]),
                    ])))
            let console = try XCTUnwrap(model.console)
            let presentation = try XCTUnwrap(model.consolePresentation)
            for preset in SurfaceFixtures.presets {
                let mount = SurfaceMount(
                    MacWorkbenchView(
                        console: console, presentation: presentation,
                        workbench: try XCTUnwrap(presentation.workbench)),
                    model: model, size: CGSize(width: 1440, height: 900), preset: preset)
                defer { mount.close() }
                try await mount.settle()
                let connected = try XCTUnwrap(mount.textFrame("Connected"), preset)
                XCTAssertGreaterThan(connected.minY, 900 - 40, "\(connected)")
                try mount.snapshot(self, name: "workbench_status_footer-\(preset)")
            }
        }

        func testFooterItemsExposeLabelsAndValuesToAccessibility() async throws {
            try SurfaceAccessibility.requireTrust()
            let model = try model(host: try host(available: true))
            var payload = Self.dispatch
            payload["type"] = .string("llm_usage_report")
            model.handleFrame(InboundFrame(name: "llm_usage_report", payload: .object(payload)))
            let mount = SurfaceMount(MacStatusFooter {}, model: model, size: CGSize(width: 900, height: 26))
            defer { mount.close() }
            try await mount.settle()
            let tree = mount.accessibility
            let connection = try XCTUnwrap(tree.first { $0.identifier == "workbench-status-connection" })
            XCTAssertEqual(connection.label, "Connection")
            XCTAssertEqual(connection.value, "Connected")
            XCTAssertEqual(tree.first { $0.identifier == "workbench-status-model" }?.value, "test-model")
            XCTAssertEqual(
                tree.first { $0.identifier == "workbench-status-tokens" }?.value,
                "Context 3,210 tokens, 3,660 tokens this session")
            let computer = try XCTUnwrap(tree.first { $0.identifier == "workbench-status-computer" })
            XCTAssertEqual(computer.label, "This Mac")
            XCTAssertEqual(computer.role, kAXButtonRole)
        }
    }
#endif
