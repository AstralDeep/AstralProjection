// Feature 051 — REST surface shared by the three Apple clients: chat list /
// detail / creation, and the 044 native sign-out (client_id attribution).
import Foundation

public struct ChatSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let updatedAt: String
    public let preview: String
    public let hasSavedComponents: Bool
    public let icon: String
    public let timeLabel: String?

    public init?(json: JSONValue) {
        guard
            let id = json["id"]?.stringValue
                ?? json["chat_id"]?.stringValue
        else { return nil }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.id = id
        self.title = json["title"]?.stringValue ?? "Untitled chat"
        self.updatedAt =
            json["updated_at"]?.stringValue
            ?? json["updated_at"]?.numberValue.map { String($0) } ?? ""
        self.preview = json["preview"]?.stringValue ?? ""
        self.hasSavedComponents = json["has_saved_components"]?.boolValue == true
        self.icon = json["icon"]?.stringValue ?? ""
        self.timeLabel = json["time"]?.stringValue
    }

    /// The server owns history enrichment and ROTE's per-device row count.
    public init?(historyItem: JSONValue) {
        guard let id = historyItem["chat_id"]?.stringValue ?? historyItem["id"]?.stringValue else { return nil }
        self.init(
            json: .object([
                "id": .string(id), "title": historyItem["title"] ?? .null,
                "preview": historyItem["preview"] ?? .null,
                "has_saved_components": historyItem["saved"] ?? .null,
                "icon": historyItem["icon"] ?? .null, "time": historyItem["time"] ?? .null,
            ]))
    }

    public var displayTitle: String {
        let value = Self.singleLine(title)
        return value.isEmpty ? "Untitled chat" : value
    }
    public var displayPreview: String { Self.singleLine(preview) }

    /// Match CSS white-space: nowrap without interpreting message markup.
    private static func singleLine(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\t\\n\\f\\r ]+", with: " ", options: .regularExpression)
    }

    /// Same display thresholds as the server's history_surface._relative_time.
    public func relativeTime(now: Date = Date()) -> String {
        if let timeLabel { return Self.singleLine(timeLabel) }
        guard let timestamp = Double(updatedAt), timestamp.isFinite else { return "" }
        let seconds = timestamp >= 1e11 ? timestamp / 1000 : timestamp
        let age = max(0, now.timeIntervalSince1970 - seconds)
        guard age.isFinite else { return "" }
        if age < 45 { return "just now" }
        for (ceiling, unit, suffix) in [
            (3600.0, 60.0, "m"), (86400, 3600, "h"), (604800, 86400, "d"),
            (2_629_800, 604800, "w"), (31_557_600, 2_629_800, "mo"),
        ] where age < ceiling {
            return "\(Int(age / unit))\(suffix)"
        }
        let years = age / 31_557_600
        guard years < Double(Int.max) else { return "" }
        return "\(Int(years))y"
    }
}

/// Payload-free retained operation projection returned by the authenticated
/// feature-060 reconciliation endpoint. Credentials and submitted fields are
/// deliberately absent from this type.
public struct OperationProjection: Sendable, Equatable {
    public let operationId: String
    public let operationKind: String
    public let requestGeneration: String?
    public let state: String
    public let phaseCode: String?
    public let terminalCode: String?
    public let safeSummary: String?
    public let retryAfterMs: UInt64?
    public let stateRevision: UInt64

    public init?(json: JSONValue) {
        guard let operationId = Self.uuid(json["operation_id"]),
            let operationKind = json["operation_kind"]?.stringValue,
            let state = json["state"]?.stringValue,
            ["queued", "running", "completed", "failed", "cancelled", "retryable"]
                .contains(state),
            let stateRevision = Self.unsigned(json["state_revision"])
        else { return nil }
        let requestGeneration: String?
        if json["request_generation"] == .null {
            requestGeneration = nil
        } else {
            guard let value = Self.uuid(json["request_generation"]) else { return nil }
            requestGeneration = value
        }
        let retryAfterMs: UInt64?
        if json["retry_after_ms"] == .null {
            retryAfterMs = nil
        } else {
            guard state == "retryable", let value = Self.unsigned(json["retry_after_ms"])
            else { return nil }
            retryAfterMs = value
        }
        self.operationId = operationId
        self.operationKind = operationKind
        self.requestGeneration = requestGeneration
        self.state = state
        self.phaseCode = json["phase_code"]?.stringValue
        self.terminalCode = json["terminal_code"]?.stringValue
        self.safeSummary = json["safe_summary"]?.stringValue
        self.retryAfterMs = retryAfterMs
        self.stateRevision = stateRevision
    }

