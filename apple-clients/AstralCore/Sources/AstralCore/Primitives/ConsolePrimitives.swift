// Mirrors the composite actions, statistics and charts authored by astralprims.
// These declarations serialize through Primitive and are rendered by the native ComponentView.

import Foundation

extension AstralPrims {
    public final class ActionGroup: Primitive {
        public var buttons: [Primitive]
        public var align: String
        public var label: String?

        public init(buttons: [Primitive] = [], align: String = "start", label: String? = nil) {
            self.buttons = buttons
            self.align = align
            self.label = label
            super.init(type: "action_group")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("buttons", .array(buttons.map { $0.toDict() })), ("align", .string(align)),
                ("label", label.map(JSONValue.string)),
            ]
        }
    }

    public final class StatGroup: Primitive {
        public var title: String?
        public var items: [[String: JSONValue]]
        public var columns: Int

        public init(title: String? = nil, items: [[String: JSONValue]] = [], columns: Int = 4) {
            self.title = title
            self.items = items
            self.columns = columns
            super.init(type: "stat_group")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", title.map(JSONValue.string)), ("items", .array(items.map(JSONValue.object))),
                ("columns", .number(Double(columns))),
            ]
        }
    }

    public final class Gauge: Primitive {
        public var label: String
        public var value: Double
        public var displayValue: String?
        public var thresholds: [[String: JSONValue]]
        public var subtitle: String?

        public init(
            label: String = "", value: Double = 0, displayValue: String? = nil,
            thresholds: [[String: JSONValue]] = [], subtitle: String? = nil
        ) {
            self.label = label
            self.value = value
            self.displayValue = displayValue
            self.thresholds = thresholds
            self.subtitle = subtitle
            super.init(type: "gauge")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)), ("value", .number(value)),
                ("display_value", displayValue.map(JSONValue.string)),
                ("thresholds", .array(thresholds.map(JSONValue.object))),
                ("subtitle", subtitle.map(JSONValue.string)),
            ]
        }
    }

    public final class PipelineStepper: Primitive {
        public var title: String?
        public var steps: [[String: JSONValue]]
        public var orientation: String

        public init(title: String? = nil, steps: [[String: JSONValue]] = [], orientation: String = "horizontal") {
            self.title = title
            self.steps = steps
            self.orientation = orientation
            super.init(type: "pipeline_stepper")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", title.map(JSONValue.string)), ("steps", .array(steps.map(JSONValue.object))),
                ("orientation", .string(orientation)),
            ]
        }
    }

    public final class DonutChart: Primitive {
        public var title: String
        public var labels: [String]
        public var data: [Double]
        public var centerLabel: String?
        public var centerValue: String?

        public init(
            title: String = "", labels: [String] = [], data: [Double] = [],
            centerLabel: String? = nil, centerValue: String? = nil
        ) {
            self.title = title
            self.labels = labels
            self.data = data
            self.centerLabel = centerLabel
            self.centerValue = centerValue
            super.init(type: "donut_chart")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)), ("labels", strings(labels)), ("data", numbers(data)),
                ("center_label", centerLabel.map(JSONValue.string)),
                ("center_value", centerValue.map(JSONValue.string)),
            ]
        }
    }

    public final class RadarChart: Primitive {
        public var title: String
        public var axes: [String]
        public var datasets: [[String: JSONValue]]
        public var maxValue: Double?

        public init(
            title: String = "", axes: [String] = [], datasets: [[String: JSONValue]] = [],
            maxValue: Double? = nil
        ) {
            self.title = title
            self.axes = axes
            self.datasets = datasets
            self.maxValue = maxValue
            super.init(type: "radar_chart")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)), ("axes", strings(axes)),
                ("datasets", .array(datasets.map(JSONValue.object))), ("max_value", maxValue.map(JSONValue.number)),
            ]
        }
    }
}
