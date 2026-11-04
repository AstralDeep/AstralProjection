// Account-scoped, non-secret persistence for the outcome-unknown summary: retained job identifiers, states,
// exit statuses and output sizes only, never output content, transcripts, canvas or tokens; AppModel reads it
// after relaunch to explain that the chat is waiting for the owner's decision about earlier computer actions.

import AstralCore
import Foundation

struct OutcomeUnknownRecordJob: Sendable, Equatable {
    let id: String
    let state: String
    let exitCode: Int?
    let signal: String?
    let outputBytes: Int
}

struct OutcomeUnknownRecord: Sendable, Equatable {
    static let schemaVersion = 1
    static let maximumJobs = 64
    let hostId: String
    let incarnationId: String
    let jobs: [OutcomeUnknownRecordJob]
}

final class OutcomeUnknownStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    static func key(scope: String) -> String {
        "astraldeep.outcome_unknown.v1." + scope
    }

    @discardableResult
    func save(_ record: OutcomeUnknownRecord, key: String) -> Bool {
        guard record.jobs.count <= OutcomeUnknownRecord.maximumJobs else { return false }
        var jobs: [[String: JSONValue]] = []
        for job in record.jobs {
            guard Self.canonicalUUID4(job.id), ComputerHostRetainedJob.states.contains(job.state),
                job.outputBytes >= 0
            else { return false }
            var entry: [String: JSONValue] = [
                "job_id": .string(job.id), "state": .string(job.state),
                "output_bytes": .number(Double(job.outputBytes)),
            ]
            if let exitCode = job.exitCode, exitCode >= 0, exitCode <= 9_007_199_254_740_991 {
                entry["exit_code"] = .number(Double(exitCode))
            }
            if let signal = job.signal { entry["signal"] = .string(signal) }
            jobs.append(entry)
        }
        let value: JSONValue = .object([
            "schema_version": .number(Double(OutcomeUnknownRecord.schemaVersion)),
            "host_id": .string(record.hostId),
            "incarnation_id": .string(record.incarnationId),
            "jobs": .array(jobs.map(JSONValue.object)),
            "updated_at": .string(Self.timestamp(now())),
        ])
        guard let data = try? value.encoded(), let encoded = String(data: data, encoding: .utf8) else {
            return false
        }
        defaults.set(encoded, forKey: key)
        return defaults.string(forKey: key) == encoded
    }

    func load(key: String) -> OutcomeUnknownRecord? {
        guard let encoded = defaults.string(forKey: key),
            let value = try? JSONValue.parse(Data(encoded.utf8)),
            let object = value.objectValue,
            object["schema_version"]?.numberValue == Double(OutcomeUnknownRecord.schemaVersion),
            let hostId = object["host_id"]?.stringValue, Self.canonicalUUID4(hostId),
            let incarnationId = object["incarnation_id"]?.stringValue, Self.canonicalUUID4(incarnationId),
            let updated = object["updated_at"]?.stringValue, Self.validTimestamp(updated),
            let jobs = object["jobs"]?.arrayValue, jobs.count <= OutcomeUnknownRecord.maximumJobs
        else { return nil }
        var parsed: [OutcomeUnknownRecordJob] = []
        for entry in jobs {
            guard let fields = entry.objectValue,
                let id = fields["job_id"]?.stringValue, Self.canonicalUUID4(id),
                let state = fields["state"]?.stringValue, ComputerHostRetainedJob.states.contains(state),
                let bytes = fields["output_bytes"]?.numberValue, Self.boundedInteger(bytes),
                Set(fields.keys).isSubset(of: ["job_id", "state", "exit_code", "signal", "output_bytes"])
            else { return nil }
            var exitCode: Int?
            if let raw = fields["exit_code"] {
                guard let number = raw.numberValue, Self.boundedInteger(number) else { return nil }
                exitCode = Int(number)
            }
            var signal: String?
            if let raw = fields["signal"] {
                guard let name = raw.stringValue else { return nil }
                signal = name
            }
            parsed.append(
                OutcomeUnknownRecordJob(
                    id: id, state: state, exitCode: exitCode, signal: signal, outputBytes: Int(bytes)))
        }
        return OutcomeUnknownRecord(hostId: hostId, incarnationId: incarnationId, jobs: parsed)
    }

    @discardableResult
    func clear(key: String) -> Bool {
        guard defaults.object(forKey: key) != nil else { return false }
        defaults.removeObject(forKey: key)
        return defaults.object(forKey: key) == nil
    }

    private static func boundedInteger(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 && value.rounded() == value
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func validTimestamp(_ value: String) -> Bool {
        value.hasSuffix("Z") && ISO8601DateFormatter().date(from: value) != nil
    }

    private static func canonicalUUID4(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression) != nil && UUID(uuidString: value) != nil
    }
}
