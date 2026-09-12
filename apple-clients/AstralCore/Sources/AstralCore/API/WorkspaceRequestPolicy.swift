import Foundation

public enum WorkspaceShareError: Error, Equatable, Sendable {
    case refused(status: Int)
    case phiBlocked
}

/// The share response contains a capability URL: keep it bounded and ephemeral,
/// refuse redirects, and never accept a link to another origin or route.
enum WorkspaceRequestPolicy {
    static let maximumResponseBytes = 16 * 1024

    static func shareURL(_ raw: String, relativeTo base: URL) throws -> URL {
        guard raw.utf8.count <= 2048, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = try? DownloadPolicy.resolve(raw, relativeTo: base),
            DownloadPolicy.sameOrigin(url, base),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.query == nil, components.fragment == nil,
            components.percentEncodedPath.hasPrefix("/share/")
        else { throw URLError(.badServerResponse) }
        let token = components.percentEncodedPath.dropFirst("/share/".count)
        guard !token.isEmpty, token.utf8.count <= 256,
            token.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 95
            })
        else { throw URLError(.badServerResponse) }
        return url
    }

    static func response(_ request: URLRequest, session: URLSession) async throws -> (Int, Data) {
        let (bytes, response) = try await session.bytes(for: request, delegate: WorkspaceRedirectRefusal())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (http.statusCode, data)
    }
}

/// A minting POST must never be redirected or replayed at a new endpoint.
final class WorkspaceRedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
