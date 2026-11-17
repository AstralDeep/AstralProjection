// Backend selection for the execution policy: the facts a node reports, the refusal texts, the ordered selection table and the facts probe for this device.
// ExecLauncher selects through it before every launch, and the Mac governed-command path asks ExecBackends.current whether confinement exists.

import AstralExecSpawn
import Foundation

public enum ExecBackend: String, Sendable, Equatable {
    case seatbelt
    case linux
}

public enum ExecBackendReason: String, Sendable, Equatable {
    case landlockABI = "landlock_abi"
    case bwrapMissing = "bwrap_missing"
    case usernsDenied = "userns_denied"
    case rootNode = "root_node"
    case sandboxExecMissing = "sandbox_exec_missing"
    case appSandboxed = "app_sandboxed"
    case platformUnsupported = "platform_unsupported"
}

public struct ExecRefusal: Sendable, Equatable {
    public let code: String
    public let reason: ExecBackendReason?
    public let observed: Int?
    public let required: Int?
    public let platform: String?
    public let message: String

    public var json: ExecJSON {
        var members: [(key: String, value: ExecJSON)] = [("ok", .bool(false)), ("code", .string(code))]
        if let reason { members.append(("reason", .string(reason.rawValue))) }
        if let observed { members.append(("observed", .int(Int64(observed)))) }
        if let required { members.append(("required", .int(Int64(required)))) }
        if let platform { members.append(("platform", .string(platform))) }
        members.append(("message", .string(message)))
        return .object(members)
    }
}

public struct ExecRefused: Error, Equatable, Sendable {
    public let refusal: ExecRefusal

    init(_ refusal: ExecRefusal) { self.refusal = refusal }
}

public enum ExecSelection: Sendable, Equatable {
    case backend(ExecBackend)
    case refused(ExecRefusal)
}

public enum ExecBackendAvailability: Sendable, Equatable {
    case available(ExecBackend)
    case unavailable(ExecBackendReason)
}

public enum ExecMode: String, Sendable, Equatable {
    case enforce
    case shadow
}

public struct ExecFacts: Sendable, Equatable {
    public var platform: String
    public var mode: ExecMode
    public var landlockABI: Int
    public var bwrap: Bool
    public var userns: Bool
    public var euid: Int
    public var sandboxExec: Bool
    public var appSandboxed: Bool

    public init(
        platform: String, mode: ExecMode = .enforce, landlockABI: Int = 0, bwrap: Bool = false, userns: Bool = false,
        euid: Int, sandboxExec: Bool = false, appSandboxed: Bool = false
    ) {
        self.platform = platform
        self.mode = mode
        self.landlockABI = landlockABI
        self.bwrap = bwrap
        self.userns = userns
        self.euid = euid
        self.sandboxExec = sandboxExec
        self.appSandboxed = appSandboxed
    }

    static let keys = ["platform", "mode", "landlock_abi", "bwrap", "userns", "euid", "sandbox_exec", "app_sandboxed"]

    public init(json: ExecJSON) throws {
        guard case .object(let members) = json else { throw ExecContextError("facts must be an object") }
        let unknown = members.filter { member in !Self.keys.contains { $0.utf8.elementsEqual(member.key.utf8) } }
        if !unknown.isEmpty { throw ExecContextError("unknown facts: \(unknown.map(\.key).sorted())") }
        guard case .string(let platform)? = json["platform"] else { throw ExecContextError("facts.platform must be a string") }
        var mode = ExecMode.enforce
        if let given = json["mode"] {
            guard case .string(let text) = given, let parsed = ExecMode(rawValue: text) else {
                throw ExecContextError("facts.mode must be enforce or shadow")
            }
            mode = parsed
        }
        func count(_ key: String) throws -> Int {
            guard case .int(let value)? = json[key], value >= 0 else {
                throw ExecContextError("facts.\(key) must be a non-negative integer")
            }
            return Int(value)
        }
        func flag(_ key: String) throws -> Bool {
            guard case .bool(let value)? = json[key] else { throw ExecContextError("facts.\(key) must be a boolean") }
            return value
        }
        self.init(
            platform: platform, mode: mode, landlockABI: try count("landlock_abi"), bwrap: try flag("bwrap"),
            userns: try flag("userns"), euid: try count("euid"), sandboxExec: try flag("sandbox_exec"),
            appSandboxed: try flag("app_sandboxed"))
    }
}

public enum ExecBackends {
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"
    public static let requiredLandlockABI = 6
    static let execSubdirectory = "exec"
    static let darwinBase = ["/usr", "/System", "/Library", "/private/etc", "/private/var/db/dyld", "/dev"]
    static let linuxBase = ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"]

