// The execution policy model: strict parsing and validation in the contract's order, the canonical digest and, on macOS, the loader that checks on-disk spellings.
// ExecBackends, ExecSeatbeltProfile and ExecLauncher take their input from here, and the committed policy vectors pin every outcome.

import CryptoKit
import Foundation

public struct ExecPolicyError: Error, Equatable, Sendable {
    public let code: String
    public let detail: String

    init(_ code: String, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

public struct ExecContextError: Error, Equatable, Sendable {
    public let message: String

    init(_ message: String) { self.message = message }
}

public struct ExecPolicy: Sendable {
    public struct Host: Sendable {
        public let host: String
        public let port: Int
    }

    public struct Limits: Sendable {
        public let memoryBytes: Int
        public let processes: Int
        public let openFiles: Int
        public let fileBytes: Int
    }

    public static let format = "astral.exec-policy/v1"
    static let maxReads = 64
    static let maxHosts = 64
    static let maxPathBytes = 4096
    static let hostPorts = [80, 443]
    static let limitRanges: [(name: String, low: Int64, high: Int64)] = [
        ("memory_bytes", 16_777_216, 68_719_476_736),
        ("processes", 1, 4096),
        ("open_files", 16, 65536),
        ("file_bytes", 4096, 1_099_511_627_776),
    ]
    static let wallRange: (low: Int64, high: Int64) = (1, 86_400_000)
    static let topFields = ["v", "reads", "workspace", "hosts", "limits", "time"]

    public let reads: [String]
    public let workspace: String
    public let hosts: [Host]
    public let limits: Limits
    public let wallMs: Int
    public let canonicalData: Data

    public init(json data: Data, platform: String?) throws {
        let tree: ExecJSON
        do {
            tree = try ExecJSON.parse(data)
        } catch let error as ExecJSONError {
            throw ExecPolicyError("policy.malformed", error.detail)
        }
        try self.init(document: tree, platform: platform)
    }

    public init(document: ExecJSON, platform: String?) throws {
        try Self.requireObject(document, Self.topFields, "policy")
        guard document["v"]?.intValue == 1 else { throw ExecPolicyError("policy.malformed", "v must be 1") }
        let reads = try Self.validatedReads(document["reads"], platform)
        let workspace = try Self.validatedWorkspace(document["workspace"], reads: reads, platform)
        let hosts = try Self.validatedHosts(document["hosts"])
        let limits = try Self.validatedLimits(document["limits"])
        let wall = try Self.validatedWall(document["time"])
        self.reads = reads
        self.workspace = workspace
        self.hosts = hosts
        self.limits = limits
        self.wallMs = wall
        do {
            self.canonicalData = try document.canonicalData()
        } catch {
            throw ExecPolicyError("policy.malformed", "not canonical")
        }
    }

    public var digest: String {
        "sha256:" + SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireObject(_ value: ExecJSON?, _ fields: [String], _ place: String) throws {
        guard case .object(let members)? = value else {
            throw ExecPolicyError("policy.malformed", "\(place) must be an object")
        }
        if members.contains(where: { member in !fields.contains { $0.utf8.elementsEqual(member.key.utf8) } }) {
            throw ExecPolicyError("policy.unknown_field", place)
        }
        if fields.contains(where: { field in !members.contains { $0.key.utf8.elementsEqual(field.utf8) } }) {
            throw ExecPolicyError("policy.malformed", "\(place) is missing a field")
        }
    }

    static func pathProblem(_ path: String) -> String? {
        let bytes = Array(path.utf8)
        if bytes.count > maxPathBytes { return "too long" }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "control character" }
        if bytes.first != 0x2F { return "must be absolute" }
        for part in bytes.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false) {
            if part.isEmpty || part.elementsEqual([0x2E]) || part.elementsEqual([0x2E, 0x2E]) {
                return "not normalized"
            }
        }
        return nil
    }

    static func hasUnassigned(_ value: String) -> Bool {
        !value.unicodeScalars.allSatisfy(ExecPathFold.isAssigned)
    }

    private static func checkedPath(_ value: ExecJSON?, _ place: String, _ platform: String?) throws -> String {
        guard case .string(let path)? = value else {
            throw ExecPolicyError("policy.malformed", "\(place) must be a string")
        }
        var problem = pathProblem(path)
        if problem == nil, platform == "darwin", hasUnassigned(path) { problem = "unassigned code point" }
        if let problem { throw ExecPolicyError("policy.path_invalid", "\(place): \(problem)") }
        return path
    }

    private static func validatedReads(_ value: ExecJSON?, _ platform: String?) throws -> [String] {
        guard case .array(let entries)? = value else {
            throw ExecPolicyError("policy.malformed", "reads must be a list")
        }
        if entries.count > maxReads { throw ExecPolicyError("policy.too_many_entries", "reads") }
        var previous: String?
        var seen = Set<[UInt32]>()
        var reads = [String]()
        for (index, entry) in entries.enumerated() {
            let path = try checkedPath(entry, "reads[\(index)]", platform)
            if let previous, !previous.utf8.lexicographicallyPrecedes(path.utf8) {
                throw ExecPolicyError("policy.path_invalid", "reads[\(index)] not sorted and unique")
            }
            guard seen.insert(ExecPathFold.folded(path, platform: platform)).inserted else {
                throw ExecPolicyError("policy.path_invalid", "reads[\(index)] repeats a read root")
            }
            previous = path
            reads.append(path)
        }
        return reads
    }

    private static func validatedWorkspace(_ value: ExecJSON?, reads: [String], _ platform: String?) throws -> String {
        let workspace = try checkedPath(value, "workspace", platform)
        for path in reads
        where ExecPathFold.contains(workspace, path, platform: platform)
            || ExecPathFold.contains(path, workspace, platform: platform)
        {
            throw ExecPolicyError("policy.path_invalid", "a read root overlaps the workspace")
        }
        return workspace
    }

    private static func isHostLabel(_ label: ArraySlice<UInt8>) -> Bool {
        guard (1...63).contains(label.count) else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte) }
        guard alphanumeric(label.first ?? 0), alphanumeric(label.last ?? 0) else { return false }
        return label.allSatisfy { alphanumeric($0) || $0 == 0x2D }
    }

    private static func isNumericLabel(_ label: ArraySlice<UInt8>) -> Bool {
        if !label.isEmpty, label.allSatisfy({ (0x30...0x39).contains($0) }) { return true }
        guard label.starts(with: [0x30, 0x78]) else { return false }
        return label.dropFirst(2).allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func validatedHosts(_ value: ExecJSON?) throws -> [Host] {
        guard case .array(let entries)? = value else {
            throw ExecPolicyError("policy.malformed", "hosts must be a list")
        }
        if entries.count > maxHosts { throw ExecPolicyError("policy.too_many_entries", "hosts") }
        var hosts = [Host]()
        for (index, entry) in entries.enumerated() {
            let place = "hosts[\(index)]"
            try requireObject(entry, ["host", "port"], place)
            guard case .string(let name)? = entry["host"], case .int(let port)? = entry["port"] else {
                throw ExecPolicyError("policy.malformed", "\(place) has a wrong type")
            }
            let bytes = Array(name.utf8)
            let labels = bytes.split(separator: 0x2E, omittingEmptySubsequences: false)
            if name.unicodeScalars.count > 253 || labels.count < 2 || !labels.allSatisfy(isHostLabel)
                || isNumericLabel(labels[labels.count - 1])
            {
                throw ExecPolicyError("policy.host_invalid", "\(place).host")
            }
            guard hostPorts.contains(Int(port)) else { throw ExecPolicyError("policy.host_invalid", "\(place).port") }
            if let last = hosts.last {
                let ordered =
                    last.host.utf8.lexicographicallyPrecedes(name.utf8)
                    || (last.host.utf8.elementsEqual(name.utf8) && last.port < Int(port))
                if !ordered { throw ExecPolicyError("policy.host_invalid", "\(place) not sorted and unique") }
            }
            hosts.append(Host(host: name, port: Int(port)))
        }
        return hosts
    }

    private static func validatedLimits(_ value: ExecJSON?) throws -> Limits {
        try requireObject(value, limitRanges.map(\.name), "limits")
        var numbers = [Int]()
        for range in limitRanges {
            guard case .int(let number)? = value?[range.name] else {
                throw ExecPolicyError("policy.malformed", "limits.\(range.name) must be an integer")
            }
            if !(range.low...range.high).contains(number) {
                throw ExecPolicyError("policy.limit_out_of_range", range.name)
            }
            numbers.append(Int(number))
        }
        return Limits(memoryBytes: numbers[0], processes: numbers[1], openFiles: numbers[2], fileBytes: numbers[3])
    }

    private static func validatedWall(_ value: ExecJSON?) throws -> Int {
        try requireObject(value, ["wall_ms"], "time")
        guard case .int(let wall)? = value?["wall_ms"] else {
            throw ExecPolicyError("policy.malformed", "time.wall_ms must be an integer")
        }
        if !(wallRange.low...wallRange.high).contains(wall) {
            throw ExecPolicyError("policy.time_out_of_range", "wall_ms")
        }
        return Int(wall)
    }
}

