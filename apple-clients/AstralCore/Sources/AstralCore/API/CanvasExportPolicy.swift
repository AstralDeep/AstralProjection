import Foundation

/// A presentation is untrusted display data. It carries no dispatch authority.
public enum CanvasExportPolicy {
    public enum Failure: Error { case invalidCapture }
    public static let version = "astral.canvas-export/v1"
    public static let maximumInputBytes = 8 * 1024 * 1024
    public static let maximumOutputBytes = 32 * 1024 * 1024

    /// Resource time bounds the whole response, including peers that keep
    /// resetting the idle timeout with small chunks. Each export owns and
    /// invalidates this session; its bytes/cookies never enter a shared cache.
    static func boundedSession(like session: URLSession? = nil) -> URLSession {
        let configuration = NoStoreHTTP.configuration()
        let supplied = session?.configuration
        configuration.protocolClasses = supplied?.protocolClasses
        func bounded(_ supplied: Double?, ceiling: Double) -> Double {
            guard let supplied, supplied.isFinite, supplied > 0 else { return ceiling }
            return min(ceiling, supplied)
        }
        configuration.timeoutIntervalForRequest = bounded(supplied?.timeoutIntervalForRequest, ceiling: 15)
        configuration.timeoutIntervalForResource = bounded(supplied?.timeoutIntervalForResource, ceiling: 30)
        return URLSession(configuration: configuration)
    }

    static func validateRequest(_ data: Data) throws -> JSONValue {
        guard data.count <= maximumInputBytes,
            let value = try? JSONValue.parse(data),
            let fields = value.objectValue,
            Set(fields.keys) == Set(["version", "components", "viewport", "theme", "display_state", "images"]),
            value["version"]?.stringValue == version,
            value["components"]?.arrayValue != nil,
            value["display_state"]?.arrayValue != nil,
            value["images"]?.arrayValue != nil,
            value["viewport"]?.objectValue != nil,
            value["theme"]?.objectValue != nil
        else { throw Failure.invalidCapture }
        return value
    }

    static func validateResponse(_ data: Data, capture: JSONValue) throws {
        guard data.count <= maximumOutputBytes,
            let value = try? JSONValue.parse(data),
            let fields = value.objectValue,
            Set(fields.keys) == Set(["version", "html", "viewport", "theme"]),
            value["version"]?.stringValue == version,
            let html = value["html"]?.stringValue, !html.isEmpty,
            value["viewport"] == capture["viewport"],
            value["theme"] == capture["theme"]
        else { throw URLError(.cannotParseResponse) }
    }

    static func response(_ request: URLRequest, session: URLSession) async throws -> (Int, Data, String?) {
        let bounded = boundedSession(like: session)
        defer { bounded.invalidateAndCancel() }
        let (bytes, response) = try await bounded.bytes(for: request, delegate: WorkspaceRedirectRefusal())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= maximumOutputBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumOutputBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (http.statusCode, data, http.value(forHTTPHeaderField: "X-Astral-Render-Revision"))
    }
}
