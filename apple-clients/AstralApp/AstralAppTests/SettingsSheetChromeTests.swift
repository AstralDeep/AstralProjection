// Renders the Updates sheet and computer controls through the shared settings chrome in offscreen windows.
// Checks one key model, palette-drawn Done and checkboxes, a pinned footer and Graphite/Midnight/Daylight captures.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import Vision
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class SettingsSheetChromeTests: XCTestCase {
        private final class Mount {
            let window: NSWindow
            let view: NSView

            init(_ root: some View, size: CGSize, scheme: ColorScheme = .dark) {
                window = NSWindow(
                    contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let hosting = NSHostingView(rootView: root)
                window.contentView = hosting
                window.orderBack(nil)
                view = hosting
                hosting.layoutSubtreeIfNeeded()
            }

            func settle() async throws {
                for _ in 0..<6 {
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
            }

            func key(_ characters: String, code: UInt16) -> Bool {
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: code)!
                return window.performKeyEquivalent(with: event)
            }

            func bitmap() throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }

            func text() throws -> [(text: String, bounds: CGRect)] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap().cgImage)).perform([request])
                return (request.results ?? []).compactMap { result in
                    result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
                }
            }

            func close() {
                window.contentView = nil
                window.close()
            }
        }

        @MainActor
        private final class InertMonitor: MacComputerMonitoring {
            var running = false
            func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
                running = true
                return true
            }
            func stop() { running = false }
        }

        private actor InertDriver: MacComputerDriving {
            func execute(
                _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
                authorize: @escaping @Sendable () throws -> Void
            ) async throws -> [String: JSONValue] { [:] }
            func reset() {}
        }

        private func host() -> MacComputerHost {
            let name = "SettingsSheetChromeTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            return MacComputerHost(
                available: false, defaults: defaults, driver: InertDriver(), monitor: InertMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: false, screen: false, monitoring: false) },
                permissionRequester: { _ in false }, settingsOpener: { _ in false }, desktopProbe: { true },
                desktopRearm: { false }, system: MacComputerTestSystem(), panelPresenter: { _ in })
        }

        private func theme(_ preset: String) -> ThemeStore {
            let theme = ThemeStore()
            theme.apply(preset: preset)
            return theme
        }

        struct Pixels {
            let width: Int
            let height: Int
            private let bytes: [UInt8]

            init(_ bitmap: NSBitmapImageRep) throws {
                let image = try XCTUnwrap(bitmap.cgImage)
                let width = image.width
                let height = image.height
                self.width = width
                self.height = height
                var buffer = [UInt8](repeating: 0, count: width * height * 4)
                let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                buffer.withUnsafeMutableBytes { raw in
                    let context = CGContext(
                        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                bytes = buffer
            }

            func matches(x: Int, y: Int, _ expected: Color) -> Bool {
                let target = expected.resolve(in: EnvironmentValues())
                let offset = (y * width + x) * 4
                let channels = [target.red, target.green, target.blue].map { Int(($0 * 255).rounded()) }
                return zip(bytes[offset..<offset + 3], channels).allSatisfy { abs(Int($0) - $1) <= 6 }
            }

            func count(_ color: Color, rows: Range<Int>) -> Int {
                var total = 0
                for y in rows where y >= 0 && y < height {
                    for x in 0..<width where matches(x: x, y: y, color) { total += 1 }
                }
                return total
            }
        }

        private func write(_ data: Data, name: String) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let directory = ProcessInfo.processInfo.environment["ASTRAL_SETTINGS_SNAPSHOT_DIR"] else { return }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }

        func testReturnIsDoneAndEscapeClosesTheUpdatesSheet() async throws {
            for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
                let coordinator = UpdateCoordinator(isBusy: { false })
                coordinator.settingsPresented = true
                let mount = Mount(
                    UpdateSettingsSheet(coordinator: coordinator).environment(ThemeStore()),
                    size: CGSize(width: 420, height: 420))
                defer { mount.close() }
                try await mount.settle()
                XCTAssertTrue(mount.key(characters, code: code), "key \(code)")
                XCTAssertFalse(coordinator.settingsPresented, "key \(code)")
            }
        }

        func testReturnIsDoneAndEscapeClosesComputerControls() async throws {
            for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
                let host = host()
                host.controlsPresented = true
                let mount = Mount(
                    MacComputerControls(host: host).environment(ThemeStore()), size: CGSize(width: 560, height: 620))
                defer {
                    mount.close()
                    host.signedOut()
                }
                try await mount.settle()
                XCTAssertTrue(mount.key(characters, code: code), "key \(code)")
                XCTAssertFalse(host.controlsPresented, "key \(code)")
            }
        }

        func testDoneAndCheckboxesUseThePalettePrimaryOnTheSurface() async throws {
            for preset in ["graphite", "midnight", "daylight"] {
                let theme = theme(preset)
                let size = CGSize(width: 420, height: 300)
                let mount = Mount(
                    SettingsSheetChrome("Probe", identifier: "probe", close: {}) {
                        Toggle("Checked", isOn: .constant(true))
                    }
                    .frame(width: size.width, height: size.height)
                    .environment(theme),
                    size: size, scheme: theme.colorScheme)
                defer { mount.close() }
                try await mount.settle()
                let bitmap = try mount.bitmap()
                let pixels = try Pixels(bitmap)
                let scale = pixels.height / Int(size.height)
                let footer = (pixels.height - 60 * scale)..<pixels.height
                let body = (60 * scale)..<(pixels.height - 70 * scale)
                XCTAssertGreaterThan(pixels.count(theme.palette.primary, rows: footer), 40 * 20 * scale, preset)
                XCTAssertGreaterThan(pixels.count(theme.palette.primary, rows: body), 8 * 8 * scale, preset)
                XCTAssertTrue(pixels.matches(x: 4, y: 4, theme.palette.surface), preset)
                write(
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), name: "chrome-probe-\(preset)")
            }
        }

        func testChromeButtonsShareOneCompactHeightAndMinimumWidth() {
            for prominent in [true, false] {
                for label in ["OK", "Check now", "Choose workspace folders…"] {
                    let view = NSHostingView(
                        rootView: Button(label) {}
                            .buttonStyle(SettingsButtonStyle(palette: .graphite, prominent: prominent))
                            .fixedSize()
                    )
                    view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(view.fittingSize.height, SettingsControlMetrics.height, accuracy: 0.5, label)
                    XCTAssertGreaterThanOrEqual(view.fittingSize.width, SettingsControlMetrics.minimumWidth, label)
                }
            }
        }

        func testComputerControlsKeepTitleAndDoneVisibleAtTheMinimumHeight() async throws {
            let host = host()
            let size = CGSize(width: 480, height: 460)
            let mount = Mount(
                MacComputerControls(host: host).frame(width: size.width, height: size.height).environment(ThemeStore()),
                size: size)
            defer {
                mount.close()
                host.signedOut()
            }
            try await mount.settle()
            let text = try mount.text()
            let done = try XCTUnwrap(text.first { $0.text == "Done" }, "\(text.map(\.text))")
            XCTAssertLessThan(done.bounds.maxY, 0.15)
            let title = try XCTUnwrap(text.first { $0.text.contains("Computer access on this Mac") })
            XCTAssertGreaterThan(title.bounds.minY, 0.85)
        }

        func testUpdatesSheetAndComputerControlsRenderInEveryPreset() async throws {
            for preset in ["graphite", "midnight", "daylight"] {
                let theme = theme(preset)
                let coordinator = UpdateCoordinator(isBusy: { false })
                let updates = Mount(
                    UpdateSettingsSheet(coordinator: coordinator).environment(theme),
                    size: CGSize(width: 420, height: 360), scheme: theme.colorScheme)
                defer { updates.close() }
                try await updates.settle()
                let updatesText = try updates.text().map(\.text)
                for kept in ["Updates", "Check automatically", "Version", "Last checked", "Check now", "Done"] {
                    XCTAssertTrue(updatesText.contains { $0.contains(kept) }, "\(preset): \(kept) in \(updatesText)")
                }
                let updatesBitmap = try updates.bitmap()
                XCTAssertTrue(try Pixels(updatesBitmap).matches(x: 4, y: 4, theme.palette.surface), preset)
                write(
                    try XCTUnwrap(updatesBitmap.representation(using: .png, properties: [:])),
                    name: "updates-sheet-\(preset)")

                let host = host()
                let controls = Mount(
                    MacComputerControls(host: host).frame(width: 560, height: 620).environment(theme),
                    size: CGSize(width: 560, height: 620), scheme: theme.colorScheme)
                defer {
                    controls.close()
                    host.signedOut()
                }
                try await controls.settle()
                let controlsBitmap = try controls.bitmap()
                XCTAssertTrue(try Pixels(controlsBitmap).matches(x: 4, y: 4, theme.palette.surface), preset)
                write(
                    try XCTUnwrap(controlsBitmap.representation(using: .png, properties: [:])),
                    name: "computer-controls-\(preset)")
            }
        }
    }
#endif
