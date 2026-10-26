// Closed v1 computer-host models validate native execution requests before they reach platform drivers.
// Frames and current-channel transport use these values without granting local agent-host capability.

import CryptoKit
import Foundation

public struct ComputerHostError: Error, LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

public struct ComputerHostScreen: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let scale: Double
    public let primary: Bool
    public init(index: Int, width: Int, height: Int, scale: Double, primary: Bool) {
        self.index = index
        self.width = width
        self.height = height
        self.scale = scale
        self.primary = primary
    }
    public var json: JSONValue {
        .object([
            "index": .number(Double(index)), "width": .number(Double(width)), "height": .number(Double(height)),
            "scale": .number(scale), "primary": .bool(primary),
        ])
    }
}

public struct ComputerHostWorkspaceRoot: Sendable, Equatable {
    public let name: String
    public let path: String
    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
    var valid: Bool {
        !name.isEmpty && name.unicodeScalars.count <= 255
            && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) && path.hasPrefix("/")
            && path.utf8.count <= 1024 && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && !path.split(separator: "/").contains("..")
    }
    public var json: JSONValue { .object(["name": .string(name), "path": .string(path)]) }
}

public struct ComputerHostDescriptor: Sendable, Equatable {
    public static let maximumWorkspaceRoots = 32
    public let hostId: String
    public let name: String
    public let clientVersion: String
    public let screens: [ComputerHostScreen]
    public let verbs: [String]
    public let workspaceRoots: [ComputerHostWorkspaceRoot]
    public init(
        hostId: String, name: String, clientVersion: String, screens: [ComputerHostScreen], verbs: [String],
        workspaceRoots: [ComputerHostWorkspaceRoot] = []
    ) throws {
        guard computerUUID(hostId), !name.isEmpty, name.count <= 64,
            !name.unicodeScalars.contains(where: { $0.value < 32 }),
            clientVersion.range(
                of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$",
                options: .regularExpression) != nil,
            (1...8).contains(screens.count), screens.filter(\.primary).count == 1,
            screens.enumerated().allSatisfy({
                $0.offset == $0.element.index && (1...16384).contains($0.element.width)
                    && (1...16384).contains($0.element.height) && $0.element.scale.isFinite
                    && (0.5...8).contains($0.element.scale)
            }),
            !verbs.isEmpty, Set(verbs).count == verbs.count, Set(verbs).isSubset(of: ComputerHostRequest.verbs),
            workspaceRoots.count <= Self.maximumWorkspaceRoots, workspaceRoots.allSatisfy(\.valid),
            Set(workspaceRoots.map(\.path)).count == workspaceRoots.count
        else { throw ComputerHostError("out_of_range", "The computer descriptor is invalid.") }
        self.hostId = hostId
        self.name = name
        self.clientVersion = clientVersion
        self.screens = screens
        self.verbs = verbs.sorted()
        self.workspaceRoots = workspaceRoots
    }
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "host_id": .string(hostId), "name": .string(name), "platform": .string("macos"),
            "client_version": .string(clientVersion), "screens": .array(screens.map(\.json)),
            "verbs": .array(verbs.map(JSONValue.string)), "protocol": .number(1),
        ]
        if !workspaceRoots.isEmpty { object["workspace_roots"] = .array(workspaceRoots.map(\.json)) }
        return .object(object)
    }
}

public struct ComputerHostSession: Sendable, Equatable {
    public let id: String
    public let hostId: String
    public let state: String
    public let controller: String
    public init(json: JSONValue) throws {
        guard let id = json["session_id"]?.stringValue, computerUUID(id),
            let host = json["host_id"]?.stringValue, computerUUID(host),
            let state = json["state"]?.stringValue, ["active", "paused", "ended"].contains(state)
        else { throw ComputerHostError("no_session", "The session frame is invalid.") }
        self.id = id
        hostId = host
        self.state = state
        controller = String((json["controller_label"]?.stringValue ?? "your device").prefix(100))
    }
}

