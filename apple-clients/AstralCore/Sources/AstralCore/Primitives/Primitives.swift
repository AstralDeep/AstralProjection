// Swift mirror of the astralprims Python authoring package: toDict() serializes to the same wire dict
// astralprims.<X>(...).to_dict() produces, pinned by fixtures in AstralCoreTests/Fixtures. The consuming side
// is AstralComponent.

import Foundation

public enum AstralPrims {
    open class Primitive {
        public let type: String
        public var css: [String: String]?
        public var id: String?
        public var className: String?
        public var tooltip: String?
        public var attributes: [String: JSONValue]

        public init(type: String) {
            self.type = type
            self.attributes = [:]
        }

        open var ownFields: [(String, JSONValue?)] { [] }

        public final func toDict() -> JSONValue {
            var out: [String: JSONValue] = ["type": .string(type)]
            if let css, !css.isEmpty {
                out["css"] = .object(css.mapValues { .string($0) })
            }
            if let id { out["id"] = .string(id) }
            if let className { out["class"] = .string(className) }
            if let tooltip { out["tooltip"] = .string(tooltip) }
            for (key, value) in ownFields {
                if let value { out[key] = value }
            }
            for (key, value) in attributes { out[key] = value }
            return .object(out)
        }

        public final func toJSONString() throws -> String {
            let data = try toDict().encoded()
            return String(decoding: data, as: UTF8.self)
        }

        @discardableResult
        public func css(_ css: [String: String]) -> Self {
            self.css = css
            return self
        }

        @discardableResult
        public func id(_ id: String) -> Self {
            self.id = id
            return self
        }

        @discardableResult
        public func className(_ name: String) -> Self {
            self.className = name
            return self
        }

        @discardableResult
        public func tooltip(_ tip: String) -> Self {
            self.tooltip = tip
            return self
        }

        @discardableResult
        public func attributes(_ attrs: [String: JSONValue]) -> Self {
            self.attributes.merge(attrs) { _, new in new }
            return self
        }
    }

    public static func createUIResponse(_ components: [Primitive]) -> JSONValue {
        .object([
            "_ui_components": .array(components.map { $0.toDict() }),
            "_data": .null,
        ])
    }

    public static let allTypes: Set<String> = [
        "action_group", "donut_chart", "gauge", "pipeline_stepper", "radar_chart", "stat_group",
        "alert", "audio", "badge", "bar_chart", "button", "card",
        "chat_history", "code", "collapsible", "color_picker", "container",
        "divider", "file_download", "file_upload", "grid", "hero", "image",
        "input", "keyvalue", "line_chart", "list", "metric", "param_picker",
        "pie_chart", "plotly_chart", "progress", "rating", "table", "tabs",
        "text", "theme_apply", "timeline",
    ]

    static func strings(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
    }

    static func numbers(_ values: [Double]) -> JSONValue {
        .array(values.map { .number($0) })
    }

    public final class Container: Primitive {
        public var children: [Primitive]
        public var direction: String?

        public init(children: [Primitive] = [], direction: String? = nil) {
            self.children = children
            self.direction = direction
            super.init(type: "container")
        }

