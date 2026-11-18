// Native SwiftUI renderer for the astralprims component vocabulary, styled to match web/Android/Windows and
// round-tripping actions via emit(); unknown types fall back to labeled text. ConsoleShell's Mac settings sheet
// opts into a compact density whose controls keep one size across states. Used by ComponentView.

import AstralCore
import SwiftUI

private struct WorkReadSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NavigationTranscriptKey: EnvironmentKey { static let defaultValue: String? = nil }

private struct NavigationSurfaceKey: EnvironmentKey { static let defaultValue = false }

private struct ComponentActionOwnerKey: EnvironmentKey { static let defaultValue: AstralComponent? = nil }

private struct GuidanceSurfaceKey: EnvironmentKey { static let defaultValue = false }

private struct CompactSettingsKey: EnvironmentKey { static let defaultValue = false }

private struct CompactCardContentKey: EnvironmentKey { static let defaultValue = false }

private struct CompactChipKey: EnvironmentKey { static let defaultValue: Bool? = nil }

private struct MeshActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String, String, [String: JSONValue]) -> Void)? = nil
}

extension EnvironmentValues {
    var astralComponentActionOwner: AstralComponent? {
        get { self[ComponentActionOwnerKey.self] }
        set { self[ComponentActionOwnerKey.self] = newValue }
    }
    var astralNavigationTranscript: String? {
        get { self[NavigationTranscriptKey.self] }
        set { self[NavigationTranscriptKey.self] = newValue }
    }
    var astralNavigationSurface: Bool {
        get { self[NavigationSurfaceKey.self] }
        set { self[NavigationSurfaceKey.self] = newValue }
    }
    var astralGuidanceSurface: Bool {
        get { self[GuidanceSurfaceKey.self] }
        set { self[GuidanceSurfaceKey.self] = newValue }
    }
    var astralWorkReadSurface: Bool {
        get { self[WorkReadSurfaceKey.self] }
        set { self[WorkReadSurfaceKey.self] = newValue }
    }
    var astralCompactSettings: Bool {
        get { self[CompactSettingsKey.self] }
        set { self[CompactSettingsKey.self] = newValue }
    }
    var astralCompactCardContent: Bool {
        get { self[CompactCardContentKey.self] }
        set { self[CompactCardContentKey.self] = newValue }
    }
    var astralCompactChip: Bool? {
        get { self[CompactChipKey.self] }
        set { self[CompactChipKey.self] = newValue }
    }
    var astralMeshAction: (@MainActor @Sendable (String, String, [String: JSONValue]) -> Void)? {
        get { self[MeshActionKey.self] }
        set { self[MeshActionKey.self] = newValue }
    }
}

struct ComponentAlertMessage: View {
    let text: String
    let literal: Bool

