// Decodes owner-scoped scheduled jobs returned by the server's schedule API for native clients.
// The server remains the authority for schedule validity, execution policy, and job controls.

import Foundation

public struct ScheduledWorkJob: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let instruction: String
    public let status: String
    public let scheduleKind: String
    public let scheduleExpression: String
    public let timezone: String
    public let consentedScopes: [String]
    public let nextRunAtMillis: Int64?
    public let lastRunAtMillis: Int64?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let uuid = UUID(uuidString: id),
            uuid.uuidString.lowercased() == id,
            let name = json["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 120,
            let instruction = json["instruction"]?.stringValue, !instruction.isEmpty,
            instruction.utf8.count <= 4000,
            let status = json["status"]?.stringValue,
            ["active", "paused", "expired", "completed", "disabled"].contains(status),
            let kind = json["schedule_kind"]?.stringValue, ["one_shot", "interval", "cron"].contains(kind),
            let expression = json["schedule_expr"]?.stringValue, !expression.isEmpty,
            expression.utf8.count <= 256,
            let timezone = json["timezone"]?.stringValue, !timezone.isEmpty, timezone.utf8.count <= 128,
            let scopes = json["consented_scopes"]?.arrayValue, scopes.count <= 64,
            scopes.allSatisfy({ (1...64).contains($0.stringValue?.utf8.count ?? 0) })
        else { return nil }
        guard let next = Self.millis(json["next_run_at"]),
            let last = Self.millis(json["last_run_at"])
        else { return nil }
        self.id = id
        self.name = name
        self.instruction = instruction
        self.status = status
        self.scheduleKind = kind
        self.scheduleExpression = expression
        self.timezone = timezone
        consentedScopes = scopes.compactMap(\.stringValue)
        nextRunAtMillis = next
        lastRunAtMillis = last
    }

    public var canPause: Bool { status == "active" }
    public var canResume: Bool { status == "paused" }
    public var canRunNow: Bool { status == "active" }

    private static func millis(_ value: JSONValue?) -> Int64?? {
        if value == nil || value == .null { return .some(nil) }
        guard let number = value?.numberValue, number.isFinite, number.rounded() == number,
            number >= 0, number <= 9_007_199_254_740_991
        else { return nil }
        return .some(Int64(number))
    }
}

public enum ScheduledWorkAction: Equatable, Sendable {
    case pause
    case resume
    case runNow(submissionId: UUID)

    var suffix: String {
        switch self {
        case .pause: "pause"
        case .resume: "resume"
        case .runNow: "run-now"
        }
    }

    var body: JSONValue? {
        switch self {
        case .pause, .resume: nil
        case .runNow(let id): .object(["submission_id": .string(id.uuidString.lowercased())])
        }
    }
}

extension RestClient {
    public func scheduledWorkJobs() async throws -> [ScheduledWorkJob] {
        let (status, json) = try await authenticatedRequest("GET", "api/schedule")
        guard status == 200, let raw = json["jobs"]?.arrayValue, raw.count <= 1000 else {
            throw URLError(.badServerResponse)
        }
        let jobs = raw.compactMap(ScheduledWorkJob.init(json:))
        guard jobs.count == raw.count, Set(jobs.map(\.id)).count == jobs.count else {
            throw URLError(.cannotParseResponse)
        }
        return jobs
    }

    public func scheduledWorkAction(id: String, action: ScheduledWorkAction) async throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw URLError(.badURL)
        }
        let (status, json) = try await authenticatedRequest(
            "POST", "api/schedule/\(id)/\(action.suffix)", body: action.body)
        guard json["job_id"]?.stringValue == id else { throw URLError(.cannotParseResponse) }
        switch action {
        case .pause:
            guard status == 200, json["status"]?.stringValue == "paused" else {
                throw URLError(.badServerResponse)
            }
        case .resume:
            guard status == 200, json["status"]?.stringValue == "active" else {
                throw URLError(.badServerResponse)
            }
        case .runNow(let submissionId):
            guard status == 202,
                json["submission_id"]?.stringValue == submissionId.uuidString.lowercased(),
                json["occurrence_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil,
                json["duplicate"]?.boolValue != nil
            else { throw URLError(.badServerResponse) }
        }
    }
}
