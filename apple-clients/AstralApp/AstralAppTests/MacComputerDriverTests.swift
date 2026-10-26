// Runs real driver request decisions against raw synthetic OS data and recorded native input.
// File operations use actual temporary workspaces while capture and application calls remain inert.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerDriverTests: XCTestCase {
        private func request(_ verb: String, _ args: [String: JSONValue] = [:]) throws -> ComputerHostRequest {
            try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string(verb),
                    "args": .object(args), "deadline_ms": .number(30000),
                ]))
        }
        private func driver(_ io: MacComputerTestSystem) -> (MacComputerDriver, MacComputerInputTestEvents) {
            let events = MacComputerInputTestEvents()
            return (
                MacComputerDriver(
                    marker: 30, system: io, input: MacComputerInput(marker: 30, system: io, events: events)), events
            )
        }
        private func error(_ expected: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                XCTFail("Expected refusal")
            } catch {
                XCTAssertEqual((error as? ComputerHostError)?.code, expected)
            }
        }
        private func observe(_ driver: MacComputerDriver) async throws {
            _ = try await driver.execute(request("list_windows"), workspaces: [], authorize: {})
            _ = try await driver.execute(
                request("screenshot", ["max_width": .number(320)]), workspaces: [], authorize: {})
        }
        func testActualScreenshotTransportAndObservedPointerMapping() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            _ = try await driver.execute(request("list_windows"), workspaces: [], authorize: {})
            let image = try await driver.execute(
                request("screenshot", ["max_width": .number(320)]), workspaces: [], authorize: {})
            XCTAssertEqual(image["width"], .number(320))
            XCTAssertEqual(image["height"], .number(240))
            XCTAssertEqual(image["media_type"], .string("image/jpeg"))
            XCTAssertEqual(image["scale"], .number(4))
            XCTAssertFalse(try XCTUnwrap(image["base64"]?.stringValue).isEmpty)
            XCTAssertEqual(io.configure { $0.plans.first?.excludedWindows }, [5])
            _ = try await driver.execute(
                request("click", ["x": .number(20), "y": .number(30), "hwnd": .number(1)]), workspaces: [],
                authorize: {})
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            XCTAssertEqual(events.posted.first?.location, CGPoint(x: 40, y: 60))
        }
        func testPermissionsDesktopAndMissingObservationDenyBeforeAnyEffect() async throws {
            for denial in 0..<5 {
                let io = MacComputerTestSystem()
                io.configure {
                    switch denial {
                    case 0: $0.accessibility = false
                    case 1: $0.posting = false
                    case 2: $0.screen = false
                    case 3: $0.monitoring = false
                    default: $0.session = nil
                    }
                }
                let (driver, events) = driver(io)
                await error("permission_denied") {
                    _ = try await driver.execute(self.request("get_clipboard"), workspaces: [], authorize: {})
                }
                XCTAssertTrue(events.posted.isEmpty)
                XCTAssertFalse(io.configure { $0.trace.contains("clipboardRead") })
            }
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            await error("stale_target") {
                _ = try await driver.execute(
                    self.request("click", ["x": .number(1), "y": .number(1)]), workspaces: [], authorize: {})
            }
            XCTAssertTrue(events.posted.isEmpty)
        }
        func testSecureInputRefusesKeyboardButKeepsObservationAndPointerVerbs() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            io.configure { $0.secure = true }
            io.configure { $0.clipboard = "Synthetic" }
            let clipboard = try await driver.execute(request("get_clipboard"), workspaces: [], authorize: {})
            XCTAssertEqual(clipboard["text"], .string("Synthetic"))
            try await observe(driver)
            for verb in ["type_text", "press_keys"] {
                await error("secure_input_active") {
                    _ = try await driver.execute(
                        self.request(verb, verb == "type_text" ? ["text": .string("x")] : ["keys": .string("a")]),
                        workspaces: [], authorize: {})
                }
            }
            XCTAssertTrue(events.posted.isEmpty)
            let click = try await driver.execute(
                request("click", ["x": .number(1), "y": .number(1)]), workspaces: [], authorize: {})
            XCTAssertEqual(click["attempted"], .bool(true))
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
        }
        func testInputResultsCarryASettledBoundedScreenshotWithoutFailingTheEffect() async throws {
            let io = MacComputerTestSystem()
            io.configure { $0.captureDisplays = [MacComputerCaptureDisplay(id: 77, width: 2560, height: 1600)] }
            let (driver, events) = driver(io)
            try await observe(driver)
            let plans = io.configure { $0.plans.count }
            let click = try await driver.execute(
                request("click", ["x": .number(1), "y": .number(1)]), workspaces: [], authorize: {})
            let shot = try XCTUnwrap(click["screenshot"])
            XCTAssertEqual(shot["width"], .number(1280))
            XCTAssertEqual(shot["height"], .number(800))
            XCTAssertEqual(shot["media_type"], .string("image/jpeg"))
            XCTAssertEqual(shot["screen_index"], .number(0))
            XCTAssertFalse(try XCTUnwrap(shot["base64"]?.stringValue).isEmpty)
            XCTAssertEqual(io.configure { $0.plans.count }, plans + 1)
            XCTAssertEqual(io.configure { $0.plans.last?.excludedWindows }, [5])
            let trace = io.configure { $0.trace }
            let posted = try XCTUnwrap(trace.lastIndex(of: "delay"))
            XCTAssertLessThan(posted, try XCTUnwrap(trace.lastIndex(of: "capture")))
            io.configure { $0.jpegOverride = Data(repeating: 0, count: 2_900_001) }
            let oversized = try await driver.execute(
                request("move", ["x": .number(2), "y": .number(2)]), workspaces: [], authorize: {})
            XCTAssertEqual(oversized["attempted"], .bool(true))
            XCTAssertNil(oversized["screenshot"])
            io.configure {
                $0.jpegOverride = nil
                $0.captureFailure = true
            }
            let typed = try await driver.execute(
                request("type_text", ["text": .string("ok")]), workspaces: [], authorize: {})
            XCTAssertEqual(typed["chars"], .number(2))
            XCTAssertNil(typed["screenshot"])
            XCTAssertEqual(events.posted.count, 5)
            let clipboard = try await driver.execute(
                request("set_clipboard", ["text": .string("x")]), workspaces: [], authorize: {})
            XCTAssertNil(clipboard["screenshot"])
        }
        func testPointerRechecksPermissionFocusAndTopologyAfterFirstEvent() async throws {
            for change in 0..<3 {
                let io = MacComputerTestSystem()
                let (driver, events) = driver(io)
                try await observe(driver)
                events.configure { state in
                    state.onPost = { _, count in
                        if count == 1 {
                            io.configure {
                                if change == 0 { $0.posting = false }
                                if change == 1 { $0.nodes[1].pid = 201 }
                                if change == 2 { $0.bounds.origin.x = 10 }
                            }
                        }
                    }
                }
                do {
                    _ = try await driver.execute(
                        request("drag", ["x1": .number(1), "y1": .number(1), "x2": .number(30), "y2": .number(30)]),
                        workspaces: [], authorize: {})
                    XCTFail("Changed authority continued a drag")
                } catch { XCTAssertTrue(error is ComputerHostError) }
                XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
                XCTAssertEqual(events.posted.last?.location, CGPoint(x: 80, y: 90))
            }
        }
        func testScreenshotDenialsAndFocusInvalidatePointerEvidence() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            try await observe(driver)
            let focused = try await driver.execute(
                request("focus_window", ["title": .string("Synthetic")]), workspaces: [], authorize: {})
            XCTAssertNotNil(focused["screenshot"])
            io.configure { $0.jpegFailure = true }
            let unobserved = try await driver.execute(
                request("focus_window", ["title": .string("Synthetic")]), workspaces: [], authorize: {})
            XCTAssertNil(unobserved["screenshot"])
            await error("stale_target") {
                _ = try await driver.execute(
                    self.request("click", ["x": .number(1), "y": .number(1)]), workspaces: [], authorize: {})
            }
            await error("out_of_range") {
                _ = try await driver.execute(self.request("screenshot"), workspaces: [], authorize: {})
            }
            io.configure {
                $0.jpegFailure = false
                $0.jpegOverride = Data(repeating: 0, count: 2_900_001)
            }
            await error("out_of_range") {
                _ = try await driver.execute(self.request("screenshot"), workspaces: [], authorize: {})
            }
            XCTAssertTrue(events.posted.isEmpty)
        }
        func testClipboardBoundsAndNativeFailureUseActualDriverBranches() async throws {
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            io.configure { $0.clipboard = String(repeating: "🧭", count: 17000) }
            let result = try await driver.execute(request("get_clipboard"), workspaces: [], authorize: {})
            XCTAssertEqual(result["text"]?.stringValue?.unicodeScalars.count, 16384)
            XCTAssertEqual(result["truncated"], .bool(true))
            _ = try await driver.execute(
                request("set_clipboard", ["text": .string("Synthetic")]), workspaces: [], authorize: {})
            XCTAssertEqual(io.configure { $0.clipboard }, "Synthetic")
            io.configure { $0.clipboardWrite = false }
            await error("failed") {
                _ = try await driver.execute(
                    self.request("set_clipboard", ["text": .string("next")]), workspaces: [], authorize: {})
            }
        }
        func testSelectedWorkspaceDispatchUsesActualDescriptorRelativeIO() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let workspace = try ComputerWorkspace(root: folder.resolvingSymlinksInPath().path)
            let path = workspace.root + "/file.txt"
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            _ = try await driver.execute(
                request("write_file", ["path": .string(path), "content": .string("Synthetic")]),
                workspaces: [workspace], authorize: {})
            let read = try await driver.execute(
                request("read_file", ["path": .string(path)]), workspaces: [workspace], authorize: {})
            XCTAssertEqual(read["text"], .string("Synthetic"))
            let list = try await driver.execute(
                request("list_dir", ["path": .string(workspace.root)]), workspaces: [workspace], authorize: {})
            XCTAssertNotNil(list["entries"])
            _ = try await driver.execute(
                request("delete_path", ["path": .string(path)]), workspaces: [workspace], authorize: {})
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("read_file", ["path": .string(path)]), workspaces: [], authorize: {})
            }
        }
        func testRevokedCaptureAuthorityNeverReachesThePhysicalCaptureBoundary() async throws {
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            io.configure { $0.hook = { name in if name == "content" { io.configure { $0.posting = false } } } }
            await error("permission_denied") {
                _ = try await driver.execute(self.request("screenshot"), workspaces: [], authorize: {})
            }
            XCTAssertTrue(io.configure { $0.plans.isEmpty })
        }
        func testRevokedClipboardAuthorityCannotContinueAfterClearing() async throws {
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            io.configure { $0.hook = { name in if name == "clipboardClear" { io.configure { $0.posting = false } } } }
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("set_clipboard", ["text": .string("denied")]), workspaces: [], authorize: {})
            }
            XCTAssertFalse(io.configure { $0.trace.contains("clipboardWrite") })
        }
        func testScreenshotEnumerationCaptureAndEncodingFailuresStayFailClosed() async throws {
            for scenario in 0..<7 {
                let io = MacComputerTestSystem()
                let (driver, events) = driver(io)
                io.configure {
                    switch scenario {
                    case 0: $0.displays = []
                    case 1: $0.enumerationError = .failure
                    case 2: $0.captureDisplays = []
                    case 3: $0.captureDisplays = [MacComputerCaptureDisplay(id: 77, width: 0, height: 1)]
                    case 4: $0.contentFailure = true
                    case 5: $0.captureFailure = true
                    default: $0.jpegOverride = Data()
                    }
                }
                do {
                    _ = try await driver.execute(request("screenshot"), workspaces: [], authorize: {})
                    XCTFail("Unavailable capture returned pixels")
                } catch { XCTAssertFalse(error is CancellationError) }
                XCTAssertTrue(events.posted.isEmpty)
            }
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            await error("out_of_range") {
                _ = try await driver.execute(
                    self.request("screenshot", ["screen_index": .number(1)]), workspaces: [], authorize: {})
            }
        }
        func testUnknownScreenshotForegroundAndDisplayEdgesCannotAuthorizePointer() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            io.configure {
                $0.hook = { name in
                    if name == "capture" { io.setBounds(CGRect(x: 10, y: 0, width: 640, height: 480), of: io.window) }
                }
            }
            _ = try await driver.execute(request("screenshot"), workspaces: [], authorize: {})
            await error("stale_target") {
                _ = try await driver.execute(
                    self.request("move", ["x": .number(1), "y": .number(1)]), workspaces: [], authorize: {})
            }
            io.configure { $0.hook = nil }
            try await observe(driver)
            await error("out_of_range") {
                _ = try await driver.execute(
                    self.request("move", ["x": .number(320), "y": .number(0)]), workspaces: [], authorize: {})
            }
            await error("out_of_range") {
                _ = try await driver.execute(
                    self.request("drag", ["x1": .number(1), "y1": .number(1), "x2": .number(320), "y2": .number(1)]),
                    workspaces: [], authorize: {})
            }
            XCTAssertTrue(events.posted.isEmpty)
        }
        func testEveryPointerVerbAndKeyboardVerbUsesActualInputAdapter() async throws {
            for verb in ["click", "double_click", "right_click", "move", "scroll", "drag"] {
                let io = MacComputerTestSystem()
                let (driver, events) = driver(io)
                try await observe(driver)
                let args: [String: JSONValue] =
                    verb == "drag"
                    ? ["x1": .number(1), "y1": .number(1), "x2": .number(20), "y2": .number(20)]
                    : ["x": .number(1), "y": .number(1)]
                let value = try await driver.execute(request(verb, args), workspaces: [], authorize: {})
                XCTAssertEqual(value["attempted"], .bool(true))
                XCTAssertEqual(value["screenshot"]?["media_type"], .string("image/jpeg"), verb)
                XCTAssertFalse(events.posted.isEmpty)
                XCTAssertTrue(events.posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 30 })
            }
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            try await observe(driver)
            let text = try await driver.execute(
                request("type_text", ["text": .string("Synthetic")]), workspaces: [], authorize: {})
            XCTAssertEqual(text["chars"], .number(9))
            XCTAssertNotNil(text["screenshot"])
            let chord = try await driver.execute(
                request("press_keys", ["keys": .string("cmd+a")]), workspaces: [], authorize: {})
            XCTAssertEqual(chord["keys"], .string("cmd+a"))
            XCTAssertNotNil(chord["screenshot"])
            XCTAssertEqual(events.posted.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        }
        func testWindowEnumerationIsBoundedAndResetDoesNotReuseOldIdentities() async throws {
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            io.set(Array(repeating: io.window, count: 150) as CFArray, attribute: kAXWindowsAttribute, of: io.app)
            io.set(String(repeating: "title", count: 100) as CFString, attribute: kAXTitleAttribute, of: io.window)
            let listed = try await driver.execute(request("list_windows"), workspaces: [], authorize: {})
            XCTAssertEqual(listed["windows"]?.arrayValue?.count, 100)
            XCTAssertEqual(listed["windows"]?.arrayValue?.first?["title"]?.stringValue?.count, 200)
            await error("window_not_found") {
                _ = try await driver.execute(
                    self.request("focus_window", ["title": .string("title")]), workspaces: [], authorize: {})
            }
            await driver.reset()
            await error("window_not_found") {
                _ = try await driver.execute(
                    self.request("focus_window", ["hwnd": .number(1)]), workspaces: [], authorize: {})
            }
            io.set(nil, attribute: kAXTitleAttribute, of: io.window)
            let none = try await driver.execute(request("list_windows"), workspaces: [], authorize: {})
            XCTAssertEqual(none["windows"], .array([]))
        }
        func testExplicitFocusMustActuallyActivateAndRetainReviewedGeometry() async throws {
            for repair in [false, true] {
                let io = MacComputerTestSystem()
                let (driver, events) = driver(io)
                try await observe(driver)
                io.configure {
                    $0.hook = { name in
                        if name == "raise" { io.setBounds(CGRect(x: 1, y: 0, width: 640, height: 480), of: io.window) }
                        if name == "delay", repair {
                            io.setBounds(CGRect(x: 0, y: 0, width: 640, height: 480), of: io.window)
                        }
                    }
                }
                do {
                    _ = try await driver.execute(
                        request("click", ["x": .number(1), "y": .number(1), "hwnd": .number(1)]), workspaces: [],
                        authorize: {})
                    XCTAssertTrue(repair)
                } catch {
                    XCTAssertFalse(repair)
                    XCTAssertEqual((error as? ComputerHostError)?.code, "stale_target")
                }
                XCTAssertEqual(events.posted.isEmpty, !repair)
            }
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            try await observe(driver)
            io.configure { $0.activation = false }
            await error("failed") {
                _ = try await driver.execute(
                    self.request("focus_window", ["hwnd": .number(1)]), workspaces: [], authorize: {})
            }
            io.configure {
                $0.activation = true
                $0.actionResult = .cannotComplete
            }
            await error("failed") {
                _ = try await driver.execute(
                    self.request("focus_window", ["hwnd": .number(1)]), workspaces: [], authorize: {})
            }
        }
        func testExactTerminalGrantAndOwnTargetChecksPrecedeKeyboardEffect() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            try await observe(driver)
            io.configure { $0.bundles[200] = "com.apple.Terminal" }
            await error("confirmation_required") {
                _ = try await driver.execute(
                    self.request("type_text", ["text": .string("denied"), "hwnd": .number(1)]), workspaces: [],
                    authorize: {})
            }
            await error("confirmation_required") {
                _ = try await driver.execute(
                    self.request(
                        "type_text",
                        [
                            "text": .string("denied"), "hwnd": .number(1), "terminal_ok": .bool(true),
                            "terminal_app": .string("com.googlecode.iterm2"),
                        ]), workspaces: [], authorize: {})
            }
            XCTAssertTrue(events.posted.isEmpty)
            _ = try await driver.execute(
                request(
                    "type_text",
                    [
                        "text": .string("Synthetic"), "hwnd": .number(1), "terminal_ok": .bool(true),
                        "terminal_app": .string("com.apple.Terminal"),
                    ]), workspaces: [], authorize: {})
            XCTAssertEqual(events.posted.count, 2)
            io.configure { $0.nodes[2].pid = 100 }
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("type_text", ["text": .string("denied"), "hwnd": .number(1)]), workspaces: [],
                    authorize: {})
            }
            XCTAssertEqual(events.posted.count, 2)
        }
        private func application(_ bundle: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let app = root.appendingPathComponent("Fixture.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundle, "CFBundlePackageType": "APPL"], format: .xml,
                options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return app
        }
        func testApplicationLaunchValidatesResolvedAndReturnedTerminalIdentity() async throws {
            let io = MacComputerTestSystem()
            let (driver, _) = driver(io)
            let ordinary = try application("fixture.editor")
            io.configure { $0.applicationURL = ordinary }
            let launched = try await driver.execute(
                request("open_app", ["app": .string("fixture.editor")]), workspaces: [], authorize: {})
            XCTAssertEqual(launched["launched"], .bool(true))
            XCTAssertEqual(launched["bundle_id"], .string("fixture.editor"))
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("open_app", ["app": .string("Terminal")]), workspaces: [], authorize: {})
            }
            let terminal = try application("com.apple.Terminal")
            io.configure { $0.applicationURL = terminal }
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("open_app", ["app": .string("Terminal")]), workspaces: [], authorize: {})
            }
            let own = try application("fixture.host")
            await error("permission_denied") {
                _ = try await driver.execute(
                    self.request("open_app", ["app": .string(own.path)]), workspaces: [], authorize: {})
            }
            await error("not_found") {
                _ = try await driver.execute(
                    self.request("open_app", ["app": .string(ordinary.path + "/missing.app")]), workspaces: [],
                    authorize: {})
            }
            io.configure {
                $0.applicationURL = ordinary
                $0.launchFailure = true
            }
            do {
                _ = try await driver.execute(
                    request("open_app", ["app": .string("fixture.editor")]), workspaces: [], authorize: {})
                XCTFail("Native launch failure was swallowed")
            } catch { XCTAssertTrue(error is CocoaError) }
        }
        func testWaitAndResetRemainAuthorityCheckedWithoutWallClockAssertions() async throws {
            let io = MacComputerTestSystem()
            let (driver, events) = driver(io)
            let result = try await driver.execute(
                request("wait", ["seconds": .number(0.1)]), workspaces: [], authorize: {})
            XCTAssertEqual(result["waited"], .number(0.1))
            XCTAssertTrue(io.configure { $0.trace.contains("delay") })
            try await observe(driver)
            await driver.reset()
            await error("stale_target") {
                _ = try await driver.execute(
                    self.request("type_text", ["text": .string("denied")]), workspaces: [], authorize: {})
            }
            XCTAssertTrue(events.posted.isEmpty)
        }
    }
#endif