    var body: some View {
        if literal {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownBlockView(source: text)
        }
    }
}

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct ComponentView: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralWorkReadSurface) private var workReadSurface
    @Environment(\.astralViewportWidth) private var viewportWidth
    @Environment(\.astralCompactSettings) private var compactSettings
    @Environment(\.astralCompactCardContent) private var compactCardContent
    @Environment(\.astralCompactChip) private var compactChip
    @Environment(\.astralMeshAction) private var meshAction
    @State private var slotWidth: CGFloat = 0

    private var p: AstralPalette { theme.palette }

    private func fittedColumns(authored: Int) -> Int {
        guard slotWidth > 0 else { return min(authored, 2) }
        return min(authored, max(1, Int(slotWidth / 150)))
    }

    private var widthProbe: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { slotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in
                    if abs(w - slotWidth) > 1 { slotWidth = w }
                }
        }
        .frame(height: 0)
    }

    var body: some View {
        renderedContent
    }

    @ViewBuilder
    private var renderedContent: some View {
        if compactSettings, CompactSettingsLayout.rendered.contains(component.type) {
            compactContent
        } else {
            switch component.type {
            case "text":
                textView
            case "alert":
                alertView
            case "card":
                cardView
            case "collapsible":
                CollapsibleComponent(component: component)
            case "container":
                containerView
            case "grid":
                gridView
            case "metric":
                metricView
            case "action_group":
                actionGroupView
            case "stat_group":
                statGroupView
            case "gauge":
                gaugeView
            case "pipeline_stepper":
                pipelineView
            case "donut_chart":
                donutView
            case "radar_chart":
                radarView
            case "badge":
                badgeView
            case "hero":
                heroView
            case "list":
                listView.font(ComponentTypeScale.body)
            case "keyvalue":
                keyValueView
            case "timeline":
                timelineView
            case "rating":
                ratingView
            case "table":
                TableComponent(component: component)
            case "code":
                codeView
            case "image":
                imageView
            case "progress":
                progressView
            case "divider":
                Divider().overlay(p.border)
            case "button":
                buttonView
            case "file_upload":
                fileUploadHint
            case "input":
                InputComponent(component: component)
            case "tabs":
                TabsComponent(component: component)
            case "bar_chart", "line_chart", "pie_chart", "plotly_chart":
                ChartComponent(component: component)
            case "skeleton":
                skeletonView
            case "theme_apply":
                Color.clear.frame(height: 0)
                    .onAppear { theme.apply(spec: component.raw["attributes"] ?? component.raw) }
                    .onChange(of: component.raw) { _, raw in theme.apply(spec: raw["attributes"] ?? raw) }
            default:
                fallbackView
            }
        }
    }

    @ViewBuilder
    private var textView: some View {
        let text = component.textContent ?? component.fallbackText
        if component.variant == "markdown" && !workReadSurface {
            MarkdownBlockView(source: text)
                .foregroundStyle(p.text)
                .textSelection(.enabled)
        } else {
            markdown(text)
                .font(fontForVariant(component.variant))
                .foregroundStyle(component.variant == "caption" ? p.muted : p.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fontForVariant(_ v: String?) -> Font {
        switch v {
        case "h1": return ComponentTypeScale.title
        case "h2": return ComponentTypeScale.heading
        case "h3": return ComponentTypeScale.body.weight(.semibold)
        case "caption": return ComponentTypeScale.caption
        default: return ComponentTypeScale.body
        }
    }

    private var alertView: some View {
        let color = p.variant(component.variant)
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(color).frame(width: 3)
            Image(systemName: alertIcon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if let title = component.title, !title.isEmpty {
                    markdown(title).font(ComponentTypeScale.body.weight(.semibold))
                        .foregroundStyle(p.textVariant(component.variant))
                }
                ComponentAlertMessage(text: component.message ?? component.fallbackText, literal: workReadSurface)
                    .font(ComponentTypeScale.body)
                    .foregroundStyle(p.text)
            }
            Spacer(minLength: 0)
        }
        .padding(ComponentSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
    }

    private var alertIcon: String {
        switch component.variant {
        case "error", "danger": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "success": return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private var cardView: some View {
        VStack(alignment: .leading, spacing: ComponentSpacing.tight) {
            if let title = component.title, !title.isEmpty {
                HStack(spacing: 8) {
                    Capsule().fill(p.primary).frame(width: 4, height: 16)
                    markdown(title).font(ComponentTypeScale.heading)
                        .foregroundStyle(p.text).frame(minHeight: 24)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            childViews
        }
        .padding(AstralWebStyle.canvasInset(viewportWidth) + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .componentCardSurface(p)
    }

    @ViewBuilder
    private var containerView: some View {
        let dir = component.raw["direction"]?.stringValue
        if let fill = containerFill(component) {
            Rectangle().fill(fill.color).frame(maxWidth: .infinity).frame(height: fill.height)
                .accessibilityHidden(true)
        } else if dir == "row", !component.children.isEmpty,
            component.children.allSatisfy({ containerFill($0) != nil })
        {
            HStack(spacing: 0) { childViews }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AstralRadius.sm))
        } else if dir == "row" {
            let count = fittedColumns(authored: max(1, component.children.count))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                    count: count),
                alignment: .leading, spacing: 8
            ) { childViews }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { widthProbe }
        } else {
            VStack(alignment: .leading, spacing: 8) { childViews }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func containerFill(_ component: AstralComponent) -> (color: Color, height: CGFloat)? {
        guard component.type == "container", component.children.isEmpty,
            let css = component.raw["css"], let background = css["background"]?.stringValue,
            let color = Color(cssHex: background), let raw = css["height"]?.stringValue,
            raw.hasSuffix("px"), let height = Double(raw.dropLast(2)), height.isFinite, height > 0, height <= 1024
        else { return nil }
        return (color, CGFloat(height))
    }

    private var gridView: some View {
        let authored = RenderNumber.int(component.raw["columns"]?.numberValue ?? 2, in: 1...12)
        let count = fittedColumns(authored: authored)
        return VStack(alignment: .leading, spacing: 6) {
            titleLine
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                    count: count),
                alignment: .leading, spacing: 8
            ) {
                childViews
            }
        }
        .overlay(alignment: .top) { widthProbe }
    }

    private var metricView: some View {
        let color = AstralWebStyle.metricAccent(component.variant, palette: p)
        let title = component.title ?? ""
        let value = component.value ?? ""
        let trend = MetricTrend(component.raw)
        return VStack(alignment: .leading, spacing: 0) {
            markdown(title)
                .font(ComponentTypeScale.caption.weight(.medium))
                .tracking(0.6).textCase(.uppercase).foregroundStyle(p.muted)
                .frame(minHeight: 16).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(ComponentTypeScale.title)
                    .tracking(-0.3).foregroundStyle(p.text).frame(minHeight: 33.6)
                if let trend {
                    HStack(spacing: 3) {
                        Image(systemName: trend.symbol).accessibilityHidden(true)
                        markdown(trend.delta)
                    }
                    .font(ComponentTypeScale.caption.weight(.semibold))
                    .foregroundStyle(trend.direction == .up ? p.success : trend.direction == .down ? p.error : p.muted)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(trend.direction.rawValue)
                }
            }
            if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                markdown(sub).font(ComponentTypeScale.caption).foregroundStyle(p.muted)
                    .frame(minHeight: 16).padding(.top, 4)
            }
            if let progress = component.raw["progress"]?.numberValue, progress.isFinite {
                let fraction = min(1, max(0, progress))
                let fill = progress > 0.9 ? p.error : progress > 0.7 ? p.warning : p.primary
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(fill).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 6).padding(.top, 12)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [color.opacity(0.2), color.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(color.opacity(0.85)).frame(width: 3).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.05)))
        .astralWebShadow(radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(component.raw["aria-label"]?.stringValue ?? (title.isEmpty ? value : "\(title): \(value)"))
    }

    private var badgeView: some View {
        let color = p.textVariant(component.variant)
        return Text(component.label ?? component.fallbackText)
            .font(ConsoleTypography.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private var heroView: some View {
        ordinaryHero
    }

    private var ordinaryHero: some View {
        let variant = component.variant ?? "default"
        return VStack(alignment: .leading, spacing: 0) {
            if variant == "gradient" {
                Rectangle().fill(p.gradient).frame(height: 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow = component.raw["eyebrow"]?.stringValue, !eyebrow.isEmpty {
                    Text(eyebrow).font(ComponentTypeScale.caption.bold()).foregroundStyle(p.readablePrimary)
                        .tracking(0.6).textCase(.uppercase)
                }
                markdown(component.raw["heading"]?.stringValue ?? component.title ?? "")
                    .font(ComponentTypeScale.title).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let sub = component.raw["subtitle"]?.stringValue ?? component.raw["subheading"]?.stringValue {
                    markdown(sub).font(ComponentTypeScale.heading.weight(.regular)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = component.raw["summary"]?.stringValue, !summary.isEmpty {
                    markdown(summary).font(ComponentTypeScale.body).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let badges = component.raw["badges"]?.arrayValue ?? []
                if !badges.isEmpty {
                    HStack {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, b in
                            Text(b["label"]?.stringValue ?? b.displayText)
                                .font(ConsoleTypography.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(p.primary.opacity(0.18), in: Capsule())
                                .foregroundStyle(p.text)
                        }
                    }
                }
            }
            .padding(ComponentSpacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(heroBackground(variant), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AstralRadius.md))
    }

    private func heroBackground(_ variant: String) -> AnyShapeStyle {
        switch variant {
        case "gradient":
            return AnyShapeStyle(
                LinearGradient(
                    colors: [p.primary.opacity(0.18), p.secondary.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        case "subtle":
            return AnyShapeStyle(p.text.opacity(0.02))
        default:
            return AnyShapeStyle(p.surface.opacity(0.55))
        }
    }

    private var listView: some View {
        let ordered = component.raw["ordered"]?.boolValue ?? false
        let items = component.listItems
        let glyphs = (component.raw["items"]?.arrayValue ?? []).map(ListItemGlyph.init)
        return VStack(alignment: .leading, spacing: 6) {
            titleLine
            if items.isEmpty {
                childViews
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let glyph = glyphs[safe: index] ?? nil {
                            Image(systemName: glyph.symbol)
                                .foregroundStyle(glyph.tone.map { p.variant($0) } ?? p.muted)
                                .frame(minWidth: 16)
                                .accessibilityLabel(glyph.label)
                        } else {
                            Text(ordered ? "\(index + 1)." : "•").foregroundStyle(p.muted)
                                .frame(minWidth: 16, alignment: .leading)
                        }
                        markdown(item).foregroundStyle(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var keyValueView: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            ForEach(Array(component.keyValuePairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top) {
                    Text(pair.0).foregroundStyle(p.muted)
                    Spacer(minLength: ComponentSpacing.tight)
                    Text(pair.1).foregroundStyle(p.text).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(ComponentTypeScale.body)
            }
        }
        .padding(ComponentSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border, lineWidth: 1))
    }

    private var timelineView: some View {
        let items = component.raw["items"]?.arrayValue ?? []
        return VStack(alignment: .leading, spacing: 6) {
            titleLine
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(p.variant(item["variant"]?.stringValue))
                        .frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        if let time = item["time"]?.stringValue, !time.isEmpty {
                            Text(time).font(ComponentTypeScale.caption).foregroundStyle(p.muted)
                        }
                        markdown(item["title"]?.stringValue ?? item["label"]?.stringValue ?? item.displayText)
                            .font(ComponentTypeScale.body).foregroundStyle(p.text)
                        if let desc = item["description"]?.stringValue, !desc.isEmpty {
                            markdown(desc).font(ComponentTypeScale.caption).foregroundStyle(p.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var ratingView: some View {
        let rawValue = component.raw["value"]?.numberValue ?? 0
        let maxValue = RenderNumber.int(
            component.raw["max_value"]?.numberValue ?? component.raw["max"]?.numberValue ?? 5, in: 1...10)
        let value = RenderNumber.int(rawValue.rounded(), in: 0...maxValue)
        return VStack(alignment: .leading, spacing: 2) {
            if let label = component.label ?? component.title, !label.isEmpty {
                markdown(label).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
            HStack(spacing: 2) {
                ForEach(0..<maxValue, id: \.self) { i in
                    Image(systemName: i < value ? "star.fill" : "star")
                        .foregroundStyle(p.accent)
                }
                if component.raw["show_value"]?.boolValue != false {
                    Text("\(rawValue.formatted(.number.precision(.fractionLength(0...1))))/\(maxValue)")
                        .font(ConsoleTypography.caption.weight(.semibold)).foregroundStyle(p.text)
                        .padding(.leading, 4)
                }
            }
            if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                markdown(sub).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
        }
    }

    private var codeView: some View {
        let code = component.textContent ?? component.raw["code"]?.stringValue ?? ""
        let language = (component.raw["language"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !language.isEmpty, language.lowercased() != "text" {
                    Text(verbatim: language).font(ComponentTypeScale.caption.weight(.medium))
                        .foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                ComponentCopyButton(text: code, palette: p)
            }
            .padding(.horizontal, ComponentSpacing.tight).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(ConsoleTypography.mono(13))
                    .foregroundStyle(p.success)
                    .textSelection(.enabled)
                    .padding(.horizontal, ComponentSpacing.tight).padding(.bottom, ComponentSpacing.tight)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border, lineWidth: 1))
    }

    @ViewBuilder
    private var imageView: some View {
        if let source = component.url ?? component.raw["src"]?.stringValue {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if source.prefix(5).lowercased() == "data:" {
                        InlineComponentImageView(source: source)
                    } else if let url = URL(string: source) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                ProgressView().tint(p.primary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: AstralRadius.md))
                if let caption = component.raw["caption"]?.stringValue ?? component.raw["alt"]?.stringValue,
                    !caption.isEmpty
                {
                    Text(caption).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                }
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = component.label ?? component.title, !label.isEmpty {
                HStack {
                    markdown(label).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    Spacer(minLength: 8)
                    if component.raw["show_percentage"]?.boolValue != false {
                        Text("\(Int((progressFraction * 100).rounded()))%")
                            .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                }
            }
            ProgressView(value: progressFraction).tint(p.primary)
        }
    }

    private var progressFraction: Double {
        let value = component.raw["value"]?.numberValue ?? 0
        return value > 1 ? min(value / 100, 1) : min(max(value, 0), 1)
    }

    @ViewBuilder
    private var buttonView: some View {
        let label = component.label ?? component.title ?? "Continue"
        let variant = component.variant ?? "primary"
        let serverDisabled =
            component.raw["disabled"]?.boolValue == true || component.raw["enabled"]?.boolValue == false
        let chip = CompactSettingsLayout.chipState(
            serverDisabled: serverDisabled, selected: compactSettings && compactChip == true)
        let button = Button {
            guard !chip.inert else { return }
            let payload = component.raw["payload"]?.objectValue ?? [:]
            if let meshAction, let capability = component.raw["capability"]?.stringValue,
                let componentId = component.componentId
            {
                meshAction(componentId, capability, payload)
            }
        } label: {
            if compactSettings {
                CompactButtonLabel(text: label)
            } else {
                Text(label).fixedSize(horizontal: false, vertical: true)
                    .frame(
                        maxWidth: variant == "primary" && meshAction == nil ? .infinity : nil)
            }
        }
        .disabled(chip.disabled)
        .accessibilityAddTraits(compactSettings && compactChip == true ? .isSelected : [])
        #if os(macOS)
            let accessibleButton =
                button
                .accessibilityLabel(component.raw["aria-label"]?.stringValue ?? label)
                .accessibilityIdentifier(component.raw["id"]?.stringValue ?? "")
        #else
            let accessibleButton = button
        #endif
        if meshAction != nil {
            switch variant {
            case "secondary", "ghost": accessibleButton.buttonStyle(.bordered)
            case "danger": accessibleButton.buttonStyle(.borderedProminent).tint(p.error)
            default: accessibleButton.buttonStyle(.borderedProminent)
            }
        } else {
            accessibleButton.buttonStyle(
                AstralButtonStyle(palette: p, variant: variant, chip: compactSettings ? compactChip : nil))
        }
    }

    private var actionGroupView: some View {
        let group = ActionGroupPresentation(component.raw)
        return VStack(alignment: .leading, spacing: 8) {
            if !group.label.isEmpty {
                markdown(group.label).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
            CompositeFlow(alignment: group.alignment) {
                ForEach(Array(group.buttons.enumerated()), id: \.offset) { _, button in
                    ComponentView(component: button)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label)
    }

    private var statGroupView: some View {
        let group = StatGroupPresentation(component.raw)
        return VStack(alignment: .leading, spacing: 8) {
            compositeTitle(group.title)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: min(group.columns, fittedColumns(authored: group.columns))), spacing: 8
            ) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        markdown(item.label).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        CompositeFlow(spacing: 4) {
                            markdown(item.value).font(ConsoleTypography.title3.bold()).foregroundStyle(p.text)
                            if !item.delta.isEmpty {
                                markdown("\(item.trendSymbol) \(item.delta)")
                                    .font(ConsoleTypography.caption).foregroundStyle(compositeColor(item.variant))
                            }
                        }
                        if !item.hint.isEmpty {
                            markdown(item.hint).font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .background(p.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.text.opacity(0.1)))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .background(widthProbe)
    }

    private var gaugeView: some View {
        let gauge = GaugePresentation(component.raw)
        return VStack(spacing: 4) {
            ZStack {
                CompositeGaugeArc(fraction: 1).stroke(
                    p.text.opacity(0.12), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                CompositeGaugeArc(fraction: gauge.value)
                    .stroke(compositeColor(gauge.variant), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            }
            .aspectRatio(100.0 / 56.0, contentMode: .fit)
            .frame(maxWidth: 128)
            .accessibilityHidden(true)
            Text(verbatim: gauge.displayValue).font(ConsoleTypography.title3.bold()).foregroundStyle(p.text)
            markdown(gauge.label).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            if !gauge.subtitle.isEmpty {
                markdown(gauge.subtitle).font(ConsoleTypography.caption2).foregroundStyle(p.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.accessibilityLabel)
        .accessibilityValue(gauge.subtitle)
    }

    private var pipelineView: some View {
        let pipeline = PipelinePresentation(component.raw)
        return VStack(alignment: .leading, spacing: 8) {
            compositeTitle(pipeline.title)
            let layout =
                pipeline.vertical
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(CompositeFlow(spacing: 12))
            layout {
                ForEach(Array(pipeline.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(step.status == "pending" ? p.text.opacity(0.25) : compositeColor(step.variant))
                            .overlay(
                                Circle().stroke(
                                    compositeColor(step.variant).opacity(step.isCurrent ? 0.25 : 0), lineWidth: 6)
                            )
                            .frame(width: 8, height: 8).padding(.top, 4)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            markdown(step.label).font(ConsoleTypography.caption).foregroundStyle(p.text)
                            if !step.detail.isEmpty {
                                markdown(step.detail).font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(step.isCurrent ? "Current step, \(step.status)" : step.status)
                }
            }
        }
    }

    @ViewBuilder
    private var donutView: some View {
        let donut = DonutPresentation(component.raw)
        if !donut.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                compositeTitle(donut.title)
                ZStack {
                    ForEach(Array(donut.segments.enumerated()), id: \.offset) { _, segment in
                        Circle().trim(from: segment.start, to: segment.end)
                            .stroke(seriesColor(segment.series), lineWidth: 22.4)
                            .padding(16).rotationEffect(.degrees(-90))
                    }
                    VStack(spacing: 2) {
                        markdown(donut.centerValue).font(ConsoleTypography.title3.bold()).foregroundStyle(p.text)
                        markdown(donut.centerLabel).font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    }
                    .padding(30)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(donut.title.isEmpty ? "Donut chart" : "Donut chart: \(donut.title)")
                .accessibilityValue(
                    [donut.centerValue, donut.centerLabel].filter { !$0.isEmpty }.joined(separator: ", "))
                CompositeFlow {
                    ForEach(Array(donut.segments.enumerated()), id: \.offset) { _, segment in
                        compositeLegend(segment.label, series: segment.series)
                            .accessibilityLabel(segment.label)
                            .accessibilityValue(JSONValue.number(segment.value).displayText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var radarView: some View {
        let radar = RadarPresentation(component.raw)
        if radar.canRender {
            VStack(alignment: .leading, spacing: 8) {
                compositeTitle(radar.title)
                ZStack {
                    ForEach([0.24, 0.48, 0.72, 0.9], id: \.self) { diameter in
                        Circle().stroke(p.text.opacity(0.15), lineWidth: 1).scaleEffect(diameter)
                    }
                    ForEach(Array(radar.datasets.enumerated()), id: \.offset) { _, dataset in
                        CompositeRadarPolygon(points: dataset.points)
                            .fill(seriesColor(dataset.series).opacity(0.28))
                            .overlay(
                                CompositeRadarPolygon(points: dataset.points)
                                    .stroke(seriesColor(dataset.series), lineWidth: 2.88))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 192)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(radar.title.isEmpty ? "Radar chart" : "Radar chart: \(radar.title)")
                CompositeFlow {
                    ForEach(Array(radar.datasets.enumerated()), id: \.offset) { _, dataset in
                        compositeLegend(dataset.label, series: dataset.series)
                            .accessibilityLabel(dataset.label)
                            .accessibilityValue(
                                radar.axes.enumerated().map { index, axis in
                                    let value =
                                        index < dataset.values.count
                                        ? JSONValue.number(dataset.values[index]).displayText : "No value"
                                    return "\(axis): \(value)"
                                }.joined(separator: ", "))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compositeTitle(_ title: String) -> some View {
        if !title.isEmpty { markdown(title).font(ConsoleTypography.subheadline.bold()).foregroundStyle(p.text) }
    }

    private func compositeLegend(_ label: String, series: Int) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(seriesColor(series)).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(verbatim: label).font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func compositeColor(_ variant: String) -> Color {
        variant == "info" ? p.accent : p.variant(variant)
    }

    private func seriesColor(_ index: Int) -> Color {
        let colors = [p.primary, p.secondary, p.accent]
        let base = colors[index % 3]
        if index < 3 { return base }
        let resolved = base.resolve(in: EnvironmentValues())
        return Color(
            .sRGB, red: Double(resolved.red) * 0.55 + 0.45,
            green: Double(resolved.green) * 0.55 + 0.45, blue: Double(resolved.blue) * 0.55 + 0.45)
    }

    private var skeletonView: some View {
        let count = RenderNumber.int(component.raw["count"]?.numberValue ?? 3, in: 1...6)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AstralRadius.sm)
                    .fill(p.surface.opacity(0.5))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var fallbackView: some View {
        VStack(alignment: .leading, spacing: 2) {
            markdown(component.fallbackText).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.3), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
    }

    @ViewBuilder
    private var titleLine: some View {
        if let title = component.title, !title.isEmpty {
            HStack(spacing: 6) {
                Rectangle().fill(p.gradient).frame(width: 3, height: 16)
                markdown(title).font(compactSettings ? ConsoleTypography.headline : ComponentTypeScale.heading)
                    .foregroundStyle(p.text)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var fileUploadHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "paperclip").foregroundStyle(p.muted).accessibilityHidden(true)
            if let label = component.label ?? component.title, !label.isEmpty {
                markdown(label).foregroundStyle(p.text)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
    }

    @ViewBuilder
    private var childViews: some View {
        ComponentChildrenList(raw: component.raw)
    }

    private func markdown(_ string: String) -> Text {
        workReadSurface ? Text(verbatim: string) : Text(InlineMarkdown.attributed(string))
    }

    private func isTruthy(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return value.boolValue == true
            || (value.numberValue ?? 0) > 0
            || (value.stringValue?.isEmpty == false)
    }
}

enum ComponentAccessibility {
    static func buttonValue(pending: Bool) -> String { pending ? "Submitting" : "" }
}

enum ComponentTypeScale {
    static var title: Font { ConsoleTypography.sans(22, relativeTo: .title2).weight(.semibold) }
    static var heading: Font { ConsoleTypography.sans(17, relativeTo: .headline).weight(.semibold) }
    static var body: Font { ConsoleTypography.sans(14, relativeTo: .body) }
    static var caption: Font { ConsoleTypography.sans(12, relativeTo: .caption) }
}

enum ComponentSpacing {
    static let tight: CGFloat = 12
    static let regular: CGFloat = 16
    static let loose: CGFloat = 24
}

struct MetricTrend: Equatable {
    enum Direction: String { case up, down, flat }

    let delta: String
    let direction: Direction

    init?(_ raw: JSONValue) {
        let delta = CompositeValue.text(raw["delta"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !delta.isEmpty else { return nil }
        self.delta = delta
        let stated = raw["trend"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let stated, let direction = Direction(rawValue: stated) {
            self.direction = direction
        } else if delta.hasPrefix("-") || delta.hasPrefix("−") {
            direction = .down
        } else if delta.hasPrefix("+") || (Double(delta.filter { "0123456789.".contains($0) }) ?? 0) > 0 {
            direction = .up
        } else {
            direction = .flat
        }
    }

    var symbol: String {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }
}

struct ListItemGlyph: Equatable {
    let symbol: String
    let tone: String?
    let label: String

    init?(_ item: JSONValue) {
        guard item.objectValue != nil else { return nil }
        let status = item["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch status {
        case "done", "complete", "completed", "success", "passed", "ok":
            (symbol, tone) = ("checkmark.circle.fill", "success")
        case "warning", "warn", "attention":
            (symbol, tone) = ("exclamationmark.triangle.fill", "warning")
        case "error", "failed", "failure", "blocked", "danger":
            (symbol, tone) = ("xmark.octagon.fill", "error")
        case "active", "running", "in_progress", "current":
            (symbol, tone) = ("circle.dotted.circle", "info")
        case "pending", "todo", "queued", "skipped":
            (symbol, tone) = ("circle", nil)
        default:
            guard let icon = item["icon"]?.stringValue, Self.isSymbol(icon) else { return nil }
            (symbol, tone) = (icon, nil)
        }
        label = status.isEmpty ? "" : status.replacingOccurrences(of: "_", with: " ")
    }

    static func isSymbol(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) else {
            return false
        }
        #if os(macOS)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
            return UIImage(systemName: name) != nil
        #endif
    }
}

struct ComponentCopyButton: View {
    let text: String
    let palette: AstralPalette
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            copied = ComponentPasteboard.copy(text)
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(ComponentTypeScale.caption.weight(.medium))
                .foregroundStyle(palette.muted)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .help(label)
        .accessibilityLabel(copied ? "Copied" : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

enum ComponentPasteboard {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        #if os(macOS)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
            return true
        #endif
    }
}

extension View {
    func componentCardSurface(_ palette: AstralPalette) -> some View {
        background(palette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: AstralRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(palette.border, lineWidth: 1))
            .astralWebShadow(radius: AstralRadius.md)
            .astralChartBackdrop(palette, color: palette.surface, opacity: 0.45)
    }
}

enum CompactSettingsLayout {
    static let rendered: Set<String> = ["text", "alert", "card", "container", "badge", "keyvalue", "code", "list"]
    private static let inline: Set<String> = ["button", "badge", "text", "link"]

    struct Item {
        let index: Int
        let component: AstralComponent
    }

    struct Card {
        enum Segment {
            case item(Item)
            case actions([Item])
        }

        private(set) var badges: [Item] = []
        private(set) var segments: [Segment] = []
        private(set) var headerActions: [Item] = []

        init(_ raw: JSONValue, titled: Bool) {
            var items = ComponentChildren.items(raw).map { Item(index: $0.index, component: $0.component) }[...]
            while let first = items.first, CompactSettingsLayout.isBadgeRun(first.component) {
                badges.append(first)
                items = items.dropFirst()
            }
            for item in items {
                if CompactSettingsLayout.isActionRun(item.component) {
                    if case .actions(let run)? = segments.last {
                        segments[segments.count - 1] = .actions(run + [item])
                    } else {
                        segments.append(.actions([item]))
                    }
                } else {
                    segments.append(.item(item))
                }
            }
            if titled, case .actions(let run)? = segments.last, segments.dropLast().allSatisfy(Self.isRowDetail) {
                headerActions = run
                segments.removeLast()
            }
        }

        private static func isRowDetail(_ segment: Segment) -> Bool {
            guard case .item(let item) = segment else { return false }
            let component = item.component
            return component.type == "container"
                ? CompactSettingsLayout.isRow(component) : !detailBlocks.contains(component.type)
        }

        private static let detailBlocks: Set<String> = ["param_picker", "card", "collapsible", "table", "tabs"]
    }

    static func isRow(_ component: AstralComponent) -> Bool {
        component.type == "container" && component.raw["direction"]?.stringValue == "row" && !component.children.isEmpty
    }

    static func isInlineRow(_ component: AstralComponent) -> Bool {
        isRow(component) && component.children.allSatisfy { inline.contains($0.type) }
    }

    static func isActionRun(_ component: AstralComponent) -> Bool {
        component.type == "button" || (isRow(component) && component.children.allSatisfy { $0.type == "button" })
    }

    static func isBadgeRun(_ component: AstralComponent) -> Bool {
        component.type == "badge" || (isRow(component) && component.children.allSatisfy { $0.type == "badge" })
    }

    static func chipSelection(_ buttons: [AstralComponent]) -> [Bool]? {
        guard buttons.count >= 2,
            buttons.allSatisfy({ $0.type == "button" && $0.raw["action"]?.stringValue == "chrome_open" })
        else { return nil }
        let disabled = buttons.map { $0.raw["disabled"]?.boolValue == true || $0.raw["enabled"]?.boolValue == false }
        if disabled.filter({ $0 }).count == 1 { return disabled }
        let primary = buttons.map { ($0.variant ?? "primary") == "primary" }
        return !disabled.contains(true) && primary.filter({ $0 }).count == 1 ? primary : nil
    }

    static func chipState(serverDisabled: Bool, selected: Bool) -> (disabled: Bool, inert: Bool) {
        (serverDisabled && !selected, serverDisabled && selected)
    }

    static func isNumeric(_ cells: [String]) -> Bool {
        let values = cells.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" && $0 != "—" }
        return !values.isEmpty
            && values.allSatisfy { value in
                Double(value.filter { !",%$€£ ".contains($0) }.replacingOccurrences(of: "−", with: "-")) != nil
            }
    }
}

extension ComponentView {
    @ViewBuilder
    fileprivate var compactContent: some View {
        switch component.type {
        case "text": compactText
        case "alert": compactAlert
        case "card": compactCard
        case "container": compactContainer
        case "badge": compactBadge
        case "keyvalue": compactKeyValue
        case "code": compactCode
        default: compactList
        }
    }

    @ViewBuilder
    private var compactText: some View {
        let text = component.textContent ?? component.fallbackText
        if component.variant == "markdown" && !workReadSurface {
            MarkdownBlockView(source: text)
                .font(ConsoleTypography.footnote).foregroundStyle(p.text).textSelection(.enabled)
        } else if component.variant == "h3" {
            compactSectionHeader(text).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            markdown(text)
                .font(compactTextFont).foregroundStyle(compactTextColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(["h1", "h2"].contains(component.variant ?? "") ? .isHeader : [])
        }
    }

    private var compactTextFont: Font {
        switch component.variant {
        case "h1": return ConsoleTypography.title3.weight(.semibold)
        case "h2": return ConsoleTypography.headline
        case "caption": return ConsoleTypography.caption
        default: return ConsoleTypography.footnote
        }
    }

    private var compactTextColor: Color {
        switch component.variant {
        case "h1", "h2": return p.text
        case "caption": return p.muted
        default: return compactCardContent ? p.muted : p.text
        }
    }

    private func compactSectionHeader(_ title: String) -> some View {
        markdown(title)
            .font(ConsoleTypography.caption.weight(.semibold)).tracking(0.6).textCase(.uppercase)
            .foregroundStyle(p.muted)
            .accessibilityAddTraits(.isHeader)
    }

    private var compactAlert: some View {
        let color = p.variant(component.variant)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: alertIcon).font(ConsoleTypography.footnote).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if let title = component.title, !title.isEmpty {
                    markdown(title).font(ConsoleTypography.footnote.weight(.semibold)).foregroundStyle(p.text)
                }
                ComponentAlertMessage(text: component.message ?? component.fallbackText, literal: workReadSurface)
                    .font(ConsoleTypography.footnote).foregroundStyle(p.text)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(color.opacity(0.25)))
    }

    private var compactCard: some View {
        let title = component.title.flatMap { $0.isEmpty ? nil : $0 }
        let layout = CompactSettingsLayout.Card(component.raw, titled: title != nil)
        let fill = compactCardContent ? p.surface2 : p.surface
        return VStack(alignment: .leading, spacing: 8) {
            if title != nil || !layout.badges.isEmpty || !layout.headerActions.isEmpty {
                CompactHeaderLayout {
                    CompositeFlow(spacing: 6, centered: true) {
                        if let title {
                            markdown(title)
                                .font(ConsoleTypography.subheadline.weight(.semibold)).foregroundStyle(p.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(layout.badges, id: \.index) { compactChild($0) }
                    }
                    if !layout.headerActions.isEmpty { compactActions(layout.headerActions) }
                }
            }
            ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .item(let item): compactChild(item)
                case .actions(let run): compactActions(run)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border))
        .astralChartBackdrop(p, color: fill, opacity: 1)
    }

    private func compactChild(_ item: CompactSettingsLayout.Item) -> some View {
        ComponentView(component: item.component)
            .environment(\.astralCompactCardContent, true)
    }

    private func compactActions(_ run: [CompactSettingsLayout.Item]) -> some View {
        CompositeFlow(spacing: 6, alignment: "end", centered: true) {
            ForEach(run, id: \.index) { compactChild($0) }
        }
    }

    @ViewBuilder
    private var compactContainer: some View {
        if CompactSettingsLayout.isInlineRow(component) {
            let items = ComponentChildren.items(component.raw)
            let chips = CompactSettingsLayout.chipSelection(items.map { $0.component })
            CompositeFlow(spacing: 6, centered: true) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    ComponentView(component: item.component)
                        .environment(\.astralCompactChip, chips?[offset])
                }
            }
        } else {
            containerView
        }
    }

    private var compactBadge: some View {
        let neutral = (component.variant ?? "default") == "default"
        let color = neutral ? p.muted : p.textVariant(component.variant)
        let shape = RoundedRectangle(cornerRadius: AstralRadius.md)
        return Text(component.label ?? component.fallbackText)
            .font(ConsoleTypography.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(shape.fill(color.opacity(0.14)).overlay(shape.strokeBorder(color.opacity(0.3))))
            .fixedSize()
    }

    private var compactKeyValue: some View {
        let pairs = component.keyValuePairs
        return VStack(alignment: .leading, spacing: 4) {
            if let title = component.title, !title.isEmpty { compactSectionHeader(title) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    if index > 0 { Divider().overlay(p.border) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(pair.0).foregroundStyle(p.muted)
                        Spacer(minLength: 12)
                        Text(pair.1).foregroundStyle(p.text).multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(ConsoleTypography.footnote)
                    .padding(.vertical, 5)
                }
            }
            .compactGroupBox(!compactCardContent, palette: p)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactCode: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(component.textContent ?? component.raw["code"]?.stringValue ?? "")
                .font(ConsoleTypography.mono(12))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
        .foregroundStyle(p.success)
    }

    private var compactList: some View {
        listView.font(ConsoleTypography.footnote)
    }
}

private struct CompactHeaderLayout: Layout {
    var spacing: CGFloat = 12

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard let leading = subviews.first else { return [] }
        guard subviews.count > 1 else {
            return [CGRect(origin: .zero, size: leading.sizeThatFits(ProposedViewSize(width: width, height: nil)))]
        }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if leading.sizeThatFits(.unspecified).width + spacing + trailing.width <= width {
            let size = leading.sizeThatFits(ProposedViewSize(width: width - spacing - trailing.width, height: nil))
            let height = max(size.height, trailing.height)
            return [
                CGRect(x: 0, y: (height - size.height) / 2, width: size.width, height: size.height),
                CGRect(
                    x: width - trailing.width, y: (height - trailing.height) / 2, width: trailing.width,
                    height: trailing.height),
            ]
        }
        let size = leading.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let actions = subviews[1].sizeThatFits(ProposedViewSize(width: min(width, trailing.width), height: nil))
        return [
            CGRect(origin: .zero, size: size),
            CGRect(x: width - actions.width, y: size.height + 8, width: actions.width, height: actions.height),
        ]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width =
            proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct CompositeGaugeArc: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.height * 50 / 56), radius: rect.width * 0.4,
            startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction), clockwise: false)
        return path
    }
}

private struct CompositeRadarPolygon: Shape {
    let points: [RadarPresentation.Point]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = CGPoint(x: rect.width * point.x, y: rect.height * point.y)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }
}

private struct CompositeFlow: Layout {
    var spacing: CGFloat = 8
    var alignment = "start"
    var centered = false

    private func rows(width: CGFloat, subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = []
        var row: [(Int, CGSize)] = []
        var used: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            let fitted = CGSize(width: min(width, size.width), height: size.height)
            if !row.isEmpty && used + spacing + fitted.width > width {
                rows.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : spacing) + fitted.width
            row.append((index, fitted))
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal =
            subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + CGFloat(max(0, subviews.count - 1)) * spacing
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal)
        let rows = rows(width: width, subviews: subviews)
        return CGSize(
            width: width,
            height: rows.reduce(0) { $0 + ($1.map { $0.1.height }.max() ?? 0) }
                + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            let used = row.reduce(0) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            let remaining = max(0, bounds.width - used)
            var x = bounds.minX + (alignment == "end" ? remaining : alignment == "center" ? remaining / 2 : 0)
            let gap = alignment == "between" && row.count > 1 ? spacing + remaining / CGFloat(row.count - 1) : spacing
            let rowHeight = row.map { $0.1.height }.max() ?? 0
            for (index, size) in row {
                let offset = centered ? (rowHeight - size.height) / 2 : 0
                subviews[index].place(at: CGPoint(x: x, y: y + offset), proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            y += (row.map { $0.1.height }.max() ?? 0) + spacing
        }
    }
}

struct AstralButtonStyle: ButtonStyle {
    let palette: AstralPalette
    let variant: String
    var chip: Bool? = nil

    func makeBody(configuration: Configuration) -> some View {
        AstralButtonBody(configuration: configuration, palette: palette, variant: variant, chip: chip)
    }
}

private struct AstralButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let palette: AstralPalette
    let variant: String
    let chip: Bool?
    @Environment(\.astralCompactSettings) private var compact
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if compact { compactBody } else { standardBody }
    }

    private var standardBody: some View {
        let label = configuration.label
            .font(ConsoleTypography.callout.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
        switch variant {
        case "secondary", "ghost":
            return AnyView(
                label.foregroundStyle(palette.text)
                    .background(palette.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .overlay(RoundedRectangle(cornerRadius: AstralRadius.sm).stroke(palette.border))
                    .opacity(configuration.isPressed ? 0.7 : 1))
        case "danger":
            return AnyView(
                label.foregroundStyle(palette.onError)
                    .background(palette.error, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .opacity(configuration.isPressed ? 0.8 : 1))
        default:
            return AnyView(
                label.foregroundStyle(.white)
                    .background(palette.gradient, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .opacity(configuration.isPressed ? 0.85 : 1))
        }
    }

    // Every compact button keeps one height, weight and minimum width so state never resizes or shifts a row
    private var compactBody: some View {
        let shape = RoundedRectangle(cornerRadius: AstralRadius.sm)
        let colors = compactColors
        return configuration.label
            .font(ConsoleTypography.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: SettingsControlMetrics.minimumWidth)
            .frame(height: SettingsControlMetrics.height)
            .foregroundStyle(colors.foreground)
            .background(colors.fill, in: shape)
            .overlay(shape.strokeBorder(colors.stroke))
            .contentShape(shape)
            .opacity(isEnabled || chip == true ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    private var compactColors: (foreground: Color, fill: Color, stroke: Color) {
        if let chip {
            return chip
                ? (palette.text, palette.primary.opacity(0.22), palette.primary.opacity(0.6))
                : (palette.muted, palette.text.opacity(0.04), palette.border)
        }
        switch variant {
        case "secondary", "ghost": return (palette.text, palette.text.opacity(0.06), palette.border)
        case "danger": return (palette.error, palette.error.opacity(0.12), palette.error.opacity(0.4))
        default: return (.white, palette.primary, palette.primary)
        }
    }
}

private struct CompactButtonLabel: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).fixedSize()
            Text(text).lineLimit(1).truncationMode(.tail).help(text)
        }
    }
}

enum TableColumnLayout {
    static let stickyRowLimit = 10
    static let rowHeight: CGFloat = 32
    static let minimumWidth: CGFloat = 64
    static let maximumWidth: CGFloat = 320

    static func widths(headers: [String], rows: [[String]], columns: Int, available: CGFloat) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let natural = (0..<columns).map { column -> CGFloat in
            let header = column < headers.count ? headers[column].count : 0
            let cells = rows.prefix(200).map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
            return min(maximumWidth, max(minimumWidth, CGFloat(max(header, cells)) * 7.6 + 20))
        }
        let total = natural.reduce(0, +)
        guard available.isFinite, available > total, total > 0 else { return natural }
        return natural.map { ($0 * available / total).rounded(.down) }
    }
}

struct TableComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralCompactSettings) private var compactSettings
    @State private var tableWidth: CGFloat = 0
    private var p: AstralPalette { theme.palette }

    var body: some View {
        if compactSettings { compactTable } else { standardTable }
    }

    private var compactTable: some View {
        let headers = component.tableHeaders
        let rows = component.tableRows
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        let numeric = (0..<columns).map { column in
            CompactSettingsLayout.isNumeric(rows.compactMap { column < $0.count ? $0[column] : nil })
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title))
                    .font(ConsoleTypography.subheadline.weight(.semibold)).foregroundStyle(p.text)
            }
            ViewThatFits(in: .horizontal) {
                compactGrid(headers: headers, rows: rows, columns: columns, numeric: numeric)
                ScrollView(.horizontal) {
                    compactGrid(headers: headers, rows: rows, columns: columns, numeric: numeric)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AstralRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactGrid(headers: [String], rows: [[String]], columns: Int, numeric: [Bool]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !headers.isEmpty {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        compactCell(
                            column < headers.count ? headers[column] : "", header: true, numeric: numeric[column],
                            fill: p.surface2)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        compactCell(
                            column < row.count ? row[column] : "", header: false, numeric: numeric[column],
                            fill: index.isMultiple(of: 2) ? p.surface : p.surface2.opacity(0.6))
                    }
                }
            }
        }
    }

    private func compactCell(_ text: String, header: Bool, numeric: Bool, fill: Color) -> some View {
        Text(text)
            .font(header ? ConsoleTypography.caption.weight(.semibold) : ConsoleTypography.footnote)
            .tracking(header ? 0.4 : 0)
            .textCase(header ? .uppercase : nil)
            .foregroundStyle(header ? p.muted : p.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: header ? 26 : 30, alignment: numeric ? .trailing : .leading)
            .background(fill)
    }

    private var standardTable: some View {
        let headers = component.tableHeaders
        let rows = component.tableRows
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        let numeric = (0..<columns).map { column in
            CompactSettingsLayout.isNumeric(rows.compactMap { column < $0.count ? $0[column] : nil })
        }
        let widths = TableColumnLayout.widths(headers: headers, rows: rows, columns: columns, available: tableWidth)
        return VStack(alignment: .leading, spacing: 8) {
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title)).font(ComponentTypeScale.heading).foregroundStyle(p.text)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !headers.isEmpty {
                        tableRow(headers, columns: columns, widths: widths, numeric: numeric, header: true)
                            .background(p.surface2)
                            .overlay(alignment: .bottom) { p.border.frame(height: 1) }
                            .accessibilityAddTraits(.isHeader)
                    }
                    if rows.count > TableColumnLayout.stickyRowLimit {
                        ScrollView(.vertical) { tableBody(rows, columns: columns, widths: widths, numeric: numeric) }
                            .frame(height: CGFloat(TableColumnLayout.stickyRowLimit) * TableColumnLayout.rowHeight)
                    } else {
                        tableBody(rows, columns: columns, widths: widths, numeric: numeric)
                    }
                }
                .frame(width: widths.reduce(0, +), alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: AstralRadius.sm))
        }
        .padding(ComponentSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(p.border, lineWidth: 1))
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { tableWidth = max(0, geometry.size.width - 2 * ComponentSpacing.tight) }
                    .onChange(of: geometry.size.width) { _, width in
                        tableWidth = max(0, width - 2 * ComponentSpacing.tight)
                    }
            }
        }
    }

    private func tableBody(_ rows: [[String]], columns: Int, widths: [CGFloat], numeric: [Bool]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                tableRow(row, columns: columns, widths: widths, numeric: numeric, header: false)
                    .background(index.isMultiple(of: 2) ? Color.clear : p.text.opacity(0.035))
            }
        }
        .textSelection(.enabled)
    }

    private func tableRow(
        _ cells: [String], columns: Int, widths: [CGFloat], numeric: [Bool], header: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { column in
                Text(column < cells.count ? cells[column] : "")
                    .font(header ? ComponentTypeScale.caption.weight(.semibold) : ComponentTypeScale.body)
                    .monospacedDigit()
                    .tracking(header ? 0.4 : 0)
                    .textCase(header ? .uppercase : nil)
                    .foregroundStyle(header ? p.muted : p.text)
                    .multilineTextAlignment(numeric[column] ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, header ? 6 : 7)
                    .frame(width: widths[column], alignment: numeric[column] ? .trailing : .leading)
            }
        }
        .frame(minHeight: header ? 28 : TableColumnLayout.rowHeight, alignment: .leading)
    }

}

struct InputComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralCompactSettings) private var compactSettings
    @Environment(\.astralMeshAction) private var meshAction
    @State private var value = ""
    @State private var initialValue = ""
    @FocusState private var editingFocused: Bool
    private var p: AstralPalette { theme.palette }

    var body: some View {
        let placeholder = component.raw["placeholder"]?.stringValue ?? ""
        VStack(alignment: .leading, spacing: 3) {
            if let label = component.label, !label.isEmpty {
                Text(label).font(compactSettings ? ConsoleTypography.footnote : ConsoleTypography.caption)
                    .foregroundStyle(compactSettings ? p.text : p.muted)
                    .accessibilityHidden(true)
            }
            HStack(spacing: compactSettings ? 6 : 8) {
                TextField(placeholder, text: $value)
                    .astralFieldStyle(compactSettings, palette: p)
                    .focused($editingFocused)
                    .onSubmit(submit)
                    .accessibilityLabel(component.label.flatMap { $0.isEmpty ? nil : $0 } ?? placeholder)
                if compactSettings {
                    Button("Send", action: submit).buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                } else {
                    Button("Send", action: submit).tint(p.readablePrimary)
                }
            }
        }
        .onAppear {
            initialValue = component.raw["value"]?.stringValue ?? ""
            value = initialValue
        }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let meshAction, let capability = component.raw["capability"]?.stringValue,
            let componentId = component.componentId
        {
            meshAction(componentId, capability, ["value": .string(trimmed)])
        }
    }
}

struct TabsComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralCompactSettings) private var compactSettings
    @State private var selection = 0
    private var p: AstralPalette { theme.palette }

    private var tabs: [JSONValue] { component.raw["tabs"]?.arrayValue ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compactSettings ? 6 : 10) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        tabButton(tab["label"]?.stringValue ?? "Tab \(index + 1)", index: index)
                    }
                }
            }
            if tabs.indices.contains(selection) {
                ComponentChildrenList(raw: tabs[selection])
            }
        }
    }

    @ViewBuilder
    private func tabButton(_ label: String, index: Int) -> some View {
        let button = Button(label) { selection = index }
            .accessibilityAddTraits(selection == index ? .isSelected : [])
        if compactSettings {
            button.buttonStyle(AstralButtonStyle(palette: p, variant: "secondary", chip: selection == index))
        } else {
            button.font(ConsoleTypography.callout.weight(.semibold))
                .foregroundStyle(selection == index ? p.readablePrimary : p.muted)
        }
    }
}

struct CollapsibleComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralCompactSettings) private var compactSettings
    @State private var expanded: Bool
    private var p: AstralPalette { theme.palette }

    init(component: AstralComponent) {
        self.component = component
        _expanded = State(initialValue: component.raw["default_open"]?.boolValue ?? false)
    }

    private var title: String? { component.title?.isEmpty == false ? component.title : nil }
    private var spokenTitle: String { title ?? component.raw["aria-label"]?.stringValue ?? "Details" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(p.muted)
                    Text(title.map { InlineMarkdown.attributed($0) } ?? AttributedString("Details"))
                        .font(headerFont).foregroundStyle(p.text)
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 44, minHeight: compactSettings ? 28 : 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title == nil ? spokenTitle : "")
            .accessibilityLabel(title.map { Text(InlineMarkdown.attributed($0)) } ?? Text(spokenTitle))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ComponentChildrenList(raw: component.raw)
            }
        }
        .padding(compactSettings ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(compactSettings ? p.border : Color.clear)
        )
        .astralChartBackdrop(p, color: p.surface, opacity: 0.4)
    }

    private var headerFont: Font {
        compactSettings ? ConsoleTypography.subheadline.weight(.semibold) : ConsoleTypography.headline
    }
}

extension View {
    fileprivate func compactGroupBox(_ boxed: Bool, palette: AstralPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: AstralRadius.md)
        return padding(.horizontal, boxed ? 12 : 0)
            .background(boxed ? palette.surface : Color.clear, in: shape)
            .overlay(shape.strokeBorder(boxed ? palette.border : Color.clear))
    }

    @ViewBuilder
    fileprivate func compactFont(_ font: Font?) -> some View {
        if let font { self.font(font) } else { self }
    }

    @ViewBuilder
    fileprivate func astralFieldStyle(_ compact: Bool, palette: AstralPalette) -> some View {
        if compact {
            let shape = RoundedRectangle(cornerRadius: AstralRadius.sm)
            textFieldStyle(.plain)
                .font(ConsoleTypography.footnote)
                .padding(.horizontal, 8)
                .frame(minHeight: SettingsControlMetrics.height)
                .background(palette.text.opacity(0.04), in: shape)
                .overlay(shape.strokeBorder(palette.fieldBorder))
        } else {
            textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    fileprivate func astralSelectOutline(_ compact: Bool, palette: AstralPalette) -> some View {
        if compact {
            overlay(
                RoundedRectangle(cornerRadius: AstralRadius.sm).strokeBorder(palette.fieldBorder)
                    .allowsHitTesting(false))
        } else {
            self
        }
    }

    @ViewBuilder
    fileprivate func compactTooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }

    @ViewBuilder
    func fieldHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text).accessibilityHint(text)
        } else {
            self
        }
    }
}

struct ChartComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralViewportWidth) private var viewportWidth
    @State private var slotWidth: CGFloat = 704

    var body: some View {
        let inset = AstralWebStyle.chartInset(viewportWidth) + 1
        VStack(alignment: .leading, spacing: 12) {
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title))
                    .font(ConsoleTypography.subheadline.weight(.medium))
                    .foregroundStyle(theme.palette.text).frame(minHeight: 20)
            }
            OfflineChartView(component: component, viewportWidth: viewportWidth)
                .frame(
                    height: OfflineChartDocument.height(
                        component: component, viewportWidth: viewportWidth, slotWidth: slotWidth - 2 * inset)
                )
                .frame(maxWidth: .infinity)
        }
        .padding(inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .astralWebSurface(theme.palette)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { slotWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in slotWidth = width }
            }
        }
    }
}