extension ExecPolicy: Equatable {
    public static func == (lhs: ExecPolicy, rhs: ExecPolicy) -> Bool { lhs.canonicalData == rhs.canonicalData }
}

public struct ExecLoadedPolicy: Sendable, Equatable {
    public let policy: ExecPolicy
    public let platform: String
    public let dataDirectory: String
    public let home: String
}

#if os(macOS)
    extension ExecPolicy {
        static func canonicalPath(_ path: String) throws -> String {
            let descriptor = open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return String(cString: buffer)
        }

        static func checkedContextPath(_ value: String, _ name: String, _ resolve: (String) throws -> String) throws
            -> String
        {
            if pathProblem(value) != nil { throw ExecContextError("\(name) must be an absolute normalized path") }
            if hasUnassigned(value) { throw ExecContextError("\(name) holds an unassigned code point") }
            let resolved: String
            do {
                resolved = try resolve(value)
            } catch {
                throw ExecContextError("\(name) cannot be resolved: \(error)")
            }
            guard resolved.utf8.elementsEqual(value.utf8) else {
                throw ExecContextError("\(name) is not the canonical path")
            }
            return value
        }

        static func identities(_ path: String) -> [[UInt64]] {
            let parts = path.utf8.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false)
            var chain = [[UInt64]]()
            for end in 0...parts.count {
                let prefix = "/" + parts[0..<end].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
                var info = stat()
                if stat(prefix, &info) != 0 {
                    if end == parts.count { return [] }
                    continue
                }
                chain.append([UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)])
            }
            return chain
        }

        static func aliasesDataDirectory(_ policy: ExecPolicy, dataDirectory: String) -> Bool {
            let dataChain = identities(dataDirectory)
            guard let dataIdentity = dataChain.last else { return false }
            for root in ExecBackends.darwinBase + policy.reads {
                let chain = identities(root)
                if let last = chain.last, chain.contains(dataIdentity) || dataChain.contains(last) { return true }
            }
            let chain = identities(policy.workspace)
            guard let workspaceIdentity = chain.last else { return false }
            if dataChain.contains(workspaceIdentity) { return true }
            guard let lastData = chain.lastIndex(of: dataIdentity) else { return false }
            let execChain = identities(dataDirectory + "/" + ExecBackends.execSubdirectory)
            if execChain.count <= dataChain.count { return true }
            let below = lastData + 1
            return !(below < chain.count - 1 && chain[below] == execChain[execChain.count - 1])
        }

        public static func load(json: Data, dataDirectory: String, home: String) throws -> ExecLoadedPolicy {
            let platform = "darwin"
            let policy = try ExecPolicy(json: json, platform: platform)
            let named =
                policy.reads.enumerated().map { ("reads[\($0.offset)]", $0.element) } + [
                    ("workspace", policy.workspace)
                ]
            for (place, path) in named {
                let resolved: String
                do {
                    resolved = try canonicalPath(path)
                } catch {
                    throw ExecPolicyError("policy.path_invalid", "\(place): cannot resolve (\(error))")
                }
                guard resolved.utf8.elementsEqual(path.utf8) else {
                    throw ExecPolicyError("policy.path_invalid", "\(place): not the canonical path")
                }
            }
            let checkedDirectory = try checkedContextPath(dataDirectory, "data_dir", canonicalPath)
            let checkedHome = try checkedContextPath(home, "home", canonicalPath)
            if aliasesDataDirectory(policy, dataDirectory: checkedDirectory) {
                throw ExecRefused(ExecBackends.refusal(code: "exec.policy_overlaps_data"))
            }
            return ExecLoadedPolicy(
                policy: policy, platform: platform, dataDirectory: checkedDirectory, home: checkedHome)
        }
    }
#endif