    private static func uuid(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue,
            let parsed = UUID(uuidString: text),
            parsed.uuidString.lowercased() == text
        else { return nil }
        return text
    }

    private static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.numberValue, number.isFinite, number >= 0,
            number.rounded() == number, number <= 9_007_199_254_740_991
        else { return nil }
        return UInt64(number)
    }
}

/// The immutable retained result of one owner-scoped submission identity.
public enum OperationSubmissionProjection: Sendable, Equatable {
    case accepted(OperationProjection)
    case refused(code: String, retryable: Bool, retryAfterMs: UInt64?)

    public init?(json: JSONValue) {
        guard let accepted = json["accepted"]?.boolValue else { return nil }
        if accepted {
            guard let operation = json["operation"].flatMap(OperationProjection.init(json:))
            else { return nil }
            self = .accepted(operation)
            return
        }
        guard let code = json["code"]?.stringValue,
            let retryable = json["retryable"]?.boolValue
        else { return nil }
        let retryAfterMs: UInt64?
        if json["retry_after_ms"] == .null {
            retryAfterMs = nil
        } else {
            guard retryable, let number = json["retry_after_ms"]?.numberValue,
                number.isFinite, number >= 0, number.rounded() == number,
                number <= 9_007_199_254_740_991
            else { return nil }
            retryAfterMs = UInt64(number)
        }
        self = .refused(code: code, retryable: retryable, retryAfterMs: retryAfterMs)
    }
}