public struct ComputerHostRequest: Sendable, Equatable {
    public static let verbs: Set<String> = [
        "screenshot", "list_windows", "get_clipboard", "read_file", "list_dir", "wait", "click", "double_click",
        "right_click", "move", "drag", "scroll", "type_text", "press_keys", "focus_window", "open_app", "set_clipboard",
        "write_file", "delete_path", "run_command", "read_output", "interrupt_command", "browser_snapshot",
        "browser_get_text", "browser_screenshot", "browser_wait", "browser_navigate", "browser_click", "browser_fill",
        "browser_press", "browser_scroll", "browser_dialog",
    ]
    private static let deadlineCeilings: [String: Double] = [
        "run_command": 600000, "read_output": 30000, "interrupt_command": 5000, "browser_navigate": 15000,
        "browser_wait": 15000, "browser_snapshot": 5000, "browser_get_text": 5000, "browser_screenshot": 5000,
        "browser_click": 5000, "browser_fill": 5000, "browser_press": 5000, "browser_scroll": 5000,
        "browser_dialog": 5000,
    ]
    public static func maximumDeadlineMs(for verb: String) -> Double { deadlineCeilings[verb] ?? 30000 }
    public let id: String
    public let sessionId: String
    public let verb: String
    public let args: [String: JSONValue]
    public let deadline: Double
    public let digest: String

