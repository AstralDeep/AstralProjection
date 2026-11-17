// Decides whether the system-browser sign-in can run on this OS and whether a returned URL is the connection callback.
// The Apple app's sign-in driver calls it before opening a session and again before handing a redirect to the Kernel.

import Foundation

public enum ConnectionCallback {
    public static let host = "astraldeep.github.io"
    public static let path = "/oauth/callback"
    public static let redirectURL = "https://astraldeep.github.io/oauth/callback"
    public static let tooOldCode = "connection.os_too_old"

    public enum Platform: Equatable, Sendable {
        case iOS
        case macOS
        case other
    }

    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(code: String)
    }

    public static var currentPlatform: Platform {
        #if os(iOS)
            return .iOS
        #elseif os(macOS)
            return .macOS
        #else
            return .other
        #endif
    }

    public static func availability(platform: Platform, version: OperatingSystemVersion) -> Availability {
        switch platform {
        case .iOS: return atLeast(version, major: 17, minor: 4) ? .available : .unavailable(code: tooOldCode)
        case .macOS: return atLeast(version, major: 14, minor: 4) ? .available : .unavailable(code: tooOldCode)
        case .other: return .unavailable(code: tooOldCode)
        }
    }

    public static func availabilityHere() -> Availability {
        availability(platform: currentPlatform, version: ProcessInfo.processInfo.operatingSystemVersion)
    }

    public static func matches(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && parts.host?.lowercased() == host
            && parts.port == nil
            && parts.user == nil
            && parts.password == nil
            && parts.path == path
    }

    private static func atLeast(_ version: OperatingSystemVersion, major: Int, minor: Int) -> Bool {
        if version.majorVersion != major { return version.majorVersion > major }
        return version.minorVersion >= minor
    }
}