    public static let messages: [String: String] = [
        "exec.backend_unavailable": "No confinement backend can run untrusted tools on this machine.",
        "exec.agent_server_unsupported":
            "Agents you create cannot run on this node yet, because it has no way to confine them.",
        "exec.shadow_refused": "Shadow mode never runs untrusted code.",
        "exec.policy_overlaps_data": "A read root or the workspace contains the node data directory.",
        "exec.time_limit": "The tool ran past its time limit and was stopped.",
        "exec.memory_limit": "The tool used more memory than its limit allows and was stopped.",
        "exec.process_limit": "The tool started more processes than its limit allows and was stopped.",
        "exec.file_limit": "The tool went past its open file or file size limit and was stopped.",
        "exec.launch_failed": "The confinement backend could not start the tool.",
        "landlock_abi":
            "This Linux kernel offers Landlock ABI {observed} and untrusted tools need ABI {required} or newer.",
        "bwrap_missing": "bubblewrap (bwrap) is not installed, and untrusted tools need it.",
        "userns_denied":
            "Unprivileged user namespaces are disabled, and bubblewrap needs them to confine untrusted tools.",
        "root_node":
            "This node runs as root, and bubblewrap would map root to root inside the sandbox. Run the node as an unprivileged user.",
        "sandbox_exec_missing": "/usr/bin/sandbox-exec is missing, and untrusted tools need it on macOS.",
        "app_sandboxed":
            "The App Sandboxed build cannot confine child processes, so it cannot host untrusted tools. Use the direct-download build.",
        "platform_unsupported": "No confinement backend exists for {platform}.",
    ]

    static func refusal(
        code: String, reason: ExecBackendReason? = nil, observed: Int? = nil, required: Int? = nil, platform: String? = nil
    ) -> ExecRefusal {
        var text = messages[reason?.rawValue ?? code] ?? code
        if let observed { text = text.replacingOccurrences(of: "{observed}", with: String(observed)) }
        if let required { text = text.replacingOccurrences(of: "{required}", with: String(required)) }
        if let platform { text = text.replacingOccurrences(of: "{platform}", with: platform) }
        return ExecRefusal(
            code: code, reason: reason, observed: observed, required: required, platform: platform, message: text)
    }

    private static func unavailable(_ reason: ExecBackendReason, observed: Int? = nil, platform: String? = nil) -> ExecSelection {
        .refused(
            refusal(
                code: "exec.backend_unavailable", reason: reason, observed: observed,
                required: reason == .landlockABI ? requiredLandlockABI : nil, platform: platform))
    }

    static func decide(_ facts: ExecFacts) -> ExecSelection {
        switch facts.platform {
        case "linux":
            if facts.landlockABI < requiredLandlockABI { return unavailable(.landlockABI, observed: facts.landlockABI) }
            if !facts.bwrap { return unavailable(.bwrapMissing) }
            if !facts.userns { return unavailable(.usernsDenied) }
            if facts.euid == 0 { return unavailable(.rootNode) }
            return .backend(.linux)
        case "darwin":
            if !facts.sandboxExec { return unavailable(.sandboxExecMissing) }
            if facts.appSandboxed { return unavailable(.appSandboxed) }
            return .backend(.seatbelt)
        default:
            return unavailable(.platformUnsupported, platform: facts.platform)
        }
    }

    public static func select(policy: ExecPolicy, facts: ExecFacts, dataDirectory: String) throws -> ExecSelection {
        let platform = facts.platform
        let checked = try ExecPolicy(json: policy.canonicalData, platform: platform)
        if ExecPolicy.pathProblem(dataDirectory) != nil {
            throw ExecContextError("data_dir must be an absolute normalized path")
        }
        if platform == "darwin", ExecPolicy.hasUnassigned(dataDirectory) {
            throw ExecContextError("data_dir holds an unassigned code point")
        }
        let base = platform == "darwin" ? darwinBase : platform == "linux" ? linuxBase : []
        var overlaps = (base + checked.reads).contains {
            ExecPathFold.contains($0, dataDirectory, platform: platform)
                || ExecPathFold.contains(dataDirectory, $0, platform: platform)
        }
        overlaps = overlaps || ExecPathFold.contains(checked.workspace, dataDirectory, platform: platform)
        if ExecPathFold.contains(dataDirectory, checked.workspace, platform: platform) {
            let root = ExecPathFold.folded("\(dataDirectory)/\(execSubdirectory)/", platform: platform)
            let workspace = ExecPathFold.folded(checked.workspace, platform: platform)
            overlaps = overlaps || !(workspace.count >= root.count && Array(workspace[0..<root.count]) == root)
        }
        if overlaps { return .refused(refusal(code: "exec.policy_overlaps_data")) }
        if facts.mode == .shadow { return .refused(refusal(code: "exec.shadow_refused")) }
        return decide(facts)
    }

    public static var current: ExecBackendAvailability {
        #if os(macOS)
            switch decide(probe()) {
            case .backend(let backend): return .available(backend)
            case .refused(let refusal): return .unavailable(refusal.reason ?? .platformUnsupported)
            }
        #else
            return .unavailable(.platformUnsupported)
        #endif
    }

    #if os(macOS)
        public static func probe() -> ExecFacts {
            ExecFacts(
                platform: "darwin", euid: Int(geteuid()),
                sandboxExec: access(sandboxExecPath, X_OK) == 0,
                appSandboxed: astral_exec_app_sandboxed() != 0
                    || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        }
    #endif
}
