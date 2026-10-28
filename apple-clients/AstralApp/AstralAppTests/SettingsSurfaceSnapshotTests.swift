// Renders representative settings surfaces through ComponentView in the compact Mac settings style and measures
// that controls keep one size across selection, stay compact and outline inputs in field_border. The
// ASTRAL_SETTINGS_SNAPSHOT_DIR environment variable collects the PNGs.

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
            try bundled(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
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
            try [
                "agents_list", "agents_detail", "llm", "personalization", "audit", "theme", "my_computers", "table",
                "safety_running", "safety_engaged", "remote_machines", "mesh", "mesh_invitations", "llm_system",
                "admin_tools", "drafts", "authoring", "attachments", "search", "pulse",
            ]
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
            _ surface: Surface, preset: String = "graphite", width: CGFloat = 760,
            textSize: DynamicTypeSize = .large
        ) async throws -> Mount {
            let model = signedInModel()
            model.screen = .surface
            model.pendingSurfaceKey = surface.key
            model.pendingSurface = .init(surfaceKey: surface.key, title: surface.title, components: surface.components)
            let theme = ThemeStore()
            theme.apply(preset: preset)
            let mount = Mount(
                compact(content(surface, theme: theme, width: width), model: model, theme: theme)
                    .environment(\.dynamicTypeSize, textSize),
                size: CGSize(width: width, height: 200), scheme: theme.colorScheme, fitHeight: true)
            try await mount.settle(fitHeight: true)
            return mount
        }

        private func measure(
            _ component: AstralComponent, chip: Bool? = nil, inCard: Bool = true, textSize: DynamicTypeSize = .large
        ) -> CGSize {
            let model = signedInModel()
            model.screen = .surface
            let theme = ThemeStore()
            let view = NSHostingView(
                rootView: compact(
                    ComponentView(component: component)
                        .environment(\.astralCompactChip, chip)
                        .environment(\.astralCompactCardContent, inCard)
                        .fixedSize(),
                    model: model, theme: theme
                )
                .environment(\.dynamicTypeSize, textSize))
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

        func testEverySurfaceFixtureLoadsFromTheTestBundle() throws {
            let bundle = Bundle(for: SettingsSurfaceSnapshotTests.self).bundleURL.standardizedFileURL.path
            for name in [
                "SettingsSurfaceSnapshotFixtures", "chrome-console", "rote-console", "agents_surface", "notes_surface",
                "skills_surface", "monitor_surface", "panel_surface", "saved_results_surface",
                "recurring_work_surface", "connections_surface",
            ] {
                let url = try XCTUnwrap(
                    Bundle(for: SettingsSurfaceSnapshotTests.self).url(forResource: name, withExtension: "json"), name)
                XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(bundle), name)
            }
            XCTAssertEqual(try allSurfaces().count, 30)
            let keys = Set(try allSurfaces().map(\.key))
            for key in [
                "safety", "remote_machines", "mesh", "llm_system", "admin_tools", "drafts", "agent_authoring",
                "attachments", "search", "pulse",
            ] {
                XCTAssertTrue(keys.contains(key), key)
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

        func testLargerTextKeepsEverySurfaceAndControlInsideItsBounds() async throws {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                for surface in try allSurfaces() {
                    let mount = try await mount(surface, textSize: textSize)
                    defer { mount.close() }
                    XCTAssertGreaterThan(mount.view.bounds.height, 40, "\(surface.name) \(textSize)")
                    XCTAssertLessThanOrEqual(mount.view.fittingSize.width, 760.5, "\(surface.name) \(textSize)")
                    if textSize == .accessibility3 {
                        write(try mount.png(), name: "\(surface.name)-accessibility3")
                    }
                    for raw in Self.buttons(surface.components.map(\.raw)) {
                        let component = try XCTUnwrap(AstralComponent(json: raw))
                        let size = measure(component, textSize: textSize)
                        let name = "\(surface.name) \(textSize): \(component.label ?? "")"
                        XCTAssertEqual(size.height, 28, accuracy: 0.5, name)
                        XCTAssertLessThan(size.width, 760 * 0.6, name)
                    }
                }
            }
        }

        func testNoSettingsButtonGrowsPastCompactBounds() throws {
            var measured = 0
            for surface in try allSurfaces() {
                for raw in Self.buttons(surface.components.map(\.raw)) {
                    let component = try XCTUnwrap(AstralComponent(json: raw))
                    let size = measure(component)
                    XCTAssertEqual(size.height, 28, accuracy: 0.5, "\(surface.name): \(component.label ?? "")")
                    XCTAssertGreaterThanOrEqual(size.width, 64, "\(surface.name): \(component.label ?? "")")
                    XCTAssertLessThan(size.width, 760 * 0.6, "\(surface.name): \(component.label ?? "")")
                    measured += 1
                }
            }
            XCTAssertGreaterThan(measured, 40)
        }

        private func component(_ json: String) throws -> AstralComponent {
            try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
        }

        private func controls(_ view: NSView) -> (fields: [NSTextField], switches: [NSView]) {
            func collect(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(collect) }
            let all = collect(view)
            return (
                all.compactMap { $0 as? NSTextField }.filter(\.isEditable),
                all.filter { String(describing: type(of: $0)).contains("PlatformSwitch") }
            )
        }

        func testStateDependentActionLabelsKeepOneButtonWidth() throws {
            let enable = try component(#"{"type":"button","label":"Enable","action":"chrome_agent_enable"}"#)
            let disable = try component(#"{"type":"button","label":"Disable","action":"chrome_agent_disable"}"#)
            let open = try component(#"{"type":"button","label":"Open","action":"chrome_open"}"#)
            XCTAssertEqual(measure(enable).width, measure(disable).width, accuracy: 0.5)
            for button in [enable, disable, open] {
                XCTAssertEqual(measure(button).height, 28, accuracy: 0.5, button.label ?? "")
                XCTAssertEqual(measure(button).width, 64, accuracy: 0.5, button.label ?? "")
            }
        }

        func testLongCompactLabelsStayOnOneLineInsideTheirRow() throws {
            let long = try component(
                #"{"type":"button","label":"Approve and resume on build-host-07 / com.example.LongTargetName","action":"approve"}"#
            )
            let model = signedInModel()
            model.screen = .surface
            let view = NSHostingView(
                rootView: compact(
                    ComponentView(component: long).environment(\.astralCompactCardContent, true)
                        .frame(width: 180, alignment: .leading).fixedSize(horizontal: false, vertical: true),
                    model: model, theme: ThemeStore()))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.height, 28, accuracy: 0.5)
            XCTAssertLessThanOrEqual(view.fittingSize.width, 180.5)
        }

        func testCompactFormFieldsShareOneSmallTrailingColumn() async throws {
            let form = try component(
                #"""
                {"type":"param_picker","title":"Add a machine","fields":[
                {"name":"label","label":"Label","kind":"text"},
                {"name":"port","label":"Port","kind":"number","default":"22"},
                {"name":"password","label":"Password","kind":"password"},
                {"name":"os","label":"Operating system","kind":"select","default":"linux","options":["linux","windows"]},
                {"name":"trusted","label":"Trusted","kind":"boolean","default":true}],
                "submit_action":"chrome_machine_add","submit_label":"Add & probe"}
                """#)
            let input = try component(#"{"type":"input","label":"Rename","placeholder":"New name","action":"rename"}"#)
            let mount = try await mount(
                Surface(name: "form", key: "remote_machines", title: "", components: [form, input]))
            defer { mount.close() }
            let (fields, switches) = controls(mount.view)
            XCTAssertEqual(fields.count, 4)
            let column = fields.prefix(3)
            for field in fields {
                XCTAssertFalse(field.isBezeled, "compact fields draw their own outline")
                XCTAssertLessThanOrEqual(field.frame.height, 28)
            }
            let frames = column.map { $0.convert($0.bounds, to: nil) }
            for frame in frames.dropFirst() {
                XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 0.5)
                XCTAssertEqual(frame.width, frames[0].width, accuracy: 0.5)
            }
            XCTAssertLessThanOrEqual(frames[0].width, SettingsControlMetrics.formColumn)
            XCTAssertGreaterThan(frames[0].width, SettingsControlMetrics.formColumn - 20)
            let toggle = try XCTUnwrap(switches.first).convert(try XCTUnwrap(switches.first).bounds, to: nil)
            XCTAssertEqual(toggle.maxX, frames[0].maxX, accuracy: 8)
            let regular = NSHostingView(rootView: Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden())
            regular.layoutSubtreeIfNeeded()
            XCTAssertLessThan(toggle.height, regular.fittingSize.height, "boolean fields use the small control size")
            write(try mount.png(), name: "compact-form-column")
        }

        private func longestRun(_ png: Data, near color: Color) throws -> (length: Int, scale: CGFloat) {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let image = try XCTUnwrap(bitmap.cgImage)
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let resolved = color.resolve(in: EnvironmentValues())
            let target = [resolved.red, resolved.green, resolved.blue].map { Int(($0 * 255).rounded()) }
            var longest = 0
            for y in 0..<image.height {
                var run = 0
                for x in 0..<image.width {
                    let offset = (y * image.width + x) * 4
                    let hit = zip(buffer[offset..<offset + 3], target).allSatisfy { abs(Int($0) - $1) <= 4 }
                    run = hit ? run + 1 : 0
                    longest = max(longest, run)
                }
            }
            return (longest, CGFloat(image.width) / CGFloat(bitmap.size.width))
        }

        func testCompactInputOutlinesUseFieldBorderInsteadOfMuted() async throws {
            func form(_ kind: String, extra: String = "") -> String {
                #"{"type":"param_picker","title":"Add","fields":[{"name":"value","label":"Value","kind":"\#(kind)"\#(extra)}],"submit_action":"chrome_add","submit_label":"Add"}"#
            }
            let cases: [(name: String, json: String, minimum: CGFloat)] = [
                ("text", form("text"), 150),
                ("number", form("number"), 150),
                ("password", form("password"), 150),
                ("textarea", form("textarea"), 150),
                ("select", form("select", extra: #","default":"linux","options":["linux","windows"]"#), 24),
                ("input", #"{"type":"input","label":"Rename","placeholder":"New name","action":"rename"}"#, 150),
            ]
            for preset in ["graphite", "midnight", "daylight"] {
                let theme = ThemeStore()
                theme.apply(preset: preset)
                let p = theme.palette
                for (name, json, minimum) in cases {
                    let mount = try await mount(
                        Surface(name: name, key: "remote_machines", title: "", components: [try component(json)]),
                        preset: preset)
                    defer { mount.close() }
                    let png = try mount.png()
                    write(png, name: "field-outline-\(name)-\(preset)")
                    let border = try longestRun(png, near: p.fieldBorder)
                    XCTAssertGreaterThanOrEqual(CGFloat(border.length), minimum * border.scale, "\(preset) \(name)")
                    let muted = try longestRun(png, near: p.muted)
                    XCTAssertLessThan(
                        CGFloat(muted.length), 24 * muted.scale, "\(preset) \(name) still outlined in muted")
                }
            }
        }

        func testSettingsCheckboxOutlineUsesFieldBorderUntilChecked() async throws {
            for preset in ["graphite", "midnight", "daylight"] {
                let theme = ThemeStore()
                theme.apply(preset: preset)
                for on in [false, true] {
                    let size = CGSize(width: 420, height: 300)
                    let mount = Mount(
                        SettingsSheetChrome("Probe", identifier: "probe", close: {}) {
                            Toggle("Allow", isOn: .constant(on))
                        }
                        .frame(width: size.width, height: size.height)
                        .environment(theme),
                        size: size, scheme: theme.colorScheme, fitHeight: false)
                    defer { mount.close() }
                    try await mount.settle(fitHeight: false)
                    let border = try longestRun(try mount.png(), near: theme.palette.fieldBorder)
                    if on {
                        XCTAssertLessThan(CGFloat(border.length), 6 * border.scale, "\(preset) checked")
                    } else {
                        XCTAssertGreaterThanOrEqual(CGFloat(border.length), 8 * border.scale, "\(preset) unchecked")
                    }
                }
            }
        }

        func testCardTextIsNeverClampedBehindAHoverTooltip() async throws {
            let card = try component(
                #"""
                {"type":"card","title":"This Mac","content":[
                {"type":"text","content":"Pause and Stop stay visible while a task runs. Commands and file changes ask first. Touching the mouse or keyboard pauses the task until you resume it here on this Mac. Grants end when the task ends or when you revoke them from the session panel, whichever comes first, and nothing carries over to terminus."},
                {"type":"button","label":"Pause","action":"chrome_computer_pause"}]}
                """#)
            let mount = try await mount(
                Surface(name: "clamp", key: "my_computers", title: "", components: [card]), width: 420)
            defer { mount.close() }
            let text = try mount.text().joined(separator: " ")
            XCTAssertTrue(text.contains("terminus"), text)
            write(try mount.png(), name: "card-text-unclamped")
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

        func testOverlayGeometryFollowsTheServerPresentation() throws {
            for row in try XCTUnwrap(bundled("rote-console")["cases"]?.arrayValue) {
                let presentation = try XCTUnwrap(ConsolePresentation(json: row["presentation"]))
                guard presentation.settingsPresentation == .dialog, presentation.settingsNavigationAxis == .vertical
                else { continue }
                let viewport = try XCTUnwrap(row["viewport"]?.arrayValue?.compactMap(\.numberValue))
                let size = CGSize(width: viewport[0], height: viewport[1])
                let geometry = ConsoleSurfaceOverlay.geometry(
                    presentation: presentation, size: size, hasNavigation: true, isIntro: false, desktop: true)
                XCTAssertEqual(geometry.width, min(size.width - 32, presentation.settingsWidth), "\(viewport)")
                XCTAssertEqual(geometry.height, min(size.height - 32, presentation.settingsMaxHeight), "\(viewport)")
                XCTAssertEqual(geometry.navigation, presentation.settingsNavigationWidth, "\(viewport)")
            }
            let row = try XCTUnwrap(
                bundled("rote-console")["cases"]?.arrayValue?.first {
                    $0["viewport"]?.arrayValue?.first?.numberValue == 1440
                })
            let geometry = ConsoleSurfaceOverlay.geometry(
                presentation: try XCTUnwrap(ConsolePresentation(json: row["presentation"])),
                size: CGSize(width: 1440, height: 900), hasNavigation: true, isIntro: false, desktop: true)
            XCTAssertEqual(geometry.width, 940)
            XCTAssertEqual(geometry.height, 774)
            XCTAssertEqual(geometry.navigation, 216)
        }

        private static func overlayFrame(_ pixels: SettingsSheetChromeTests.Pixels, scrim: Color) -> CGRect? {
            let midX = pixels.width / 2
            let rows = (0..<pixels.height).filter { !pixels.matches(x: midX, y: $0, scrim) }
            guard let top = rows.first, let bottom = rows.last else { return nil }
            let probe = top + (bottom - top) / 2
            let columns = (0..<pixels.width).filter { !pixels.matches(x: $0, y: probe, scrim) }
            guard let left = columns.first, let right = columns.last else { return nil }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }

        func testSettingsSheetUsesDesktopFrameCompactNavigationAndTitleHeader() async throws {
            let model = signedInModel()
            var menu = try XCTUnwrap(bundled("chrome-console").objectValue)
            var groups = try XCTUnwrap(menu["menu"]?.arrayValue)
            var account = try XCTUnwrap(groups.first?.objectValue)
            account["items"] = .array(
                (account["items"]?.arrayValue ?? []) + [
                    .object([
                        "key": .string("remote_machines"), "label": .string("Remote machines and SSH credentials"),
                        "surface": .string("remote_machines"), "params": .object([:]), "admin_only": .bool(false),
                    ])
                ])
            groups[0] = .object(account)
            menu["menu"] = .array(groups)
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(.object(menu)))
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
            for preset in ["graphite", "midnight", "daylight"] {
                let theme = ThemeStore()
                theme.apply(preset: preset)
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
                write(try mount.png(), name: preset == "graphite" ? "settings_sheet" : "settings_sheet-\(preset)")
                let text = try mount.text()
                for kept in [
                    "Agents & permissions", "LLM settings", "Theme", "Private notes", "Owned by me", "Clinical Notes",
                    "Account", "Help",
                ] {
                    XCTAssertTrue(text.contains { $0.contains(kept) }, "\(preset) missing: \(kept)")
                }
                XCTAssertFalse(
                    text.contains { $0.contains("ACCOUNT") }, "group headers keep the server's sentence case")
                let navigation = text.joined(separator: " ")
                XCTAssertTrue(
                    navigation.contains("Remote machines and SSH") && navigation.contains("credentials"), "\(text)")
                XCTAssertFalse(text.contains { $0.contains("…") }, "a navigation label was truncated: \(text)")
                let bitmap = try XCTUnwrap(mount.view.bitmapImageRepForCachingDisplay(in: mount.view.bounds))
                mount.view.cacheDisplay(in: mount.view.bounds, to: bitmap)
                let pixels = try SettingsSheetChromeTests.Pixels(bitmap)
                let scale = CGFloat(pixels.width) / size.width
                let bg = theme.palette.bg.resolve(in: EnvironmentValues())
                let scrim = Color(
                    .sRGB, red: Double(bg.red) * 0.6, green: Double(bg.green) * 0.6, blue: Double(bg.blue) * 0.6)
                let frame = try XCTUnwrap(Self.overlayFrame(pixels, scrim: scrim))
                XCTAssertEqual(frame.width / scale, 940, accuracy: 2, preset)
                XCTAssertEqual(frame.height / scale, 774, accuracy: 2, preset)
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
