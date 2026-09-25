// Validates ROTE's console geometry without deriving native breakpoints or layout policy.
// The shell replaces this immutable value when a current device profile arrives.

import Foundation

public struct ConsoleInsets: Equatable, Sendable {
    public let top: Double
    public let right: Double
    public let bottom: Double
    public let left: Double

    init?(json: JSONValue?) {
        guard let top = ConsoleDecoding.number(json?["top"], range: 0...16384),
            let right = ConsoleDecoding.number(json?["right"], range: 0...16384),
            let bottom = ConsoleDecoding.number(json?["bottom"], range: 0...16384),
            let left = ConsoleDecoding.number(json?["left"], range: 0...16384)
        else { return nil }
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

public struct ConsolePresentation: Equatable, Sendable {
    public enum NavigationMode: String, Sendable {
        case drawer, sidebar, stack
    }

    public enum SettingsPresentation: String, Sendable {
        case sheet, dialog, push
    }

    public enum NavigationAxis: String, Sendable {
        case horizontal, vertical
    }

    public let version: Int
    public let navigationMode: NavigationMode
    public let sidebarWidth: Double
    public let contentPadding: ConsoleInsets
    public let composerPadding: ConsoleInsets
    public let scenarioColumns: Int
    public let settingsPresentation: SettingsPresentation
    public let settingsNavigationAxis: NavigationAxis
    public let settingsWidth: Double
    public let dialogWidth: Double
    public let settingsMaxHeight: Double
    public let settingsNavigationWidth: Double
    public let resultPreviewMaxHeight: Double
    public let resultBodyMaxHeight: Double
    public let fullscreenInset: Double
    public let minimumControlHeight: Double

    public init?(frame: InboundFrame) {
        guard frame.name == "rote_config" else { return nil }
        self.init(json: frame.payload["device_profile"]?["console"])
    }

    public init?(json: JSONValue?) {
        guard json?["version"]?.numberValue == 2,
            let rawNavigation = json?["navigation_mode"]?.stringValue,
            let navigationMode = NavigationMode(rawValue: rawNavigation),
            let sidebarWidth = ConsoleDecoding.number(json?["sidebar_width"], range: 0...16384),
            navigationMode == .stack ? sidebarWidth == 0 : sidebarWidth > 0,
            let contentPadding = ConsoleInsets(json: json?["content_padding"]),
            let composerPadding = ConsoleInsets(json: json?["composer_padding"]),
            let columns = ConsoleDecoding.number(json?["scenario_columns"], range: 1...64),
            columns.rounded() == columns,
            let rawPresentation = json?["settings_presentation"]?.stringValue,
            let settingsPresentation = SettingsPresentation(rawValue: rawPresentation),
            let rawAxis = json?["settings_navigation_axis"]?.stringValue,
            let settingsNavigationAxis = NavigationAxis(rawValue: rawAxis),
            let settingsWidth = ConsoleDecoding.number(json?["settings_width"], range: 1...16384),
            let dialogWidth = ConsoleDecoding.number(json?["dialog_width"], range: 1...16384),
            let settingsMaxHeight = ConsoleDecoding.number(json?["settings_max_height"], range: 0.1...16384),
            let settingsNavigationWidth = ConsoleDecoding.number(json?["settings_navigation_width"], range: 0...16384),
            let resultPreviewMaxHeight = ConsoleDecoding.number(json?["result_preview_max_height"], range: 1...16384),
            let resultBodyMaxHeight = ConsoleDecoding.number(json?["result_body_max_height"], range: 1...16384),
            let fullscreenInset = ConsoleDecoding.number(json?["fullscreen_inset"], range: 0...16384),
            let minimumControlHeight = ConsoleDecoding.number(json?["minimum_control_height"], range: 0...16384)
        else { return nil }
        version = 2
        self.navigationMode = navigationMode
        self.sidebarWidth = sidebarWidth
        self.contentPadding = contentPadding
        self.composerPadding = composerPadding
        scenarioColumns = Int(columns)
        self.settingsPresentation = settingsPresentation
        self.settingsNavigationAxis = settingsNavigationAxis
        self.settingsWidth = settingsWidth
        self.dialogWidth = dialogWidth
        self.settingsMaxHeight = settingsMaxHeight
        self.settingsNavigationWidth = settingsNavigationWidth
        self.resultPreviewMaxHeight = resultPreviewMaxHeight
        self.resultBodyMaxHeight = resultBodyMaxHeight
        self.fullscreenInset = fullscreenInset
        self.minimumControlHeight = minimumControlHeight
    }
}