    public init(json: JSONValue) throws {
        guard let object = json.objectValue,
            Set(object.keys) == ["type", "request_id", "session_id", "verb", "args", "deadline_ms"],
            object["type"] == .string("computer_request"), let id = object["request_id"]?.stringValue,
            id.range(of: "^creq_[0-9a-f]{32}$", options: .regularExpression) != nil,
            let session = object["session_id"]?.stringValue, computerUUID(session),
            let verb = object["verb"]?.stringValue, Self.verbs.contains(verb),
            let args = object["args"]?.objectValue,
            let milliseconds = object["deadline_ms"]?.numberValue, milliseconds.isFinite,
            milliseconds.rounded() == milliseconds, (1...Self.maximumDeadlineMs(for: verb)).contains(milliseconds)
        else { throw ComputerHostError("out_of_range", "The computer request envelope is invalid.") }
        self.id = id
        sessionId = session
        self.verb = verb
        self.args = args
        deadline = milliseconds / 1000
        try Self.validate(verb, args)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        digest = SHA256.hash(data: try encoder.encode(json)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ verb: String, _ args: [String: JSONValue]) throws {
        let fields: [String: Set<String>] = [
            "screenshot": ["screen_index", "max_width"], "list_windows": [], "get_clipboard": [], "wait": ["seconds"],
            "read_file": ["path", "max_bytes"], "list_dir": ["path"], "write_file": ["path", "content", "if_exists"],
            "delete_path": ["path"],
            "click": ["x", "y", "button", "count", "hwnd"], "double_click": ["x", "y", "hwnd"],
            "right_click": ["x", "y", "hwnd"], "move": ["x", "y", "hwnd"],
            "drag": ["x1", "y1", "x2", "y2", "hwnd"], "scroll": ["x", "y", "dx", "dy", "hwnd"],
            "type_text": ["text", "terminal_ok", "hwnd", "terminal_app"],
            "press_keys": ["keys", "terminal_ok", "hwnd", "terminal_app"],
            "focus_window": ["hwnd", "title"], "open_app": ["app", "args"], "set_clipboard": ["text"],
            "run_command": ["command", "argv", "cwd", "env", "timeout_s", "background", "stdin"],
            "read_output": ["job_id", "stream", "offset", "max_bytes", "wait_s"],
            "interrupt_command": ["job_id", "signal"],
            "browser_snapshot": ["scope_ref", "mode", "max_chars"], "browser_get_text": ["ref", "max_chars"],
            "browser_screenshot": ["max_width", "ref"], "browser_wait": ["for", "text", "ref", "seconds"],
            "browser_navigate": ["url", "action"],
            "browser_click": ["ref", "button", "count", "snapshot_id", "confirm_element", "permit"],
            "browser_fill": ["fields", "snapshot_id", "confirm_element", "permit"], "browser_press": ["keys", "ref"],
            "browser_scroll": ["ref", "dy"], "browser_dialog": ["action", "text"],
        ]
        guard Set(args.keys).isSubset(of: fields[verb] ?? []) else {
            throw ComputerHostError("out_of_range", "Unexpected computer arguments.")
        }
        func integer(_ key: String, _ range: ClosedRange<Double>, required: Bool = false) throws {
            guard let value = args[key] else {
                if required { throw ComputerHostError("out_of_range", "Missing \(key).") }
                return
            }
            guard let n = value.numberValue, n.isFinite, n.rounded() == n, range.contains(n) else {
                throw ComputerHostError("out_of_range", "Invalid \(key).")
            }
        }
        func text(_ key: String, _ maximum: Int, empty: Bool = false) throws {
            guard let s = args[key]?.stringValue, empty || !s.isEmpty, s.unicodeScalars.count <= maximum,
                !s.contains("\0")
            else {
                throw ComputerHostError("out_of_range", "Invalid \(key).")
            }
        }
        func choice(_ key: String, _ values: Set<String>, required: Bool = false) throws {
            guard let value = args[key] else {
                if required { throw ComputerHostError("out_of_range", "Missing \(key).") }
                return
            }
            guard let s = value.stringValue, values.contains(s) else {
                throw ComputerHostError("out_of_range", "Invalid \(key).")
            }
        }
        func reference(_ key: String, required: Bool = false) throws {
            guard let value = args[key] else {
                if required { throw ComputerHostError("out_of_range", "Missing \(key).") }
                return
            }
            guard let s = value.stringValue, computerFullMatch(s, "^e[0-9]{1,9}$") else {
                throw ComputerHostError("out_of_range", "Invalid element reference \(key).")
            }
        }
        func seconds(_ key: String, _ range: ClosedRange<Double>) throws {
            if let v = args[key], !(v.numberValue.map { $0.isFinite && range.contains($0) } ?? false) {
                throw ComputerHostError("out_of_range", "Invalid \(key).")
            }
        }
        func bounded(_ value: JSONValue, _ maximum: Int) -> Bool {
            value.stringValue.map { $0.unicodeScalars.count <= maximum && !$0.contains("\0") } == true
        }
        if args["terminal_ok"] != nil, args["terminal_ok"]?.boolValue == nil {
            throw ComputerHostError("out_of_range", "Invalid terminal authority.")
        }
        if let terminal = args["terminal_app"] {
            guard let app = terminal.stringValue, ComputerTerminalPolicy.canonical(app) != nil, args["hwnd"] != nil
            else {
                throw ComputerHostError(
                    "out_of_range", "A terminal-specific action needs a known application and exact window.")
            }
        }
        for key in ["x", "y", "x1", "y1", "x2", "y2"] where fields[verb]?.contains(key) == true {
            try integer(key, 0...16383, required: true)
        }
        if args["hwnd"] != nil { try integer("hwnd", 1...Double(Int32.max)) }
        switch verb {
        case "screenshot":
            try integer("screen_index", 0...7)
            try integer("max_width", 320...1920)
        case "scroll":
            try integer("dx", -20...20)
            try integer("dy", -20...20)
        case "click":
            try integer("count", 1...2)
            if let button = args["button"],
                ![JSONValue.string("left"), .string("right"), .string("middle")].contains(button)
            {
                throw ComputerHostError("out_of_range", "Invalid pointer button.")
            }
        case "type_text": try text("text", 4000)
        case "press_keys":
            try text("keys", 100)
            _ = try ComputerHostChord(args["keys"]!.stringValue!)
        case "get_clipboard", "list_windows": break
        case "set_clipboard": try text("text", 16384, empty: true)
        case "open_app":
            try text("app", 1024)
            if let argv = args["args"], argv != .array([]) {
                throw ComputerHostError("unsupported", "Application arguments are not supported on this Mac.")
            }
        case "focus_window":
            guard args["hwnd"] != nil || args["title"] != nil else {
                throw ComputerHostError("window_not_found", "Specify a window.")
            }
            try integer("hwnd", 1...Double(Int32.max))
            if args["title"] != nil { try text("title", 200) }
        case "wait":
            if let v = args["seconds"], !(v.numberValue.map { $0.isFinite && (0.1...10).contains($0) } ?? false) {
                throw ComputerHostError("out_of_range", "Wait must be 0.1–10 seconds.")
            }
        case "read_file", "list_dir", "write_file", "delete_path":
            try text("path", 1024)
            guard args["path"]!.stringValue!.hasPrefix("/"),
                !args["path"]!.stringValue!.split(separator: "/").contains("..")
            else { throw ComputerHostError("out_of_range", "An absolute workspace path is required.") }
            if verb == "read_file" { try integer("max_bytes", 1...262144) }
            if verb == "write_file" {
                try text("content", 262144, empty: true)
                guard args["content"]!.stringValue!.utf8.count <= 262144,
                    args["if_exists"] == nil || [.string("refuse"), .string("overwrite")].contains(args["if_exists"]!)
                else { throw ComputerHostError("out_of_range", "Invalid file content or overwrite mode.") }
            }
        case "run_command":
            guard (args["command"] == nil) != (args["argv"] == nil) else {
                throw ComputerHostError("out_of_range", "Give exactly one of command or argv.")
            }
            if args["command"] != nil { try text("command", 4096) }
            if let argv = args["argv"] {
                guard let items = argv.arrayValue, (1...256).contains(items.count),
                    items.allSatisfy({ bounded($0, 4096) }), items[0].stringValue?.isEmpty == false
                else { throw ComputerHostError("out_of_range", "Invalid argv.") }
            }
            try text("cwd", 1024)
            guard args["cwd"]!.stringValue!.hasPrefix("/"),
                !args["cwd"]!.stringValue!.split(separator: "/").contains("..")
            else { throw ComputerHostError("out_of_range", "An absolute workspace folder is required.") }
            if let env = args["env"] {
                guard let variables = env.objectValue, variables.count <= 32,
                    variables.allSatisfy({
                        computerFullMatch($0.key, "^[A-Za-z_][A-Za-z0-9_]{0,127}$") && bounded($0.value, 4096)
                    })
                else { throw ComputerHostError("out_of_range", "Invalid command environment.") }
            }
            if args["background"] != nil, args["background"]?.boolValue == nil {
                throw ComputerHostError("out_of_range", "Invalid background.")
            }
            try integer("timeout_s", 1...(args["background"]?.boolValue == true ? 3600 : 600))
            if let stdin = args["stdin"] {
                guard let input = stdin.stringValue, input.utf8.count <= 16384, !input.contains("\0") else {
                    throw ComputerHostError("out_of_range", "Invalid stdin.")
                }
            }
        case "read_output", "interrupt_command":
            guard let job = args["job_id"]?.stringValue, computerUUID(job), computerFullMatch(job, "^[0-9a-f-]{36}$")
            else { throw ComputerHostError("out_of_range", "Invalid job_id.") }
            if verb == "interrupt_command" {
                try choice("signal", ["INT", "TERM", "KILL"], required: true)
            } else {
                try choice("stream", ["stdout", "stderr", "both"])
                try integer("offset", 0...9_007_199_254_740_991)
                try integer("max_bytes", 1...65536)
                try seconds("wait_s", 0...25)
            }
        case "browser_snapshot":
            try reference("scope_ref")
            try choice("mode", ["interactive", "all"])
            try integer("max_chars", 1...60000)
        case "browser_get_text":
            try reference("ref")
            try integer("max_chars", 1...60000)
        case "browser_screenshot":
            try integer("max_width", 320...1920)
            try reference("ref")
        case "browser_wait":
            try choice("for", ["load", "text", "ref"], required: true)
            let mode = args["for"]!.stringValue!
            guard (args["text"] != nil) == (mode == "text"), (args["ref"] != nil) == (mode == "ref") else {
                throw ComputerHostError("out_of_range", "browser_wait needs exactly the target its mode names.")
            }
            if mode == "text" { try text("text", 1000) }
            try reference("ref", required: mode == "ref")
            try seconds("seconds", 0.1...10)
        case "browser_navigate":
            guard (args["url"] == nil) != (args["action"] == nil) else {
                throw ComputerHostError("out_of_range", "Give exactly one of url or action.")
            }
            if args["url"] != nil {
                try text("url", 4096)
                guard computerWebURL(args["url"]!.stringValue!) else {
                    throw ComputerHostError("out_of_range", "Only http and https pages can be opened.")
                }
            } else {
                try choice("action", ["back", "forward", "reload"], required: true)
            }
        case "browser_click":
            try reference("ref", required: true)
            try choice("button", ["left", "right"])
            try integer("count", 1...2)
        case "browser_fill":
            guard let items = args["fields"]?.arrayValue, (1...32).contains(items.count),
                items.allSatisfy({
                    guard let field = $0.objectValue, Set(field.keys) == ["ref", "value"],
                        let ref = field["ref"]?.stringValue, computerFullMatch(ref, "^e[0-9]{1,9}$"),
                        let value = field["value"]
                    else { return false }
                    return bounded(value, 16384)
                })
            else { throw ComputerHostError("out_of_range", "Invalid browser fields.") }
        case "browser_press":
            try text("keys", 100)
            _ = try ComputerHostChord(args["keys"]!.stringValue!)
            try reference("ref")
        case "browser_scroll":
            try integer("dy", -10000...10000, required: true)
            try reference("ref")
        case "browser_dialog":
            try choice("action", ["accept", "dismiss"], required: true)
            if args["text"] != nil { try text("text", 4000, empty: true) }
        default: break
        }
        if ["browser_click", "browser_fill"].contains(verb) {
            guard let snapshot = args["snapshot_id"]?.stringValue, computerFullMatch(snapshot, "^s[0-9]{1,9}$") else {
                throw ComputerHostError(
                    "out_of_range", "Browser actions need the snapshot_id their reference came from.")
            }
            if args["confirm_element"] != nil { try text("confirm_element", 200) }
            if let permit = args["permit"] {
                func ref(_ value: JSONValue) -> Bool {
                    value.stringValue.map { computerFullMatch($0, "^e[0-9]{1,9}$") } == true
                }
                func refs(_ value: JSONValue) -> Bool {
                    value.arrayValue.map { (1...32).contains($0.count) && $0.allSatisfy(ref) } == true
                }
                guard let object = permit.objectValue,
                    Set(object.keys) == ["ref", "origin", "snapshot_id"]
                        || Set(object.keys) == ["refs", "origin", "snapshot_id"],
                    object["ref"].map(ref) ?? true, object["refs"].map(refs) ?? true,
                    let origin = object["origin"]?.stringValue, origin.unicodeScalars.count <= 2048,
                    computerWebURL(origin), let permitted = object["snapshot_id"]?.stringValue,
                    computerFullMatch(permitted, "^s[0-9]{1,9}$")
                else { throw ComputerHostError("out_of_range", "Invalid browser action permit.") }
            }
        }
    }
}

public struct ComputerHostChord: Sendable, Equatable {
    public let key: String
    public let modifiers: Set<String>
    public init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let aliases = [
            "control": "ctrl", "command": "cmd", "meta": "cmd", "option": "alt", "return": "enter", "esc": "escape",
            "spacebar": "space", "back": "backspace", "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
            "quote": "'", "apostrophe": "'", "leftbracket": "[", "bracketleft": "[", "rightbracket": "]",
            "bracketright": "]", "backslash": "\\", "minus": "-", "hyphen": "-", "equal": "=", "equals": "=",
            "grave": "`", "backtick": "`",
        ]
        let normalized = parts.map { aliases[$0] ?? $0 }
        let mods: Set<String> = ["ctrl", "cmd", "alt", "shift"]
        let keys = Set([
            "enter", "escape", "space", "tab", "backspace", "delete", "up", "down", "left", "right", "home", "end",
            "pageup", "pagedown",
        ])
        .union((1...12).map { "f\($0)" }).union("abcdefghijklmnopqrstuvwxyz0123456789,./;'[]\\-=`".map(String.init))
        guard let last = normalized.last, keys.contains(last), normalized.dropLast().allSatisfy(mods.contains),
            Set(normalized).count == normalized.count
        else { throw ComputerHostError("out_of_range", "The key chord is unsupported.") }
        key = last
        modifiers = Set(normalized.dropLast())
    }
}

