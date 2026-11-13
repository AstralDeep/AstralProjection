// The read-only, permission-free tools this device offers the kernel: the current date and time and the device locale.
// A call for any other name or with any arguments is refused rather than ignored, so a stale ticket cannot reach a missing tool.

import Foundation

nonisolated struct DeviceLocalTools: MeshLocalTools {
    static let currentDateTime = "current_datetime"
    static let deviceLocale = "device_locale"
    private static let emptySchema = #"{"type":"object","properties":{},"additionalProperties":false}"#

    private let now: @Sendable () -> Date
    private let locale: @Sendable () -> Locale
    private let timeZone: @Sendable () -> TimeZone

    init(
        now: @escaping @Sendable () -> Date = { Date() }, locale: @escaping @Sendable () -> Locale = { .current },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
    }

    func list() -> [MeshLocalToolSpec] {
        [
            MeshLocalToolSpec(
                name: Self.currentDateTime,
                summary: "Returns the current date and time on this device with its time zone.",
                schemaJSON: Self.emptySchema, annotationsJSON: #"{"readOnlyHint":true}"#, effect: .meshRead,
                confidentiality: .public),
            MeshLocalToolSpec(
                name: Self.deviceLocale,
                summary: "Returns this device's language, region and calendar settings.",
                schemaJSON: Self.emptySchema, annotationsJSON: #"{"readOnlyHint":true}"#, effect: .meshRead,
                confidentiality: .private),
        ]
    }

    func call(name: String, argumentsJSON: String, ticket: Data) throws -> String {
        guard name == Self.currentDateTime || name == Self.deviceLocale else {
            throw MeshKernelError.refused("tool.unknown: " + name)
        }
        guard try Self.noArguments(argumentsJSON) else { throw MeshKernelError.refused("tool.bad_arguments: " + name) }
        let result: [String: String]
        if name == Self.currentDateTime {
            let zone = timeZone()
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = zone
            formatter.formatOptions = [.withInternetDateTime]
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "en_US_POSIX")
            weekday.timeZone = zone
            weekday.dateFormat = "EEEE"
            let date = now()
            result = [
                "iso8601": formatter.string(from: date), "timezone": zone.identifier,
                "weekday": weekday.string(from: date),
            ]
        } else {
            let current = locale()
            result = [
                "identifier": current.identifier, "language": current.language.languageCode?.identifier ?? "",
                "region": current.region?.identifier ?? "", "calendar": String(describing: current.calendar.identifier),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func noArguments(_ json: String) throws -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return false
        }
        return object.isEmpty
    }
}
