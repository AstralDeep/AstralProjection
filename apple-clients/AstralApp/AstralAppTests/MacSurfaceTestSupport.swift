// Mounts workbench surfaces offscreen in a chosen theme, drives them with real key and mouse events, and reads the
// accessibility tree when the test host is trusted; PNGs also go to ASTRAL_SETTINGS_SNAPSHOT_DIR when it is set.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import SwiftUI
    import Vision
    import XCTest

    @testable import AstralDeep

    @MainActor
    enum SurfaceAccessibility {
        struct Element {
            let identifier: String?
            let label: String?
            let value: String?
            let help: String?
            let role: String?
            let enabled: Bool
            let selected: Bool
        }

        static func requireTrust() throws {
            try XCTSkipUnless(
                AXIsProcessTrusted(), "Reading the accessibility tree needs a test host with Accessibility access")
        }

        static func elements(windowTitle: String) -> [Element] {
            guard let window = window(title: windowTitle) else { return [] }
            var found: [Element] = []
            func walk(_ element: AXUIElement, depth: Int) {
                found.append(
                    Element(
                        identifier: attribute(kAXIdentifierAttribute, of: element) as? String,
                        label: attribute(kAXDescriptionAttribute, of: element) as? String
                            ?? attribute(kAXTitleAttribute, of: element) as? String,
                        value: attribute(kAXValueAttribute, of: element) as? String,
                        help: attribute(kAXHelpAttribute, of: element) as? String,
                        role: attribute(kAXRoleAttribute, of: element) as? String,
                        enabled: attribute(kAXEnabledAttribute, of: element) as? Bool ?? true,
                        selected: attribute(kAXSelectedAttribute, of: element) as? Bool ?? false))
                guard depth < 64 else { return }
                for child in attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] {
                    walk(child, depth: depth + 1)
                }
            }
            walk(window, depth: 0)
            return found
        }

        private static func window(title: String) -> AXUIElement? {
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
            return windows.first { attribute(kAXTitleAttribute, of: $0) as? String == title }
        }

        private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
    }

    @MainActor
    final class SurfaceMount {
        let window: NSWindow
        let view: NSView

        init(_ root: some View, model: AppModel, size: CGSize, preset: String = "graphite") {
            model.themeStore.apply(preset: preset)
            let hosting = NSHostingView(
                rootView: AnyView(
                    root.environment(model).environment(model.themeStore)
                        .font(ConsoleTypography.body).tint(model.themeStore.palette.primary)
                        .preferredColorScheme(model.themeStore.colorScheme)))
            window = SurfaceMountWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Surface mount \(UUID().uuidString)"
            window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderBack(nil)
            view = hosting
        }

        var accessibility: [SurfaceAccessibility.Element] { SurfaceAccessibility.elements(windowTitle: window.title) }

        func settle() async throws {
            for _ in 0..<5 {
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        func bitmap() throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }

        func lines() throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap().cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }

        func text() throws -> String { try lines().joined(separator: "\n") }

        func fields() -> [NSTextField] {
            func collect(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            return collect(view)
        }

        func focusedPrompt() -> String? {
            guard let editor = window.firstResponder as? NSTextView else { return nil }
            return fields().first { $0.currentEditor() === editor }?.placeholderString
        }

        func textFrame(_ text: String) throws -> CGRect? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap().cgImage)).perform([request])
            guard
                let box = (request.results ?? []).first(where: {
                    $0.topCandidates(1).first?.string.contains(text) == true
                })?
                .boundingBox
            else { return nil }
            let size = view.bounds.size
            return CGRect(
                x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width,
                height: box.height * size.height)
        }

        func click(at point: CGPoint) throws {
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(
                    try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }

        func click(text: String) throws {
            let frame = try XCTUnwrap(textFrame(text), "No rendered text \(text)")
            try click(at: CGPoint(x: frame.midX, y: frame.midY))
        }

        func type(_ text: String) {
            (window.firstResponder as? NSTextView)?.insertText(
                text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        func key(_ key: SurfaceKey, in target: NSWindow? = nil) throws {
            let destination = target ?? window
            destination.sendEvent(try key.event(windowNumber: destination.windowNumber))
        }

        func shortcut(_ key: SurfaceKey, in target: NSWindow? = nil) throws -> Bool {
            let destination = target ?? window
            return destination.performKeyEquivalent(with: try key.event(windowNumber: destination.windowNumber))
        }

        func snapshot(_ test: XCTestCase, name: String) throws {
            let data = try XCTUnwrap(bitmap().representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
            guard let directory = ProcessInfo.processInfo.environment["ASTRAL_SETTINGS_SNAPSHOT_DIR"] else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue
            else { return }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    enum SurfaceKey {
        case returnKey, escape, down, up, delete

        func event(windowNumber: Int) throws -> NSEvent {
            let (code, characters, flags): (UInt16, String, NSEvent.ModifierFlags) =
                switch self {
                case .returnKey: (36, "\r", [])
                case .escape: (53, "\u{1b}", [])
                case .down: (125, "\u{F701}", [.numericPad, .function])
                case .up: (126, "\u{F700}", [.numericPad, .function])
                case .delete: (51, "\u{7f}", [])
                }
            return try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
    }

    private final class SurfaceMountWindow: NSWindow {
        // Ordering a window on screen clamps it to the display, and hosted runners have a 1024-point display.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    @MainActor
    enum SurfaceFixtures {
        static let presets = ["graphite", "midnight", "daylight"]

        static func json(_ name: String) throws -> JSONValue {
            let url = try XCTUnwrap(Bundle(for: SurfaceMount.self).url(forResource: name, withExtension: "json"), name)
            return try JSONValue.parse(Data(contentsOf: url))
        }

        static func model(menu: JSONValue? = nil) throws -> (AppModel, String) {
            let suite = "MacSurfaceTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "surface-owner")))
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(menu ?? json("chrome-console")))
            return (model, suite)
        }

        static func menu(agents: [JSONValue]) throws -> JSONValue {
            try replacing(json("chrome-console"), path: ["console", "catalog", "agents"], with: .array(agents))
        }

        static func replacing(_ value: JSONValue, path: [String], with replacement: JSONValue) throws -> JSONValue {
            guard let key = path.first else { return replacement }
            var object = try XCTUnwrap(value.objectValue, key)
            object[key] = try replacing(object[key] ?? .object([:]), path: Array(path.dropFirst()), with: replacement)
            return .object(object)
        }

        static func agent(_ id: String, name: String, description: String, state: String) -> JSONValue {
            .object([
                "id": .string(id), "name": .string(name), "description": .string(description),
                "state": .string(state), "owned": .bool(true),
            ])
        }
    }
#endif