public enum ComputerHostOutbound {
    private static let logicalKeys: Set<String> = ["type", "action", "payload"]
    private static let boundKeys: Set<String> = [
        "type", "action", "payload", "submission_id", "request_generation", "connection_generation",
    ]
    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = try? JSONValue.parse(Data(frameText.utf8)), frame["type"] == .string("ui_event") else {
            return false
        }
        return ["computer_event", "computer_response"].contains(frame["action"]?.stringValue ?? "")
    }
    public static func bindToConnection(
        _ text: String, connectionGeneration: String,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard computerUUID(connectionGeneration), computerUUID(submissionId), computerUUID(requestGeneration),
            isValid(text), var frame = try? JSONValue.parse(Data(text.utf8)).objectValue,
            Set(frame.keys) == logicalKeys
        else { return nil }
        frame["submission_id"] = .string(submissionId)
        frame["request_generation"] = .string(requestGeneration)
        frame["connection_generation"] = .string(connectionGeneration)
        guard let data = try? JSONValue.object(frame).encoded(), data.count <= 4 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func isBound(_ text: String, connectionGeneration: String) -> Bool {
        guard computerUUID(connectionGeneration), isValid(text),
            let frame = try? JSONValue.parse(Data(text.utf8)).objectValue
        else { return false }
        return Set(frame.keys) == boundKeys && frame["connection_generation"] == .string(connectionGeneration)
    }
    public static func isReviewDecision(_ text: String) -> Bool {
        guard text.utf8.count <= 16384, let json = try? JSONValue.parse(Data(text.utf8)),
            json["type"] == .string("ui_event"),
            let action = json["action"]?.stringValue, ["authorize_action", "remote_op_decision"].contains(action),
            let payload = json["payload"]?.objectValue, payload["decision"] == .string("approve_and_resume")
        else { return false }
        let key = action == "authorize_action" ? "hitl_request_id" : "proposal_id"
        return payload[key]?.stringValue.map { !$0.isEmpty && $0.count <= 200 } == true
            && Set(payload.keys).isSubset(of: [key, "decision", "submission_id", "request_generation"])
    }
    public static func frame(action: String, payload: [String: JSONValue]) -> String {
        let value = JSONValue.object([
            "type": .string("ui_event"), "action": .string(action), "payload": .object(payload),
        ])
        guard let data = try? value.encoded(), let text = String(data: data, encoding: .utf8), isValid(text) else {
            return "{}"
        }
        return text
    }
    public static func isValid(_ text: String) -> Bool {
        guard text.utf8.count <= 4 * 1024 * 1024, let json = try? JSONValue.parse(Data(text.utf8)),
            json["type"] == .string("ui_event"), let frame = json.objectValue,
            let payload = json["payload"]?.objectValue
        else { return false }
        let keys = Set(frame.keys)
        guard keys == logicalKeys || keys == boundKeys else { return false }
        if keys == boundKeys {
            guard
                ["submission_id", "request_generation", "connection_generation"].allSatisfy({
                    frame[$0]?.stringValue.map(computerUUID) == true
                })
            else { return false }
        }
        if json["action"] == .string("computer_response") {
            guard let id = payload["request_id"]?.stringValue,
                id.range(of: "^creq_[0-9a-f]{32}$", options: .regularExpression) != nil,
                let ok = payload["ok"]?.boolValue
            else { return false }
            return ok
                ? Set(payload.keys) == ["request_id", "ok", "result"] && payload["result"]?.objectValue != nil
                : Set(payload.keys) == ["request_id", "ok", "error"] && payload["error"]?["code"]?.stringValue != nil
                    && payload["error"]?["message"]?.stringValue != nil
        }
        guard json["action"] == .string("computer_event"), let host = payload["host_id"]?.stringValue,
            computerUUID(host), let event = payload["event"]?.stringValue
        else { return false }
        if event == "announce" {
            return Set(payload.keys) == ["host_id", "event", "host"] && payload["host"]?["host_id"] == .string(host)
        }
        if event == "withdraw" { return Set(payload.keys) == ["host_id", "event"] }
        return ["paused", "resumed", "stopped", "heartbeat"].contains(event)
            && payload["session_id"]?.stringValue.map(computerUUID) == true
            && Set(payload.keys).isSubset(of: ["host_id", "event", "session_id", "reason"])
    }
}

