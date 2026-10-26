// Exercises actual native keyboard and pointer decisions with inert AX values and recorded CGEvents.
// Raw OS bindings are substituted without replacing the input sequencer or authority and target policies.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerInputAdapterTests: XCTestCase {
        func testKeyboardProducesMarkedUnicodeEventsWithoutPostingToTheDesktop() async throws {
            let system = MacComputerInputTestSystem()
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            try await input.type("Hello 🧭", args: [:], authorize: {})
            let posted = events.posted
            XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp])
            XCTAssertTrue(posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 30 })
            var length = 0
            var text = [UInt16](repeating: 0, count: 32)
            posted[0].keyboardGetUnicodeString(
                maxStringLength: text.count, actualStringLength: &length, unicodeString: &text)
            XCTAssertEqual(String(decoding: text.prefix(length), as: UTF16.self), "Hello 🧭")
        }
        private func request(_ verb: String, args: [String: JSONValue]) throws -> ComputerHostRequest {
            try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                    "session_id": .string(UUID().uuidString.lowercased()), "verb": .string(verb),
                    "args": .object(args), "deadline_ms": .number(30000),
                ]))
        }

        func testKeyboardChecksNativeIdentityPermissionsAndSecureFieldsBeforeEffects() async throws {
            for fault in MacComputerInputTestSystem.Fault.allCases {
                let system = MacComputerInputTestSystem()
                system.apply(fault)
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.press(ComputerHostChord("a"), args: [:], authorize: {})
                    XCTFail("Unverifiable keyboard target accepted: \(fault)")
                } catch let error as ComputerHostError {
                    let expected =
                        switch fault {
                        case .terminal: "confirmation_required"
                        case .secureInput, .secureField: "secure_input_active"
                        default: "permission_denied"
                        }
                    XCTAssertEqual(error.code, expected, "\(fault)")
                }
                XCTAssertTrue(events.posted.isEmpty)
            }
        }

        func testExactTerminalGrantMatchesFocusedBundleAndIsRecheckedBetweenChunks() async throws {
            for (bundle, granted) in [("com.apple.Terminal", false), ("com.apple.TextEdit", true)] {
                let system = MacComputerInputTestSystem()
                system.setBundle(bundle)
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.press(
                        ComputerHostChord("enter"),
                        args: [
                            "terminal_app": .string("terminal"), "terminal_ok": .bool(granted),
                        ], authorize: {})
                    XCTFail("An absent or mismatched terminal grant was accepted")
                } catch let error as ComputerHostError {
                    XCTAssertEqual(error.code, "confirmation_required")
                }
                XCTAssertTrue(events.posted.isEmpty)
            }
            let system = MacComputerInputTestSystem()
            system.setBundle("com.apple.Terminal")
            let events = MacComputerInputTestEvents()
            events.configure { $0.onPost = { _, index in if index == 2 { system.setBundle("com.googlecode.iterm2") } } }
            let input = MacComputerInput(marker: 30, system: system, events: events)
            do {
                try await input.type(
                    String(repeating: "x", count: 24),
                    args: [
                        "terminal_app": .string("terminal"), "terminal_ok": .bool(true),
                    ], authorize: {})
                XCTFail("The next text chunk reached a different terminal")
            } catch let error as ComputerHostError {
                XCTAssertEqual(error.code, "confirmation_required")
            }
            XCTAssertEqual(events.posted.map(\.type), [.keyDown, .keyUp])
        }

        func testRealAuthorityRevocationStopsTypingAfterNeutralizingFirstChunk() async throws {
            let system = MacComputerInputTestSystem()
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            let authority = ComputerHostAuthority()
            authority.setDesktopAvailable(true)
            let request = try request("type_text", args: ["text": .string(String(repeating: "x", count: 24))])
            try authority.begin(request.sessionId)
            let ticket = try authority.admit(request)
            events.configure { $0.onPost = { _, index in if index == 1 { authority.setDesktopAvailable(false) } } }
            do {
                try await input.type(
                    request.args["text"]!.stringValue!, args: [:], authorize: { try authority.verify(ticket) })
                XCTFail("Revoked desktop authority continued typing")
            } catch is ComputerHostError {}
            XCTAssertEqual(events.posted.map(\.type), [.keyDown, .keyUp])
        }

        func testEveryKeyboardGuardIsRecheckedAfterTheFirstChunk() async throws {
            for fault in MacComputerInputTestSystem.Fault.allCases {
                let system = MacComputerInputTestSystem()
                let events = MacComputerInputTestEvents()
                events.configure { $0.onPost = { _, index in if index == 2 { system.apply(fault) } } }
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.type(String(repeating: "x", count: 24), args: [:], authorize: {})
                    XCTFail("Keyboard guard was not renewed: \(fault)")
                } catch is ComputerHostError {}
                XCTAssertEqual(events.posted.map(\.type), [.keyDown, .keyUp])
            }
        }

        func testActualObservationAndDesktopProbeRejectChangedFocusBoundsTopologyAndSession() async throws {
            for change in ["foreground", "window", "bounds", "topology", "session"] {
                let system = MacComputerTestSystem()
                let observed = try MacComputerObservation.capture(screenshot: true, system: system)
                let events = MacComputerInputTestEvents()
                events.configure {
                    $0.onPost = { _, index in
                        guard index == 2 else { return }
                        switch change {
                        case "foreground":
                            system.configure {
                                $0.nodes[1].pid = 300
                                $0.bundles[300] = "fixture.editor"
                            }
                        case "window": system.set(system.field, attribute: kAXFocusedWindowAttribute, of: system.app)
                        case "bounds":
                            system.setBounds(CGRect(x: 20, y: 30, width: 600, height: 400), of: system.window)
                        case "topology": system.configure { $0.pixels.width = 1400 }
                        default: system.configure { $0.session?["CGSSessionScreenIsLocked"] = true }
                        }
                    }
                }
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.type(
                        String(repeating: "x", count: 24), args: [:],
                        authorize: {
                            guard MacComputerDesktopProbe.usable(system: system) else {
                                throw ComputerHostError("screen_locked", "The desktop is unavailable.")
                            }
                            try observed.verify(requireScreenshot: false, requireWindow: true)
                        })
                    XCTFail("A changed desktop observation continued typing: \(change)")
                } catch let error as ComputerHostError {
                    XCTAssertEqual(error.code, change == "session" ? "screen_locked" : "stale_target")
                }
                XCTAssertEqual(events.posted.map(\.type), [.keyDown, .keyUp])
            }
        }

        func testChordCarriesExactVirtualKeyAndModifiersAndReleasesTheKey() async throws {
            let system = MacComputerInputTestSystem()
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            try await input.press(ComputerHostChord("cmd+ctrl+alt+shift+f12"), args: [:], authorize: {})
            let posted = events.posted
            XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp])
            XCTAssertEqual(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [111, 111])
            XCTAssertTrue(posted[0].flags.contains([.maskCommand, .maskControl, .maskAlternate, .maskShift]))
            XCTAssertTrue(posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 30 })
        }

        func testPunctuationChordsPostTheirANSIVirtualKeys() async throws {
            let codes: [String: Int64] = [
                "cmd+,": 43, "cmd+.": 47, "cmd+/": 44, "cmd+;": 41, "cmd+'": 39, "cmd+[": 33, "cmd+]": 30,
                "cmd+\\": 42, "cmd+-": 27, "cmd+=": 24, "cmd+`": 50, "cmd+comma": 43, "ctrl+grave": 50,
            ]
            for (text, code) in codes {
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: MacComputerInputTestSystem(), events: events)
                try await input.press(ComputerHostChord(text), args: [:], authorize: {})
                XCTAssertEqual(events.posted.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [code, code], text)
            }
        }

        func testSecureInputRefusesOnlyKeyboardWhilePointerContinues() async throws {
            for fault in [MacComputerInputTestSystem.Fault.secureInput, .secureField] {
                let system = MacComputerInputTestSystem()
                system.apply(fault)
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.type("secret", args: [:], authorize: {})
                    XCTFail("Secure input accepted typing")
                } catch let error as ComputerHostError { XCTAssertEqual(error.code, "secure_input_active") }
                XCTAssertTrue(events.posted.isEmpty)
                try await input.pointer(
                    request("click", args: ["x": .number(20), "y": .number(30)]), start: CGPoint(x: 20, y: 30),
                    end: nil, authorize: {})
                XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            }
        }

        func testSessionPanelOverTheTargetReportsObscuredInsteadOfAGenericRefusal() async throws {
            let system = MacComputerInputTestSystem()
            var panel = MacComputerInputTestSystem.row(pid: 100)
            panel[kCGWindowName as String] = MacComputerPanelIdentity.title
            system.setWindows([panel, MacComputerInputTestSystem.row(pid: 200)])
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            do {
                try await input.pointer(
                    request("click", args: ["x": .number(20), "y": .number(30)]), start: CGPoint(x: 20, y: 30),
                    end: nil, authorize: {})
                XCTFail("A click under the session panel was posted")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "obscured_by_astral_panel") }
            var other = MacComputerInputTestSystem.row(pid: 100)
            other[kCGWindowName as String] = "Astral"
            system.setWindows([other])
            do {
                try await input.pointer(
                    request("click", args: ["x": .number(20), "y": .number(30)]), start: CGPoint(x: 20, y: 30),
                    end: nil, authorize: {})
                XCTFail("A click into Astral's own window was posted")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
            system.setWindows([MacComputerInputTestSystem.row(pid: 200), panel])
            try await input.pointer(
                request("click", args: ["x": .number(20), "y": .number(30)]), start: CGPoint(x: 20, y: 30), end: nil,
                authorize: {})
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
        }

        func testAlreadyCancelledTypingCannotGenerateAnEvent() async throws {
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: MacComputerInputTestSystem(), events: events)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await input.type("never typed", args: [:], authorize: {})
            }
            do {
                try await task.value
                XCTFail("Cancelled typing continued")
            } catch is CancellationError {}
            XCTAssertTrue(events.posted.isEmpty)
            XCTAssertEqual(events.configure { $0.keyboardCreated }, 0)
        }

        func testKeyboardFactoryFailureNeverClaimsOrRetriesAnEffect() async throws {
            for failure in [1, 2] {
                let events = MacComputerInputTestEvents()
                events.configure { $0.keyboardFailure = failure }
                let input = MacComputerInput(marker: 30, system: MacComputerInputTestSystem(), events: events)
                do {
                    try await input.press(ComputerHostChord("a"), args: [:], authorize: {})
                    XCTFail("Missing native event was accepted")
                } catch let error as ComputerHostError { XCTAssertEqual(error.code, "failed") }
                XCTAssertEqual(events.posted.count, failure - 1)
            }
        }

        func testPointerShapesCountsAndReleasesUseCurrentCursor() async throws {
            for (verb, button, down, up, count) in [
                ("click", "left", CGEventType.leftMouseDown, CGEventType.leftMouseUp, 1),
                ("right_click", "right", .rightMouseDown, .rightMouseUp, 1),
                ("click", "middle", .otherMouseDown, .otherMouseUp, 1),
                ("double_click", "left", .leftMouseDown, .leftMouseUp, 2),
            ] {
                let system = MacComputerInputTestSystem()
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: system, events: events)
                var args: [String: JSONValue] = ["x": .number(20), "y": .number(30)]
                if verb == "click" { args["button"] = .string(button) }
                try await input.pointer(
                    request(verb, args: args), start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                XCTAssertEqual(events.posted.map(\.type), Array(repeating: [down, up], count: count).flatMap { $0 })
                XCTAssertEqual(
                    events.posted.filter { $0.type == down }.map { $0.getIntegerValueField(.mouseEventClickState) },
                    (1...count).map(Int64.init))
                XCTAssertTrue(
                    events.posted.filter { $0.type == up }.allSatisfy { $0.location == CGPoint(x: 80, y: 90) })
                XCTAssertTrue(events.posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 30 })
            }
        }

        func testPointerWindowFilteringAndOwnOrUnknownOverlayDenials() async throws {
            for owner: Int32? in [100, nil] {
                let system = MacComputerInputTestSystem()
                system.setWindows([MacComputerInputTestSystem.row(pid: owner)])
                let events = MacComputerInputTestEvents()
                let input = MacComputerInput(marker: 30, system: system, events: events)
                do {
                    try await input.pointer(
                        request("move", args: ["x": .number(20), "y": .number(30)]),
                        start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                    XCTFail("The host or unknown window accepted input")
                } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
                XCTAssertTrue(events.posted.isEmpty)
            }
            let system = MacComputerInputTestSystem()
            system.setWindows([
                MacComputerInputTestSystem.row(pid: 100, alpha: 0), [:], MacComputerInputTestSystem.row(pid: 200),
            ])
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            try await input.pointer(
                request("move", args: ["x": .number(20), "y": .number(30)]),
                start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
            XCTAssertEqual(events.posted.map(\.type), [.mouseMoved])
            system.setWindows(nil)
            do {
                try await input.pointer(
                    request("move", args: ["x": .number(20), "y": .number(30)]),
                    start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                XCTFail("Unavailable window topology accepted input")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
            XCTAssertEqual(events.posted.count, 1)
        }

        func testScrollFieldsAndAuthorityRecheckAfterPointerMove() async throws {
            let system = MacComputerInputTestSystem()
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            let call = try request(
                "scroll", args: ["x": .number(20), "y": .number(30), "dx": .number(2), "dy": .number(-4)])
            try await input.pointer(call, start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
            XCTAssertEqual(events.posted.map(\.type), [.mouseMoved, .scrollWheel])
            XCTAssertEqual(events.posted[1].getIntegerValueField(.scrollWheelEventDeltaAxis1), -4)
            XCTAssertEqual(events.posted[1].getIntegerValueField(.scrollWheelEventDeltaAxis2), 2)
            XCTAssertEqual(events.posted[1].location, CGPoint(x: 20, y: 30))
            let changed = MacComputerInputTestEvents()
            changed.configure { $0.onPost = { _, _ in system.setWindows([MacComputerInputTestSystem.row(pid: 100)]) } }
            let blocked = MacComputerInput(marker: 30, system: system, events: changed)
            do {
                try await blocked.pointer(call, start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                XCTFail("Scroll continued onto the host overlay")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
            XCTAssertEqual(changed.posted.map(\.type), [.mouseMoved])
        }

        func testPointerFactoryAndCursorFailuresRemainErrors() async throws {
            for fault in ["mouse", "cursor", "scroll"] {
                let events = MacComputerInputTestEvents()
                events.configure {
                    if fault == "mouse" { $0.mouseFailure = true }
                    if fault == "cursor" { $0.cursor = nil }
                    if fault == "scroll" { $0.scrollFailure = true }
                }
                let input = MacComputerInput(marker: 30, system: MacComputerInputTestSystem(), events: events)
                let verb = fault == "scroll" ? "scroll" : "click"
                do {
                    try await input.pointer(
                        request(verb, args: ["x": .number(20), "y": .number(30)]),
                        start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                    XCTFail("Unavailable native pointer resource was accepted")
                } catch let error as ComputerHostError {
                    XCTAssertEqual(error.code, fault == "cursor" ? "interrupted" : "failed")
                }
                XCTAssertEqual(events.posted.count, fault == "mouse" ? 0 : 1)
            }
        }

        func testDragStopsOnOverlayChangeAndReleasesAtCurrentCursor() async throws {
            let system = MacComputerInputTestSystem()
            let events = MacComputerInputTestEvents()
            events.configure {
                $0.onPost = { event, _ in
                    if event.type == .leftMouseDragged { system.setWindows([MacComputerInputTestSystem.row(pid: 100)]) }
                }
            }
            let input = MacComputerInput(marker: 30, system: system, events: events)
            do {
                try await input.pointer(
                    request(
                        "drag", args: ["x1": .number(20), "y1": .number(30), "x2": .number(40), "y2": .number(50)]),
                    start: CGPoint(x: 20, y: 30), end: CGPoint(x: 40, y: 50), authorize: {})
                XCTFail("Drag crossed a host overlay")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
            XCTAssertEqual(events.posted.last?.location, CGPoint(x: 80, y: 90))
        }

        func testCancelledDragStillNeutralizesHeldButtonAtCurrentCursor() async throws {
            let events = MacComputerInputTestEvents()
            let taskBox = MacComputerInputTestTask()
            events.configure { $0.onPost = { event, _ in if event.type == .leftMouseDragged { taskBox.cancel() } } }
            let input = MacComputerInput(marker: 30, system: MacComputerInputTestSystem(), events: events)
            let call = try request(
                "drag", args: ["x1": .number(20), "y1": .number(30), "x2": .number(40), "y2": .number(50)])
            let task = Task {
                try await input.pointer(call, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 40, y: 50), authorize: {})
            }
            taskBox.store(task)
            do {
                try await task.value
                XCTFail("Cancelled drag continued")
            } catch is CancellationError {}
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
            XCTAssertEqual(events.posted.last?.location, CGPoint(x: 80, y: 90))
        }
    }

    nonisolated final class MacComputerInputTestSystem: MacComputerSystemReading, @unchecked Sendable {
        let hostPID: pid_t = 100
        let hostBundleIdentifier: String? = "com.personalailabs.astraldeep"
        let root = AXUIElementCreateSystemWide()
        let app = AXUIElementCreateApplication(200)
        let focused = AXUIElementCreateApplication(201)
        let window = AXUIElementCreateApplication(202)
        private let lock = NSLock()
        private var trusted = true
        private var posting = true
        private var secure = false
        private var process: pid_t? = 200
        private var bundle: String? = "com.apple.TextEdit"
        private var values: [CFHashCode: [String: CFTypeRef]] = [:]
        private var rows: [[String: Any]]? = []

        enum Fault: CaseIterable {
            case accessibility, posting, secureInput, missingApp, invalidApp, missingPID, zeroPID, ownPID,
                missingBundle, missingControl, invalidControl, secureField, terminal
        }
        func apply(_ fault: Fault) {
            lock.withLock {
                switch fault {
                case .accessibility: trusted = false
                case .posting: posting = false
                case .secureInput: secure = true
                case .missingApp: values[CFHash(root)]?[kAXFocusedApplicationAttribute] = nil
                case .invalidApp: values[CFHash(root)]?[kAXFocusedApplicationAttribute] = "invalid" as CFString
                case .missingPID: process = nil
                case .zeroPID: process = 0
                case .ownPID: process = hostPID
                case .missingBundle: bundle = nil
                case .missingControl: values[CFHash(app)]?[kAXFocusedUIElementAttribute] = nil
                case .invalidControl: values[CFHash(app)]?[kAXFocusedUIElementAttribute] = "invalid" as CFString
                case .secureField:
                    values[CFHash(focused)] = [kAXSubroleAttribute: kAXSecureTextFieldSubrole as CFString]
                case .terminal: bundle = "com.apple.Terminal"
                }
            }
        }
        func setBundle(_ value: String?) { lock.withLock { bundle = value } }
        func setWindows(_ value: [[String: Any]]?) { lock.withLock { rows = value } }
        static func row(pid: Int32?, alpha: Double = 1) -> [String: Any] {
            var row: [String: Any] = [
                kCGWindowAlpha as String: NSNumber(value: alpha),
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 300, height: 300).dictionaryRepresentation,
            ]
            if let pid { row[kCGWindowOwnerPID as String] = NSNumber(value: pid) }
            return row
        }
        init() {
            values[CFHash(root)] = [kAXFocusedApplicationAttribute: app]
            values[CFHash(app)] = [kAXFocusedUIElementAttribute: focused]
        }
        func accessibilityTrusted() -> Bool { lock.withLock { trusted } }
        func postEventAccess() -> Bool { lock.withLock { posting } }
        func screenCaptureAccess() -> Bool { true }
        func listenEventAccess() -> Bool { true }
        func secureInputEnabled() -> Bool { lock.withLock { secure } }
        func systemElement() -> AXUIElement { root }
        func applicationElement(_ pid: pid_t) -> AXUIElement { app }
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            lock.withLock { values[CFHash(element)]?[name] }
        }
        func pid(of element: AXUIElement) -> pid_t? { lock.withLock { process } }
        func bundleIdentifier(for pid: pid_t) -> String? { lock.withLock { bundle } }
        func messagingTimeout(_ seconds: Float, for element: AXUIElement) {}
        func visibleWindows() -> [[String: Any]]? { lock.withLock { rows } }
    }

    nonisolated final class MacComputerInputTestEvents: MacComputerEventIO, @unchecked Sendable {
        struct State {
            var recorded: [CGEvent] = []
            var keyboardCreated = 0
            var keyboardFailure: Int?
            var mouseFailure = false
            var scrollFailure = false
            var cursor: CGPoint? = CGPoint(x: 80, y: 90)
            var onPost: (@Sendable (CGEvent, Int) -> Void)?
        }
        private let lock = NSRecursiveLock()
        private var state = State()
        @discardableResult func configure<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
        var posted: [CGEvent] { configure { $0.recorded } }
        func keyboard(key: CGKeyCode, down: Bool) -> CGEvent? {
            let fails = configure {
                $0.keyboardCreated += 1
                return $0.keyboardFailure == $0.keyboardCreated
            }
            return fails ? nil : MacComputerLiveEvents().keyboard(key: key, down: down)
        }
        func mouse(kind: CGEventType, point: CGPoint, button: CGMouseButton) -> CGEvent? {
            configure { $0.mouseFailure }
                ? nil : MacComputerLiveEvents().mouse(kind: kind, point: point, button: button)
        }
        func scroll(dy: Int32, dx: Int32) -> CGEvent? {
            configure { $0.scrollFailure } ? nil : MacComputerLiveEvents().scroll(dy: dy, dx: dx)
        }
        func cursor() -> CGPoint? { configure { $0.cursor } }
        func post(_ event: CGEvent) {
            let (callback, count) = configure {
                $0.recorded.append(event)
                return ($0.onPost, $0.recorded.count)
            }
            callback?(event, count)
        }
    }

    nonisolated final class MacComputerInputTestTask: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        func store(_ value: Task<Void, Error>) { lock.withLock { task = value } }
        func cancel() { lock.withLock { task?.cancel() } }
    }
#endif
