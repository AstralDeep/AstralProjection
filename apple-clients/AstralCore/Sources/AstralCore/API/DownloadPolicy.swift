// Credential and origin policy for file downloads: authorization requires an exact scheme/host/port match,
// and a per-task redirect delegate stops a bearer token from following an automatic cross-origin redirect.
// Backs Rest.swift's downloadFile.

import Foundation

enum DownloadPolicy {
    static func resolve(_ raw: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host?.isEmpty == false, url.user == nil, url.password == nil,
            !(base.scheme?.lowercased() == "https" && scheme != "https")
        else { throw URLError(.badURL) }
        return url
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }

    static func redirect(_ proposed: URLRequest, from original: URLRequest) -> URLRequest? {
        guard let source = original.url, let target = proposed.url,
            (try? resolve(source.absoluteString, relativeTo: source)) != nil,
            let url = try? resolve(target.absoluteString, relativeTo: source)
        else { return nil }
        let authorization = original.value(forHTTPHeaderField: "Authorization")
        // Credentialed requests never follow a cross-origin redirect
        if authorization != nil, !sameOrigin(source, url) { return nil }
        var request = NoStoreHTTP.request(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    static func filename(_ proposed: String) -> String {
        let finalSegment =
            proposed.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let clean = String(
            finalSegment.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && $0 != ":"
            }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "download" }
        return String(clean.prefix(180))
    }
}

final class DownloadRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let original: URLRequest

    init(original: URLRequest) { self.original = original }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(DownloadPolicy.redirect(request, from: original))
    }
}