func computerFullMatch(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
}

func computerWebURL(_ text: String) -> Bool {
    guard !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
        let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty,
        components.user == nil, components.password == nil
    else { return false }
    return true
}

func computerUUID(_ value: String) -> Bool {
    value.range(
        of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
}

public enum ComputerTerminalPolicy {
    public static func launchBundle(_ app: String) -> String? {
        let basename = app.split(separator: "/").last.map(String.init) ?? app
        return canonical(app) ?? canonical(basename)
            ?? (basename.lowercased().hasSuffix(".app") ? canonical(String(basename.dropLast(4))) : nil)
    }
    public static func validateLaunch(_ app: String, bundle: String?) throws {
        if let expected = launchBundle(app), expected != bundle {
            throw ComputerHostError(
                "permission_denied", "The named terminal application does not match its actual bundle identity.")
        }
    }
    public static func requiresApproval(_ bundle: String) -> Bool {
        let folded = bundle.lowercased()
        return canonical(bundle) != nil
            || [
                "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.jetbrains.intellij",
                "com.jetbrains.pycharm",
            ].contains(folded) || folded.contains("terminal") || folded.contains("cursor")
    }
    public static func canonical(_ app: String) -> String? {
        let bundles = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        ]
        let aliases = [
            "terminal": "com.apple.Terminal", "terminal.app": "com.apple.Terminal", "iterm": "com.googlecode.iterm2",
            "iterm2": "com.googlecode.iterm2", "iterm.app": "com.googlecode.iterm2",
            "iterm2.app": "com.googlecode.iterm2", "ghostty": "com.mitchellh.ghostty", "warp": "dev.warp.Warp-Stable",
            "kitty": "net.kovidgoyal.kitty", "alacritty": "org.alacritty", "wezterm": "com.github.wez.wezterm",
        ]
        return aliases[app.lowercased()] ?? bundles.first { $0.lowercased() == app.lowercased() }
    }
    public static func authorize(_ app: String, bundle: String, granted: Bool) throws {
        guard granted, let expected = canonical(app), expected == bundle else {
            throw ComputerHostError(
                "confirmation_required",
                "The exact approved terminal application is not focused or its grant is missing.")
        }
    }
}

public enum ComputerHostText {
    public static func keyboardChunks(_ text: String) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                result.append(chunk)
                chunk = []
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

public enum ComputerHostDistribution {
    public static func permits(
        marker: String?, sandboxed: Bool, hardened: Bool, signatureValid: Bool, identityMatches: Bool,
        debuggerAllowed: Bool
    ) -> Bool {
        marker == "direct-download" && !sandboxed && hardened && signatureValid && identityMatches && !debuggerAllowed
    }
}

public enum ComputerHostGeometry {
    public static func validate(_ point: CGPoint, end: CGPoint?, within bounds: CGRect) throws {
        func contains(_ value: CGPoint) -> Bool {
            value.x.isFinite && value.y.isFinite && bounds.minX.isFinite && bounds.minY.isFinite
                && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
                && value.x >= bounds.minX && value.x < bounds.maxX && value.y >= bounds.minY && value.y < bounds.maxY
        }
        guard contains(point), end.map(contains) ?? true else {
            throw ComputerHostError("out_of_range", "The pointer action falls outside the exact reviewed window.")
        }
    }
}