public struct RestClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)
    public typealias PresentationTransport = @Sendable (URLRequest) async throws -> (Int, Data, String?)

    public let serverBase: URL
    private let transport: Transport
    private let workspaceTransport: Transport
    private let presentationTransport: PresentationTransport
    private let downloadSession: URLSession?
    private let tokenProvider: @Sendable () async -> String?

    public init(
        serverBase: URL,
        tokenProvider: @escaping @Sendable () async -> String?,
        transport: Transport? = nil,
        downloadSession: URLSession? = nil,
        presentationTransport: PresentationTransport? = nil
    ) {
        self.serverBase = serverBase
        self.tokenProvider = tokenProvider
        self.downloadSession = downloadSession
        self.transport =
            transport ?? { request in
                let (data, response) = try await NoStoreHTTP.session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            }
        self.workspaceTransport =
            transport ?? { request in
                try await WorkspaceRequestPolicy.response(
                    request, session: downloadSession ?? NoStoreHTTP.session)
            }
        self.presentationTransport =
            presentationTransport ?? { request in
                try await CanvasExportPolicy.response(request, session: downloadSession ?? NoStoreHTTP.session)
            }
    }

    /// Independently authorized display-only rendering after the ordinary
    /// export GET. Never retries; the caller retains its captured owner fence.
    public func canvasPresentation(chatId: String, renderRevision: UInt64, capture: Data) async throws -> Data {
        let source = try CanvasExportPolicy.validateRequest(capture)
        guard !chatId.isEmpty, chatId.utf8.count <= 256,
            let segment = chatId.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))),
            var parts = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        parts.percentEncodedPath = "/api/export/canvas/\(segment)/presentation"
        parts.queryItems = [URLQueryItem(name: "render_revision", value: String(renderRevision))]
        parts.fragment = nil
        guard let url = parts.url, DownloadPolicy.sameOrigin(url, serverBase),
            (try? DownloadPolicy.resolve(url.absoluteString, relativeTo: serverBase)) == url
        else { throw URLError(.badURL) }
        try Task.checkCancellation()
        guard let token = await tokenProvider(), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        try Task.checkCancellation()
        var request = NoStoreHTTP.request(url: url, method: "POST", body: capture, contentType: "application/json")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, data, revision) = try await presentationTransport(request)
        try Task.checkCancellation()
        guard status == 200, revision == String(renderRevision) else { throw URLError(.badServerResponse) }
        try CanvasExportPolicy.validateResponse(data, capture: source)
        return data
    }

    /// ws(s):// twin of the server base for the orchestrator socket.
    public var webSocketURL: URL {
        var comps = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        return comps.url!
    }

    func request(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> (Int, JSONValue) {
        var request = NoStoreHTTP.request(
            url: serverBase.appendingPathComponent(path),
            method: method,
            body: try body?.encoded(),
            contentType: body == nil ? nil : "application/json")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (status, data) = try await transport(request)
        return (status, (try? JSONValue.parse(data)) ?? .object([:]))
    }

    public func chats() async throws -> [ChatSummary] {
        let (status, json) = try await request("GET", "api/chats")
        guard status == 200 else { return [] }
        let items = json["chats"]?.arrayValue ?? json.arrayValue ?? []
        return items.compactMap { ChatSummary(json: $0) }
    }

    /// One explicit mint attempt using the existing owner/PHI-gated route.
    /// The result stays ephemeral; callers must recheck their initiating owner
    /// before displaying it. An uncertain POST is never retried here.
    public func shareCanvas(chatId: String) async throws -> URL {
        guard !chatId.isEmpty, chatId.utf8.count <= 256,
            let token = await tokenProvider(), !token.isEmpty
        else { throw URLError(.userAuthenticationRequired) }
        try Task.checkCancellation()
        let endpoint = try DownloadPolicy.resolve("/api/share", relativeTo: serverBase)
        guard DownloadPolicy.sameOrigin(endpoint, serverBase) else { throw URLError(.badURL) }
        var request = NoStoreHTTP.request(
            url: endpoint, method: "POST",
            body: try JSONValue.object(["chat_id": .string(chatId), "scope": .string("canvas")]).encoded(),
            contentType: "application/json")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, data) = try await workspaceTransport(request)
        try Task.checkCancellation()
        guard data.count <= WorkspaceRequestPolicy.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard status == 201 else {
            if status == 403, (try? JSONValue.parse(data))?["error"]?.stringValue == "phi_blocked" {
                throw WorkspaceShareError.phiBlocked
            }
            throw WorkspaceShareError.refused(status: status)
        }
        let body = try JSONValue.parse(data)
        guard let raw = body["share_url"]?.stringValue else { throw URLError(.cannotParseResponse) }
        return try WorkspaceRequestPolicy.shareURL(raw, relativeTo: serverBase)
    }

    public func deleteChat(id: String) async throws -> Bool {
        let (status, _) = try await request("DELETE", "api/chats/\(id)")
        return (200...299).contains(status)
    }

    /// Reconcile one retained user-owned accepted operation. A non-disclosing
    /// 404 returns nil; transport and malformed-success responses throw.
    public func operation(id: String) async throws -> OperationProjection? {
        let (status, json) = try await request("GET", "api/operations/\(id)")
        if status == 404 { return nil }
        guard status == 200, let operation = OperationProjection(json: json) else {
            throw URLError(.cannotParseResponse)
        }
        return operation
    }

    /// Resolve acceptance/refusal by the original client submission UUID when
    /// the socket closed before an operation ID reached the client.
    public func operationSubmission(id: String) async throws -> OperationSubmissionProjection? {
        let (status, json) = try await request("GET", "api/operation-submissions/\(id)")
        if status == 404 { return nil }
        guard status == 200, let result = OperationSubmissionProjection(json: json) else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }

    /// 044 native sign-out: server-side revocation attributed to this client.
    public func logout(clientId: String, refreshToken: String) async throws -> Bool {
        let (status, json) = try await request(
            "POST", "api/auth/logout",
            body: .object([
                "client_id": .string(clientId),
                "refresh_token": .string(refreshToken),
            ]))
        let ok = json["revoked"]?.boolValue == true || json["queued"]?.boolValue == true
        return status == 200 && ok
    }

    /// The per-user, hash-chained audit log (`GET /api/audit`).
    public func audit() async -> [AuditEvent] {
        var req = NoStoreHTTP.request(url: serverBase.appendingPathComponent("api/audit"))
        if let token = await tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await NoStoreHTTP.session.data(for: req),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return AuditEvent.parse(data)
    }

    /// Upload one file (`POST /api/upload`, multipart `file` field) — the exact
    /// web/Android contract. Returns the attachment metadata or nil on failure.
    public func uploadAttachment(
        filename: String, mimeType: String?,
        data fileData: Data
    ) async -> AttachmentUpload? {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = NoStoreHTTP.request(
            url: serverBase.appendingPathComponent("api/upload"),
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)")
        if let token = await tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var body = Data()
        let mime = mimeType ?? "application/octet-stream"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        guard let (respData, response) = try? await NoStoreHTTP.session.data(for: req),
            (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
            let json = try? JSONValue.parse(respData),
            let id = json["attachment_id"]?.stringValue
        else { return nil }
        return AttachmentUpload(
            attachmentId: id,
            filename: json["filename"]?.stringValue ?? filename,
            category: json["category"]?.stringValue ?? "file",
            parserStatus: json["parser_status"]?.stringValue)
    }

    /// Download a server file with Bearer auth — the native twin of the web's
    /// cookie-carrying anchor click on `file_download` components. Handles the
    /// root-relative `/api/download/{session}/{filename}` URLs agents emit by
    /// resolving them against `serverBase`; absolute OFF-origin URLs (e.g. a
    /// `download_card`'s GitHub release asset) are fetched WITHOUT the token —
    /// credentials never leave our origin. Returns a temporary file URL whose
    /// last path component is the intended filename (for share/save UIs).
    public func downloadFile(
        from urlString: String,
        suggestedFilename: String? = nil,
        expectedRenderRevision: UInt64? = nil
    ) async throws -> URL {
        let req = try await downloadRequest(from: urlString)
        if expectedRenderRevision != nil {
            guard let url = req.url, DownloadPolicy.sameOrigin(url, serverBase) else {
                throw URLError(.badURL)
            }
            guard req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else {
                throw URLError(.userAuthenticationRequired)
            }
        }
        try Task.checkCancellation()
        let bounded = expectedRenderRevision == nil ? nil : CanvasExportPolicy.boundedSession(like: downloadSession)
        defer { bounded?.invalidateAndCancel() }
        let (bytes, response) = try await (bounded ?? downloadSession ?? NoStoreHTTP.session).bytes(
            for: req, delegate: DownloadRedirectDelegate(original: req))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let expectedRenderRevision,
            http.value(forHTTPHeaderField: "X-Astral-Render-Revision") != String(expectedRenderRevision)
        {
            throw URLError(.badServerResponse)
        }
        let limit = 64 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        try Task.checkCancellation()
        let name = DownloadPolicy.filename(
            suggestedFilename ?? http.suggestedFilename ?? req.url?.lastPathComponent ?? "download")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astral-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = dir.appendingPathComponent(name)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: dir) } }
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                try Task.checkCancellation()
                try file.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty { try file.write(contentsOf: chunk) }
        complete = true
        return destination
    }

    /// Removes only private temporary files produced by this download facade.
    public static func removeTemporaryDownload(_ file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astral-downloads", isDirectory: true)
            .standardizedFileURL
        let directory = file.standardizedFileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == root, UUID(uuidString: directory.lastPathComponent) != nil else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Testable request construction; fetching and redirects reuse this exact
    /// request, so URL policy cannot diverge from the authorization decision.
    func downloadRequest(from urlString: String) async throws -> URLRequest {
        let url = try DownloadPolicy.resolve(urlString, relativeTo: serverBase)
        var request = NoStoreHTTP.request(url: url)
        if DownloadPolicy.sameOrigin(url, serverBase), let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Toggle one tool's permission (feature-013 per-(tool,kind) shape):
    /// `PUT /api/agents/{id}/permissions {per_tool_permissions:{tool:{kind:enabled}}}`.
    @discardableResult
    public func setToolPermission(
        agentId: String, tool: String, kind: String,
        enabled: Bool
    ) async -> Bool {
        let body = JSONValue.object([
            "per_tool_permissions": .object([tool: .object([kind: .bool(enabled)])])
        ])
        let result = try? await request("PUT", "api/agents/\(agentId)/permissions", body: body)
        return (200...299).contains(result?.0 ?? 0)
    }
}

/// Metadata returned by `POST /api/upload` for a staged attachment (feature 031).
public struct AttachmentUpload: Sendable {
    public let attachmentId: String
    public let filename: String
    public let category: String
    /// covered | preparing | pending_admin_approval | unavailable
    public let parserStatus: String?
}
