// Normalizes composite primitive payloads for the native renderer without executing server text.
// Geometry and accessibility values share the same bounded data used for visible charts and controls.

import Foundation

public enum CompositeValue {
    public static func text(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "" }
        return value.displayText
    }

    public static func number(_ value: JSONValue?, default fallback: Double = 0) -> Double {
        let number = value?.numberValue ?? value?.stringValue.flatMap(Double.init)
        guard let number, number.isFinite else { return fallback }
        return number
    }

    public static func fraction(_ value: JSONValue?) -> Double {
        min(1, max(0, number(value)))
    }

    public static func objects(_ value: JSONValue?) -> [JSONValue] {
        (value?.arrayValue ?? []).filter { $0.objectValue != nil }
    }

    public static func variant(_ value: JSONValue?, default fallback: String = "default") -> String {
        let variant = text(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["default", "success", "warning", "error", "info"].contains(variant) ? variant : fallback
    }
}

public struct ActionGroupPresentation: Equatable, Sendable {
    public let label: String
    public let alignment: String
    public let buttons: [AstralComponent]

    public init(_ raw: JSONValue) {
        label = CompositeValue.text(raw["label"])
        let align = CompositeValue.text(raw["align"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        alignment = ["start", "center", "end", "between"].contains(align) ? align : "start"
        buttons = CompositeValue.objects(raw["buttons"]).map { value in
            var button = value.objectValue ?? [:]
            button["type"] = .string("button")
            return AstralComponent(type: "button", raw: .object(button))
        }
    }
}

public struct StatGroupPresentation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let label: String
        public let value: String
        public let delta: String
        public let hint: String
        public let trend: String
        public let variant: String

        public var trendSymbol: String { ["up": "▲", "down": "▼", "flat": "–"][trend] ?? "" }
    }

    public let title: String
    public let columns: Int
    public let items: [Item]

    public init(_ raw: JSONValue) {
        title = CompositeValue.text(raw["title"])
        columns = Int(min(6, max(1, CompositeValue.number(raw["columns"], default: 4))))
        items = CompositeValue.objects(raw["items"]).map {
            Item(
                label: CompositeValue.text($0["label"]), value: CompositeValue.text($0["value"]),
                delta: CompositeValue.text($0["delta"]), hint: CompositeValue.text($0["hint"]),
                trend: CompositeValue.text($0["trend"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                variant: CompositeValue.variant($0["variant"]))
        }
    }
}

public struct GaugePresentation: Equatable, Sendable {
    public let label: String
    public let value: Double
    public let displayValue: String
    public let subtitle: String
    public let variant: String
    public var accessibilityLabel: String { label.isEmpty ? displayValue : "\(label): \(displayValue)" }

    public init(_ raw: JSONValue) {
        label = CompositeValue.text(raw["label"])
        value = CompositeValue.fraction(raw["value"])
        let display = CompositeValue.text(raw["display_value"])
        displayValue = display.isEmpty ? "\(Int((value * 100).rounded(.toNearestOrEven)))%" : display
        subtitle = CompositeValue.text(raw["subtitle"])
        var selected = "default"
        for threshold in CompositeValue.objects(raw["thresholds"])
        where value >= CompositeValue.fraction(threshold["at"]) {
            selected = CompositeValue.variant(threshold["variant"], default: selected)
        }
        variant = selected
    }
}

public struct PipelinePresentation: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let label: String
        public let detail: String
        public let status: String
        public let isCurrent: Bool
        public var variant: String { ["done": "success", "active": "info", "error": "error"][status] ?? "default" }
    }

    public let title: String
    public let vertical: Bool
    public let steps: [Step]

    public init(_ raw: JSONValue) {
        title = CompositeValue.text(raw["title"])
        vertical = CompositeValue.text(raw["orientation"]).lowercased() == "vertical"
        var markedCurrent = false
        steps = CompositeValue.objects(raw["steps"]).map {
            let candidate = CompositeValue.text($0["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let status = ["done", "active", "pending", "error"].contains(candidate) ? candidate : "pending"
            let current = status == "active" && !markedCurrent
            if current { markedCurrent = true }
            return Step(
                label: CompositeValue.text($0["label"]), detail: CompositeValue.text($0["detail"]),
                status: status, isCurrent: current)
        }
    }
}

public struct DonutPresentation: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let label: String
        public let value: Double
        public let start: Double
        public let end: Double
        public let series: Int
    }

    public let title: String
    public let centerLabel: String
    public let centerValue: String
    public let segments: [Segment]

    public init(_ raw: JSONValue) {
        title = CompositeValue.text(raw["title"])
        centerLabel = CompositeValue.text(raw["center_label"])
        centerValue = CompositeValue.text(raw["center_value"])
        let labels = raw["labels"]?.arrayValue ?? []
        let values = (raw["data"]?.arrayValue ?? []).map { max(0, CompositeValue.number($0)) }
        let maximum = values.max() ?? 0
        let scaled = values.map { maximum > 0 ? $0 / maximum : 0 }
        let total = max(scaled.reduce(0, +), 1)
        var offset = 0.0
        segments = values.indices.map { index in
            let start = offset
            offset = min(1, offset + scaled[index] / total)
            return Segment(
                label: index < labels.count ? CompositeValue.text(labels[index]) : "series \(index + 1)",
                value: values[index], start: start, end: offset, series: index % 6)
        }
    }
}

public struct RadarPresentation: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    public struct Dataset: Equatable, Sendable {
        public let label: String
        public let values: [Double]
        public let points: [Point]
        public let series: Int
    }

    public let title: String
    public let axes: [String]
    public let datasets: [Dataset]
    public var canRender: Bool { axes.count >= 3 && !datasets.isEmpty }

    public init(_ raw: JSONValue) {
        title = CompositeValue.text(raw["title"])
        let axes = (raw["axes"]?.arrayValue ?? []).map { CompositeValue.text($0) }
        self.axes = axes
        let records = CompositeValue.objects(raw["datasets"])
        let values = records.map { row in
            (row["data"]?.arrayValue ?? []).map { max(0, CompositeValue.number($0)) }
        }
        let observed = values.flatMap { $0 }.max() ?? 0
        let declared = CompositeValue.number(raw["max_value"], default: observed)
        let scale = declared > 0 ? declared : (observed > 0 ? observed : 1)
        datasets = records.indices.map { index in
            let row = values[index]
            let points = axes.indices.map { axis in
                let magnitude = min(1, (axis < row.count ? row[axis] : 0) / scale)
                let angle = 2 * Double.pi * Double(axis) / Double(axes.count) - Double.pi / 2
                return Point(x: 0.5 + 0.45 * magnitude * cos(angle), y: 0.5 + 0.45 * magnitude * sin(angle))
            }
            return Dataset(
                label: CompositeValue.text(records[index]["label"]), values: row,
                points: points, series: index % 6)
        }
    }
}
