// Renders representative settings surfaces through ComponentView in the compact Mac settings style and measures
// that controls keep one size across selection and stay compact; ASTRAL_SETTINGS_SNAPSHOT_DIR collects the PNGs.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import Vision
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class SettingsSurfaceSnapshotTests: XCTestCase {
        private struct Surface {
            let name: String
            let key: String
            let title: String
            let components: [AstralComponent]
        }

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func signedInModel() -> AppModel {
            let suite = "SettingsSurfaceSnapshotTests.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            return model
        }

        private func contract(_ path: String) throws -> JSONValue {
            var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<8 {
                let file = root.appendingPathComponent("contracts/fixtures/\(path)")
                if FileManager.default.fileExists(atPath: file.path) {
                    return try JSONValue.parse(Data(contentsOf: file))
                }
                root.deleteLastPathComponent()
            }
            throw CocoaError(.fileNoSuchFile)
        }

        private func bundled(_ name: String) throws -> JSONValue {
            let url = try XCTUnwrap(
                Bundle(for: SettingsSurfaceSnapshotTests.self).url(forResource: name, withExtension: "json"), name)
            return try JSONValue.parse(Data(contentsOf: url))
        }

        private func surface(_ name: String) throws -> Surface {
            let entry = try XCTUnwrap(bundled("SettingsSurfaceSnapshotFixtures")[name], name)
            return Surface(
                name: name, key: try XCTUnwrap(entry["surface_key"]?.stringValue),
                title: try XCTUnwrap(entry["title"]?.stringValue),
                components: AstralComponent.list(from: entry["components"]))
        }

        private func surface(_ name: String, contract path: String, state: String) throws -> Surface {
            let frame = try XCTUnwrap(contract(path)["frames"]?[state], "\(path) \(state)")
            return Surface(
                name: name, key: try XCTUnwrap(frame["surface_key"]?.stringValue),
                title: frame["title"]?.stringValue ?? "", components: AstralComponent.list(from: frame["components"]))
        }

        private func allSurfaces() throws -> [Surface] {
            try ["agents_list", "agents_detail", "llm", "personalization", "audit", "theme", "my_computers", "table"]
                .map(surface)
                + [
                    try surface("guidance_agents", contract: "guidance_088/agents_surface.json", state: "list"),
                    try surface("guidance_agent_new", contract: "guidance_088/agents_surface.json", state: "new"),
                    try surface("guidance_notes", contract: "guidance_088/notes_surface.json", state: "list"),
                    try surface("guidance_skills", contract: "guidance_088/skills_surface.json", state: "list"),
                    try surface("terminal_monitor", contract: "terminal/monitor_surface.json", state: "monitor"),
                    try surface("terminal_panel", contract: "terminal/panel_surface.json", state: "panel"),
                    try surface("saved_results", contract: "workspace_088/saved_results_surface.json", state: "list"),
                    try surface(
                        "saved_result_detail", contract: "workspace_088/saved_results_surface.json", state: "detail"),
                    try surface("recurring_work", contract: "workspace_088/recurring_work_surface.json", state: "list"),
                    try surface("connections", contract: "connections_088/connections_surface.json", state: "list"),
                ]
        }

        private final class Mount {
            let window: NSWindow
            let view: NSView

            init(_ root: some View, size: CGSize, scheme: ColorScheme, fitHeight: Bool) {
                let hosting = NSHostingView(rootView: root)
                window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                window.orderBack(nil)
                view = hosting
                hosting.layoutSubtreeIfNeeded()
                if fitHeight {
                    window.setContentSize(CGSize(width: size.width, height: max(1, hosting.fittingSize.height)))
                    hosting.layoutSubtreeIfNeeded()
                }
            }

            func settle(fitHeight: Bool) async throws {
                for _ in 0..<4 {
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                if fitHeight {
                    window.setContentSize(CGSize(width: view.bounds.width, height: max(1, view.fittingSize.height)))
                    view.layoutSubtreeIfNeeded()
                }
            }

            private func bitmap() throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }

            func png() throws -> Data {
                try XCTUnwrap(bitmap().representation(using: .png, properties: [:]))
            }

            func text() throws -> [String] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap().cgImage)).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }

            func close() {
                window.contentView = nil
                window.close()
            }
        }

        private func compact<V: View>(_ view: V, model: AppModel, theme: ThemeStore) -> some View {
            view
                .environment(\.astralCompactSettings, true)
                .environment(\.astralNavigationSurface, true)
                .environment(\.colorScheme, theme.colorScheme)
                .environment(model).environment(theme)
        }

        private func content(_ surface: Surface, theme: ThemeStore, width: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(zip(SurfaceView.componentKeys(surface.components), surface.components)), id: \.0) {
                    _, component in
                    ComponentView(component: component)
                        .environment(\.astralWorkReadSurface, ["work", "guidance", "evidence"].contains(surface.key))
                        .environment(\.astralGuidanceSurface, surface.key == "guidance")
                }
            }
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(theme.palette.bg)
            .environment(\.astralViewportWidth, width)
        }

        private func mount(
            _ surface: Surface, preset: String = "graphite", width: CGFloat = 760
        ) async throws -> Mount {
            let model = signedInModel()
            model.screen = .surface
            model.pendingSurfaceKey = surface.key
            model.pendingSurface = .init(surfaceKey: surface.key, title: surface.title, components: surface.components)
            let theme = ThemeStore()
            theme.apply(preset: preset)
            let mount = Mount(
                compact(content(surface, theme: theme, width: width), model: model, theme: theme),
                size: CGSize(width: width, height: 200), scheme: theme.colorScheme, fitHeight: true)
            try await mount.settle(fitHeight: true)
            return mount
        }

        private func measure(_ component: AstralComponent, chip: Bool? = nil, inCard: Bool = true) -> CGSize {
            let model = signedInModel()
            model.screen = .surface
            let theme = ThemeStore()
            let view = NSHostingView(
                rootView: compact(
                    ComponentView(component: component)
                        .environment(\.astralCompactChip, chip)
                        .environment(\.astralCompactCardContent, inCard)
                        .fixedSize(),
                    model: model, theme: theme))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }

        private func write(_ data: Data, name: String) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let directory = ProcessInfo.processInfo.environment["ASTRAL_SETTINGS_SNAPSHOT_DIR"] else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue
            else { return }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }

        private static func buttons(_ nodes: [JSONValue]) -> [JSONValue] {
            nodes.flatMap { node -> [JSONValue] in
                let own = node["type"]?.stringValue == "button" ? [node] : []
                return own + buttons((node["content"]?.arrayValue ?? []) + (node["children"]?.arrayValue ?? []))
            }
        }

        func testEverySettingsSurfaceRendersInGraphiteMidnightAndDaylight() async throws {
            for surface in try allSurfaces() {
                for preset in ["graphite", "midnight", "daylight"] {
                    let mount = try await mount(surface, preset: preset)
                    defer { mount.close() }
                    XCTAssertGreaterThan(mount.view.bounds.height, 40, surface.name)
                    write(try mount.png(), name: preset == "graphite" ? surface.name : "\(surface.name)-\(preset)")
                }
            }
        }

        func testNoSettingsButtonGrowsPastCompactBounds() throws {
            var measured = 0
            for surface in try allSurfaces() {
                for raw in Self.buttons(surface.components.map(\.raw)) {
                    let component = try XCTUnwrap(AstralComponent(json: raw))
                    let size = measure(component)
                    XCTAssertLessThanOrEqual(size.height, 44, "\(surface.name): \(component.label ?? "")")
                    XCTAssertLessThanOrEqual(size.height, 28, "\(surface.name): \(component.label ?? "")")
                    XCTAssertLessThan(size.width, 760 * 0.6, "\(surface.name): \(component.label ?? "")")
                    measured += 1
                }
            }
            XCTAssertGreaterThan(measured, 40)
        }

        func testAgentListCardsStayCompactAndKeepTheirCopy() async throws {
            let agents = try surface("agents_list")
            for card in agents.components where card.type == "card" {
                XCTAssertLessThanOrEqual(measure(card, inCard: false).height, 120, card.title ?? "")
            }
            let mount = try await mount(agents)
            defer { mount.close() }
            XCTAssertLessThan(mount.view.bounds.height, 480)
            let text = try mount.text()
            for kept in ["Owned by me", "Public", "Drafts", "Clinical Notes", "Yours", "Connected", "Open", "Disable"] {
                XCTAssertTrue(text.contains { $0.contains(kept) }, "Missing: \(kept)")
            }
        }

        func testSelectedAndUnselectedFilterControlsKeepTheSameFrame() async throws {
            for (name, label) in [("agents_list", "Owned by me"), ("personalization", "Soul")] {
                let surface = try surface(name)
                let group = try XCTUnwrap(surface.components.first, name)
                let selection = try XCTUnwrap(CompactSettingsLayout.chipSelection(group.children), name)
                XCTAssertEqual(selection.firstIndex(of: true), group.children.firstIndex { $0.label == label }, name)
                for button in group.children {
                    let on = measure(button, chip: true, inCard: false)
                    let off = measure(button, chip: false, inCard: false)
                    XCTAssertEqual(on.width, off.width, accuracy: 0.5, "\(name): \(button.label ?? "")")
                    XCTAssertEqual(on.height, off.height, accuracy: 0.5, "\(name): \(button.label ?? "")")
                    XCTAssertGreaterThanOrEqual(on.width, 64, "\(name): \(button.label ?? "")")
                }
                let moved = try XCTUnwrap(Self.moveSelection(group, from: label), name)
                XCTAssertNotEqual(CompactSettingsLayout.chipSelection(moved.children), selection, name)
                let before = measure(group, inCard: false)
                let after = measure(moved, inCard: false)
                XCTAssertEqual(before.width, after.width, accuracy: 0.5, name)
                XCTAssertEqual(before.height, after.height, accuracy: 0.5, name)
                let mount = try await mount(
                    Surface(
                        name: name, key: surface.key, title: surface.title,
                        components: [moved] + surface.components.dropFirst()))
                defer { mount.close() }
                write(try mount.png(), name: "\(name)-reselected")
            }
            let detail = try surface(
                "saved_result_detail", contract: "workspace_088/saved_results_surface.json", state: "detail")
            let row = try XCTUnwrap(detail.components.first?.children.first { $0.type == "container" })
            XCTAssertNil(CompactSettingsLayout.chipSelection(row.children))
        }

        func testSettingsSheetUsesDesktopFrameCompactNavigationAndTitleHeader() async throws {
            let model = signedInModel()
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(bundled("chrome-console")))
            let row = try XCTUnwrap(
                bundled("rote-console")["cases"]?.arrayValue?.first {
                    $0["viewport"]?.arrayValue?.first?.numberValue == 1440
                })
            let presentation = try XCTUnwrap(ConsolePresentation(json: row["presentation"]))
            model.consolePresentation = presentation
            let agents = try surface("agents_list")
            model.screen = .surface
            model.pendingSurfaceKey = "agents"
            model.pendingSurfaceParams = .object([:])
            model.pendingSurface = .init(surfaceKey: "agents", title: agents.title, components: agents.components)
            let theme = ThemeStore()
            let size = CGSize(width: 1440, height: 900)
            let mount = Mount(
                ConsoleSurfaceOverlay(console: try XCTUnwrap(model.console), presentation: presentation, size: size)
                    .frame(width: size.width, height: size.height)
                    .background(theme.palette.bg)
                    .environment(\.astralViewportWidth, size.width)
                    .environment(model).environment(theme),
                size: size, scheme: theme.colorScheme, fitHeight: false)
            defer { mount.close() }
            try await mount.settle(fitHeight: false)
            write(try mount.png(), name: "settings_sheet")
            let text = try mount.text()
            for kept in [
                "Agents & permissions", "LLM settings", "Theme", "Private notes", "Owned by me", "Clinical Notes",
            ] {
                XCTAssertTrue(text.contains { $0.contains(kept) }, "Missing: \(kept)")
            }
        }

        private static func moveSelection(_ group: AstralComponent, from label: String) -> AstralComponent? {
            guard var raw = group.raw.objectValue, var children = raw["children"]?.arrayValue,
                let current = children.firstIndex(where: { $0["label"]?.stringValue == label }),
                let next = children.indices.first(where: { $0 != current })
            else { return nil }
            let byDisabled = children[current]["disabled"]?.boolValue == true
            for index in [current, next] {
                guard var button = children[index].objectValue else { return nil }
                if byDisabled {
                    button["disabled"] = .bool(index == next)
                } else {
                    button["variant"] = .string(index == next ? "primary" : "secondary")
                }
                children[index] = .object(button)
            }
            raw["children"] = .array(children)
            return AstralComponent(json: .object(raw))
        }
    }
#endif
