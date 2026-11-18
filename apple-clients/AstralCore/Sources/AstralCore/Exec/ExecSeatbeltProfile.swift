// Renders the canonical macOS Seatbelt profile for an execution policy, line for line as the policy contract fixes it.
// ExecLauncher writes the text to a private file for sandbox-exec, and the committed profile vectors pin every byte.

import Foundation

public struct ExecSeatbeltContext: Sendable, Equatable {
    public let home: String
    public let proxyPort: UInt16?

    public init(home: String, proxyPort: UInt16?) {
        self.home = home
        self.proxyPort = proxyPort
    }
}

public enum ExecSeatbeltProfile {
    static let execBase = ["/usr", "/System", "/Library", "/private/var/db/dyld"]
    static let execOnly = ["/bin", "/sbin"]
    static let keychains = ["/Library/Keychains", "/System/Library/Keychains"]
    static let deniedServices = [
        "com.apple.trustd", "com.apple.trustd.agent", "com.apple.system.notification_center", "com.apple.analyticsd",
        "com.apple.analyticsd.messagetracer", "com.apple.diagnosticd", "com.apple.osanalytics.osanalyticshelper",
    ]
    static let deniedLoggers = ["com.apple.logd", "com.apple.logd.events", "com.apple.system.logger"]
    static let dnssdService = "com.apple.dnssd.service"
    static let syslogSocket = "/private/var/run/syslog"

    public static func render(_ policy: ExecPolicy, context: ExecSeatbeltContext) throws -> String {
        let checked = try ExecPolicy(json: policy.canonicalData, platform: "darwin")
        if ExecPolicy.pathProblem(context.home) != nil {
            throw ExecContextError("home must be an absolute normalized path")
        }
        if ExecPolicy.hasUnassigned(context.home) { throw ExecContextError("home holds an unassigned code point") }
        if !checked.hosts.isEmpty && (context.proxyPort ?? 0) == 0 {
            throw ExecContextError("a policy with hosts needs a proxy port from 1 to 65535")
        }
        let quote = SeatbeltQuoting.quote
        let workspace = quote(checked.workspace)
        var lines = ["(version 1)", "(deny default)", "(import \"system.sb\")", ""]
        lines += (execBase + checked.reads + execOnly).map { "(allow process-exec* (subpath \(quote($0))))" }
        if checked.limits.processes > 1 { lines.append("(allow process-fork)") }
        lines += [
            "(allow process-info* (target self))",
            "(allow signal (target self))",
            "(allow signal (target children))",
            "(allow sysctl-read)",
            "(allow file-ioctl)",
            "",
        ]
        lines += ExecBackends.darwinBase.map { "(allow file-read* (subpath \(quote($0))))" }
        lines.append("(allow file-read-metadata \(execOnly.map { "(subpath \(quote($0)))" }.joined(separator: " ")))")
        lines += checked.reads.map { "(allow file-read* (subpath \(quote($0))))" }
        lines += ["(allow file-read* file-write* (subpath \(workspace)))", ""]
        let services = deniedServices.map { "(global-name \"\($0)\")" }.joined(separator: " ")
        let loggers = deniedLoggers.map { "(global-name \"\($0)\")" }.joined(separator: " ")
        lines += [
            "(deny process-exec* (subpath \(workspace)))",
            "(deny file-map-executable (subpath \(workspace)))",
            "(deny mach-lookup (global-name \"\(dnssdService)\"))",
            "(deny mach-lookup \(services) (xpc-service-name-prefix \"\"))",
            "(deny mach-lookup \(loggers))",
            "(deny network-outbound (literal \(quote(syslogSocket))))",
        ]
        lines += ([context.home + "/Library/Keychains"] + keychains).map { "(deny file-read* (subpath \(quote($0))))" }
        if !checked.hosts.isEmpty, let port = context.proxyPort {
            lines += ["", "(allow network-outbound (remote ip \"localhost:\(port)\"))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum SeatbeltQuoting {
    static func quote(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { out.append("\\") }
            out.append(scalar)
        }
        out.append("\"")
        return String(out)
    }
}