        @discardableResult
        public func add(_ children: Primitive...) -> Container {
            self.children.append(contentsOf: children)
            return self
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("children", .array(children.map { $0.toDict() })),
                ("direction", direction.map(JSONValue.string)),
            ]
        }
    }

    public final class Card: Primitive {
        public var title: String
        public var content: [Primitive]
        public var variant: String

        public init(title: String = "", content: [Primitive] = [], variant: String = "default") {
            self.title = title
            self.content = content
            self.variant = variant
            super.init(type: "card")
        }

        @discardableResult
        public func add(_ content: Primitive...) -> Card {
            self.content.append(contentsOf: content)
            return self
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("content", .array(content.map { $0.toDict() })),
                ("variant", .string(variant)),
            ]
        }
    }

    public final class Grid: Primitive {
        public var columns: Int
        public var children: [Primitive]
        public var gap: Int

        public init(columns: Int = 2, children: [Primitive] = [], gap: Int = 20) {
            self.columns = columns
            self.children = children
            self.gap = gap
            super.init(type: "grid")
        }

        @discardableResult
        public func add(_ children: Primitive...) -> Grid {
            self.children.append(contentsOf: children)
            return self
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("columns", .number(Double(columns))),
                ("children", .array(children.map { $0.toDict() })),
                ("gap", .number(Double(gap))),
            ]
        }
    }

    public typealias Grids = Grid

    public struct TabItem {
        public var label: String
        public var content: [Primitive]
        public var value: String?

        public init(label: String = "", content: [Primitive] = [], value: String? = nil) {
            self.label = label
            self.content = content
            self.value = value
        }

        public func toDict() -> JSONValue {
            var out: [String: JSONValue] = [
                "label": .string(label),
                "content": .array(content.map { $0.toDict() }),
            ]
            if let value { out["value"] = .string(value) }
            return .object(out)
        }
    }

    public final class Tabs: Primitive {
        public var tabs: [TabItem]
        public var variant: String

        public init(tabs: [TabItem] = [], variant: String = "default") {
            self.tabs = tabs
            self.variant = variant
            super.init(type: "tabs")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("tabs", .array(tabs.map { $0.toDict() })),
                ("variant", .string(variant)),
            ]
        }
    }

    public final class Collapsible: Primitive {
        public var title: String
        public var content: [Primitive]
        public var defaultOpen: Bool

        public init(title: String = "", content: [Primitive] = [], defaultOpen: Bool = false) {
            self.title = title
            self.content = content
            self.defaultOpen = defaultOpen
            super.init(type: "collapsible")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("content", .array(content.map { $0.toDict() })),
                ("default_open", .bool(defaultOpen)),
            ]
        }
    }

    public final class Divider: Primitive {
        public var variant: String

        public init(variant: String = "solid") {
            self.variant = variant
            super.init(type: "divider")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [("variant", .string(variant))]
        }
    }

    public final class Text: Primitive {
        public var content: String
        public var variant: String

        public init(content: String = "", variant: String = "body") {
            self.content = content
            self.variant = variant
            super.init(type: "text")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [("content", .string(content)), ("variant", .string(variant))]
        }
    }

    public final class Button: Primitive {
        public var label: String
        public var action: String
        public var payload: [String: JSONValue]
        public var variant: String

        public init(
            label: String = "", action: String = "",
            payload: [String: JSONValue] = [:], variant: String = "primary"
        ) {
            self.label = label
            self.action = action
            self.payload = payload
            self.variant = variant
            super.init(type: "button")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)),
                ("action", .string(action)),
                ("payload", .object(payload)),
                ("variant", .string(variant)),
            ]
        }
    }

    public final class Input: Primitive {
        public var placeholder: String
        public var name: String
        public var value: String

        public init(placeholder: String = "", name: String = "", value: String = "") {
            self.placeholder = placeholder
            self.name = name
            self.value = value
            super.init(type: "input")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("placeholder", .string(placeholder)),
                ("name", .string(name)),
                ("value", .string(value)),
            ]
        }
    }

    public final class ParamPicker: Primitive {
        public var title: String
        public var description: String
        public var fields: [JSONValue]
        public var submitLabel: String
        public var submitMessageTemplate: String

        public init(
            title: String = "", description: String = "",
            fields: [JSONValue] = [], submitLabel: String = "Submit",
            submitMessageTemplate: String = ""
        ) {
            self.title = title
            self.description = description
            self.fields = fields
            self.submitLabel = submitLabel
            self.submitMessageTemplate = submitMessageTemplate
            super.init(type: "param_picker")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("description", .string(description)),
                ("fields", .array(fields)),
                ("submit_label", .string(submitLabel)),
                ("submit_message_template", .string(submitMessageTemplate)),
            ]
        }
    }

    public final class Image: Primitive {
        public var url: String
        public var alt: String?
        public var width: String?
        public var height: String?

        public init(
            url: String = "", alt: String? = nil,
            width: String? = nil, height: String? = nil
        ) {
            self.url = url
            self.alt = alt
            self.width = width
            self.height = height
            super.init(type: "image")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("url", .string(url)),
                ("alt", alt.map(JSONValue.string)),
                ("width", width.map(JSONValue.string)),
                ("height", height.map(JSONValue.string)),
            ]
        }
    }

    public final class CodeBlock: Primitive {
        public var code: String
        public var language: String
        public var showLineNumbers: Bool

        public init(
            code: String = "", language: String = "text",
            showLineNumbers: Bool = false
        ) {
            self.code = code
            self.language = language
            self.showLineNumbers = showLineNumbers
            super.init(type: "code")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("code", .string(code)),
                ("language", .string(language)),
                ("show_line_numbers", .bool(showLineNumbers)),
            ]
        }
    }

    public final class Alert: Primitive {
        public var message: String
        public var variant: String
        public var title: String?

        public init(message: String = "", variant: String = "info", title: String? = nil) {
            self.message = message
            self.variant = variant
            self.title = title
            super.init(type: "alert")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("message", .string(message)),
                ("variant", .string(variant)),
                ("title", title.map(JSONValue.string)),
            ]
        }
    }

    public final class ProgressBar: Primitive {
        public var value: Double
        public var label: String?
        public var variant: String
        public var showPercentage: Bool

        public init(
            value: Double = 0.0, label: String? = nil,
            variant: String = "default", showPercentage: Bool = true
        ) {
            self.value = value
            self.label = label
            self.variant = variant
            self.showPercentage = showPercentage
            super.init(type: "progress")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("value", .number(value)),
                ("label", label.map(JSONValue.string)),
                ("variant", .string(variant)),
                ("show_percentage", .bool(showPercentage)),
            ]
        }
    }

    public final class MetricCard: Primitive {
        public var title: String
        public var value: String
        public var subtitle: String?
        public var icon: String?
        public var variant: String
        public var progress: Double?

        public init(
            title: String = "", value: String = "", subtitle: String? = nil,
            icon: String? = nil, variant: String = "default",
            progress: Double? = nil
        ) {
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.icon = icon
            self.variant = variant
            self.progress = progress
            super.init(type: "metric")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("value", .string(value)),
                ("subtitle", subtitle.map(JSONValue.string)),
                ("icon", icon.map(JSONValue.string)),
                ("variant", .string(variant)),
                ("progress", progress.map(JSONValue.number)),
            ]
        }
    }

    public final class List: Primitive {
        public var items: [JSONValue]
        public var ordered: Bool
        public var variant: String

        public init(
            items: [JSONValue] = [], ordered: Bool = false,
            variant: String = "default"
        ) {
            self.items = items
            self.ordered = ordered
            self.variant = variant
            super.init(type: "list")
        }

        public convenience init(
            items: [String], ordered: Bool = false,
            variant: String = "default"
        ) {
            self.init(items: items.map(JSONValue.string), ordered: ordered, variant: variant)
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("items", .array(items)),
                ("ordered", .bool(ordered)),
                ("variant", .string(variant)),
            ]
        }
    }

    public final class Table: Primitive {
        public var headers: [String]
        public var rows: [[JSONValue]]
        public var variant: String
        public var totalRows: Int?
        public var pageSize: Int?
        public var pageOffset: Int?
        public var pageSizes: [Int]
        public var sourceTool: String?
        public var sourceAgent: String?
        public var sourceParams: [String: JSONValue]

        public init(
            headers: [String] = [], rows: [[JSONValue]] = [],
            variant: String = "default", totalRows: Int? = nil,
            pageSize: Int? = nil, pageOffset: Int? = nil,
            pageSizes: [Int] = [], sourceTool: String? = nil,
            sourceAgent: String? = nil, sourceParams: [String: JSONValue] = [:]
        ) {
            self.headers = headers
            self.rows = rows
            self.variant = variant
            self.totalRows = totalRows
            self.pageSize = pageSize
            self.pageOffset = pageOffset
            self.pageSizes = pageSizes
            self.sourceTool = sourceTool
            self.sourceAgent = sourceAgent
            self.sourceParams = sourceParams
            super.init(type: "table")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("headers", AstralPrims.strings(headers)),
                ("rows", .array(rows.map { .array($0) })),
                ("variant", .string(variant)),
                ("total_rows", totalRows.map { .number(Double($0)) }),
                ("page_size", pageSize.map { .number(Double($0)) }),
                ("page_offset", pageOffset.map { .number(Double($0)) }),
                ("page_sizes", .array(pageSizes.map { .number(Double($0)) })),
                ("source_tool", sourceTool.map(JSONValue.string)),
                ("source_agent", sourceAgent.map(JSONValue.string)),
                ("source_params", .object(sourceParams)),
            ]
        }
    }

    public struct ChartDataset {
        public var label: String
        public var data: [Double]
        public var color: String?

        public init(label: String = "", data: [Double] = [], color: String? = nil) {
            self.label = label
            self.data = data
            self.color = color
        }

        public func toDict() -> JSONValue {
            var out: [String: JSONValue] = [
                "label": .string(label),
                "data": AstralPrims.numbers(data),
            ]
            if let color { out["color"] = .string(color) }
            return .object(out)
        }
    }

    public final class BarChart: Primitive {
        public var title: String
        public var labels: [String]
        public var datasets: [JSONValue]

        public init(title: String = "", labels: [String] = [], datasets: [JSONValue] = []) {
            self.title = title
            self.labels = labels
            self.datasets = datasets
            super.init(type: "bar_chart")
        }

        public convenience init(
            title: String = "", labels: [String] = [],
            datasets: [ChartDataset]
        ) {
            self.init(title: title, labels: labels, datasets: datasets.map { $0.toDict() })
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("labels", AstralPrims.strings(labels)),
                ("datasets", .array(datasets)),
            ]
        }
    }

    public final class LineChart: Primitive {
        public var title: String
        public var labels: [String]
        public var datasets: [JSONValue]

        public init(title: String = "", labels: [String] = [], datasets: [JSONValue] = []) {
            self.title = title
            self.labels = labels
            self.datasets = datasets
            super.init(type: "line_chart")
        }

        public convenience init(
            title: String = "", labels: [String] = [],
            datasets: [ChartDataset]
        ) {
            self.init(title: title, labels: labels, datasets: datasets.map { $0.toDict() })
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("labels", AstralPrims.strings(labels)),
                ("datasets", .array(datasets)),
            ]
        }
    }

    public final class PieChart: Primitive {
        public var title: String
        public var labels: [String]
        public var data: [Double]
        public var colors: [String]

        public init(
            title: String = "", labels: [String] = [],
            data: [Double] = [], colors: [String] = []
        ) {
            self.title = title
            self.labels = labels
            self.data = data
            self.colors = colors
            super.init(type: "pie_chart")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("labels", AstralPrims.strings(labels)),
                ("data", AstralPrims.numbers(data)),
                ("colors", AstralPrims.strings(colors)),
            ]
        }
    }

    public final class PlotlyChart: Primitive {
        public var title: String
        public var data: [JSONValue]
        public var layout: [String: JSONValue]
        public var config: [String: JSONValue]

        public init(
            title: String = "", data: [JSONValue] = [],
            layout: [String: JSONValue] = [:], config: [String: JSONValue] = [:]
        ) {
            self.title = title
            self.data = data
            self.layout = layout
            self.config = config
            super.init(type: "plotly_chart")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("data", .array(data)),
                ("layout", .object(layout)),
                ("config", .object(config)),
            ]
        }
    }

    public final class Audio: Primitive {
        public var src: String
        public var contentType: String?
        public var autoplay: Bool
        public var loop: Bool
        public var label: String?
        public var showControls: Bool
        public var description: String?

        public init(
            src: String = "", contentType: String? = nil,
            autoplay: Bool = false, loop: Bool = false,
            label: String? = nil, showControls: Bool = true,
            description: String? = nil
        ) {
            self.src = src
            self.contentType = contentType
            self.autoplay = autoplay
            self.loop = loop
            self.label = label
            self.showControls = showControls
            self.description = description
            super.init(type: "audio")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("src", .string(src)),
                ("contentType", contentType.map(JSONValue.string)),
                ("autoplay", .bool(autoplay)),
                ("loop", .bool(loop)),
                ("label", label.map(JSONValue.string)),
                ("showControls", .bool(showControls)),
                ("description", description.map(JSONValue.string)),
            ]
        }
    }

    public final class FileUpload: Primitive {
        public var label: String
        public var accept: String
        public var action: String

        public init(label: String = "Upload File", accept: String = "*/*", action: String = "") {
            self.label = label
            self.accept = accept
            self.action = action
            super.init(type: "file_upload")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)),
                ("accept", .string(accept)),
                ("action", .string(action)),
            ]
        }
    }

    public final class FileDownload: Primitive {
        public var label: String
        public var url: String
        public var filename: String?

        public init(label: String = "Download File", url: String = "", filename: String? = nil) {
            self.label = label
            self.url = url
            self.filename = filename
            super.init(type: "file_download")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)),
                ("url", .string(url)),
                ("filename", filename.map(JSONValue.string)),
            ]
        }
    }

    public final class Badge: Primitive {
        public var label: String
        public var variant: String
        public var icon: String?

        public init(label: String = "", variant: String = "default", icon: String? = nil) {
            self.label = label
            self.variant = variant
            self.icon = icon
            super.init(type: "badge")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)),
                ("variant", .string(variant)),
                ("icon", icon.map(JSONValue.string)),
            ]
        }
    }

    public final class Hero: Primitive {
        public var title: String
        public var subtitle: String?
        public var eyebrow: String?
        public var icon: String?
        public var variant: String
        public var badges: [String]

        public init(
            title: String = "", subtitle: String? = nil, eyebrow: String? = nil,
            icon: String? = nil, variant: String = "default", badges: [String] = []
        ) {
            self.title = title
            self.subtitle = subtitle
            self.eyebrow = eyebrow
            self.icon = icon
            self.variant = variant
            self.badges = badges
            super.init(type: "hero")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", .string(title)),
                ("subtitle", subtitle.map(JSONValue.string)),
                ("eyebrow", eyebrow.map(JSONValue.string)),
                ("icon", icon.map(JSONValue.string)),
                ("variant", .string(variant)),
                ("badges", AstralPrims.strings(badges)),
            ]
        }
    }

    public final class KeyValue: Primitive {
        public var title: String?
        public var items: [JSONValue]
        public var columns: Int

        public init(title: String? = nil, items: [JSONValue] = [], columns: Int = 2) {
            self.title = title
            self.items = items
            self.columns = columns
            super.init(type: "keyvalue")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", title.map(JSONValue.string)),
                ("items", .array(items)),
                ("columns", .number(Double(columns))),
            ]
        }
    }

    public final class Timeline: Primitive {
        public var title: String?
        public var items: [JSONValue]
        public var variant: String

        public init(title: String? = nil, items: [JSONValue] = [], variant: String = "default") {
            self.title = title
            self.items = items
            self.variant = variant
            super.init(type: "timeline")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", title.map(JSONValue.string)),
                ("items", .array(items)),
                ("variant", .string(variant)),
            ]
        }
    }

    public final class Rating: Primitive {
        public var value: Double
        public var maxValue: Int
        public var label: String?
        public var subtitle: String?
        public var showValue: Bool

        public init(
            value: Double = 0.0, maxValue: Int = 5, label: String? = nil,
            subtitle: String? = nil, showValue: Bool = true
        ) {
            self.value = value
            self.maxValue = maxValue
            self.label = label
            self.subtitle = subtitle
            self.showValue = showValue
            super.init(type: "rating")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("value", .number(value)),
                ("max_value", .number(Double(maxValue))),
                ("label", label.map(JSONValue.string)),
                ("subtitle", subtitle.map(JSONValue.string)),
                ("show_value", .bool(showValue)),
            ]
        }
    }

    public final class ChatHistory: Primitive {
        public var title: String?
        public var items: [JSONValue]

        public init(title: String? = "Recent chats", items: [JSONValue] = []) {
            self.title = title
            self.items = items
            super.init(type: "chat_history")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("title", title.map(JSONValue.string)),
                ("items", .array(items)),
            ]
        }
    }

    public final class ColorPicker: Primitive {
        public var label: String
        public var colorKey: String
        public var value: String

        public init(label: String = "", colorKey: String = "", value: String = "#000000") {
            self.label = label
            self.colorKey = colorKey
            self.value = value
            super.init(type: "color_picker")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("label", .string(label)),
                ("color_key", .string(colorKey)),
                ("value", .string(value)),
            ]
        }
    }

    public final class ThemeApply: Primitive {
        public var preset: String?
        public var colors: [String: String]?
        public var colorKey: String?
        public var colorValue: String?
        public var message: String

        public init(
            preset: String? = nil, colors: [String: String]? = nil,
            colorKey: String? = nil, colorValue: String? = nil,
            message: String = ""
        ) {
            self.preset = preset
            self.colors = colors
            self.colorKey = colorKey
            self.colorValue = colorValue
            self.message = message
            super.init(type: "theme_apply")
        }

        override public var ownFields: [(String, JSONValue?)] {
            [
                ("preset", preset.map(JSONValue.string)),
                ("colors", colors.map { .object($0.mapValues(JSONValue.string)) }),
                ("color_key", colorKey.map(JSONValue.string)),
                ("color_value", colorValue.map(JSONValue.string)),
                ("message", .string(message)),
            ]
        }
    }
}
