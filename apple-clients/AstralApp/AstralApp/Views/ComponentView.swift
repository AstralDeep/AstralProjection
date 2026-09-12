import AstralCore
// Feature 051 — the iOS/macOS SDUI renderer (FR-004/FR-025). Native views for
// the full astralprims vocabulary, styled from the shared AstralDeep palette
// (parity with web/Android/Windows), with `emit(action,payload)` round-trips
// for interactive components (buttons, inputs, tables, forms, theme). Anything
// unknown falls back to readable text with a type badge (FR-003).
import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct ComponentView: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    @Environment(\.astralViewportWidth) private var viewportWidth
    @Environment(\.canvasCapturePath) private var capturePath
    /// Measured width of this component's slot, used to clamp multi-column
    /// layouts on compact screens (0 until the first layout pass).
    @State private var slotWidth: CGFloat = 0

    private var p: AstralPalette { theme.palette }
    private var captureNode: CanvasCaptureNode? { model.canvasCapture.node(path: capturePath, component: component) }

    private func captureLayout() {
        guard slotWidth.isFinite, slotWidth > 0 else { return }
        if component.type == "grid" {
            model.canvasCapture.record(
                captureNode, columns: fittedColumns(authored: max(1, Int(component.raw["columns"]?.numberValue ?? 2))))
        } else if component.type == "container", component.raw["direction"]?.stringValue == "row" {
            model.canvasCapture.record(captureNode, columns: fittedColumns(authored: max(1, component.children.count)))
        }
    }

    /// How many ~150 pt columns actually fit the measured slot, capped at
    /// `authored`. Before the first measurement, fall back to 2 on the
    /// assumption of a compact screen — never the authored maximum.
    private func fittedColumns(authored: Int) -> Int {
        guard slotWidth > 0 else { return min(authored, 2) }
        return min(authored, max(1, Int(slotWidth / 150)))
    }

    /// Invisible width probe: writes the slot width into `slotWidth` without
    /// influencing layout (fixed 0-height overlay on the container).
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
            .onAppear { captureLayout() }
            .onChange(of: slotWidth) { _, _ in captureLayout() }
            .onChange(of: captureNode) { _, _ in captureLayout() }
    }

    @ViewBuilder
    private var renderedContent: some View {
        if WorkspaceWelcome.role(of: component) == .examples {
            WelcomeExamplesLayout { childViews }
                .frame(maxWidth: .infinity)
        } else if WorkspaceWelcome.role(of: component) == .more {
            CollapsibleComponent(component: component)
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
            case "badge":
                badgeView
            case "hero":
                heroView
            case "list":
                listView
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
                // Not a live control here — the chat input owns attachment staging.
                // A generic action button would emit a bogus component_action and
                // earn a server error alert.
                fileUploadHint
            case "input":
                InputComponent(component: component)
            case "param_picker":
                ParamPickerComponent(component: component)
            case "tabs":
                TabsComponent(component: component)
            case "color_picker":
                ColorPickerComponent(component: component)
            case "chat_history":
                chatHistoryView
            case "bar_chart", "line_chart", "pie_chart", "plotly_chart":
                ChartComponent(component: component)
            case "file_download", "download_card":
                DownloadComponent(component: component)
            case "skeleton":
                skeletonView
            case "theme_apply":
                Color.clear.frame(height: 0)
                    .onAppear { theme.apply(spec: component.raw["attributes"] ?? component.raw) }
            default:
                fallbackView
            }
        }
    }

    // MARK: text

    @ViewBuilder
    private var textView: some View {
        let text = component.textContent ?? component.fallbackText
        if component.variant == "markdown" {
            // The server explicitly declared block content (web parity:
            // block_md) — headings/fences/lists/tables must not stay literal.
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
        case "h1": return AstralTypography.largeTitle.bold()
        case "h2": return AstralTypography.title.bold()
        case "h3": return AstralTypography.title3.bold()
        case "caption": return AstralTypography.caption
        default: return AstralTypography.body
        }
    }

    // MARK: alert

    private var alertView: some View {
        let color = p.variant(component.variant)
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(color).frame(width: 3)
            Image(systemName: alertIcon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if let title = component.title, !title.isEmpty {
                    markdown(title).font(AstralTypography.subheadline.bold()).foregroundStyle(color)
                }
                MarkdownBlockView(source: component.message ?? component.fallbackText)
                    .foregroundStyle(p.text)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
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

    // MARK: containers

    private var cardView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = component.title, !title.isEmpty {
                HStack(spacing: 8) {
                    Capsule().fill(p.primary).frame(width: 4, height: 16)
                    markdown(title).font(AstralTypography.headline)
                        .foregroundStyle(p.text).frame(minHeight: 24)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            childViews
        }
        .padding(AstralWebStyle.canvasInset(viewportWidth) + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .astralWebSurface(p)
    }

    @ViewBuilder
    private var containerView: some View {
        let dir = component.raw["direction"]?.stringValue
        if dir == "row" {
            // Not a fixed HStack: N children on a phone would each get
            // screenWidth/N points and wrap character-by-character. Clamp the
            // side-by-side count to how many ~150 pt slots the measured width
            // fits, breaking extra children to the next line.
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

    private var gridView: some View {
        // The authored column count is a wide-screen hint. Honoring it verbatim
        // on a phone gives each cell screenWidth/N points and wraps content
        // character-by-character — clamp to the columns the measured width
        // actually fits, so a 4-up grid becomes 2×2 on compact widths.
        let authored = max(1, Int(component.raw["columns"]?.numberValue ?? 2))
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

    // MARK: metric / badge / hero

    private var metricView: some View {
        let color = AstralWebStyle.metricAccent(component.variant, palette: p)
        let title = component.title ?? ""
        let value = component.value ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            markdown(title)
                .font(AstralTypography.caption.weight(.medium))
                .tracking(0.6).textCase(.uppercase).foregroundStyle(p.muted)
                .frame(minHeight: 16).padding(.bottom, 4)
            Text(value).font(AstralTypography.title.weight(.bold))
                .tracking(-0.56).foregroundStyle(p.text).frame(minHeight: 33.6)
            if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                markdown(sub).font(AstralTypography.caption).foregroundStyle(p.muted)
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
        let color = p.variant(component.variant)
        return Text(component.label ?? component.fallbackText)
            .font(AstralTypography.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }

    /// Hero variants match the web renderer: default = surface + soft border,
    /// `gradient` = subtle 135° wash (primary 18% → secondary 8%) with a 3 pt
    /// top accent bar, `subtle` = 2% text wash — never a full-strength banner.
    @ViewBuilder
    private var heroView: some View {
        if WorkspaceWelcome.role(of: component) == .intro {
            VStack(spacing: 8) {
                markdown(component.raw["heading"]?.stringValue ?? component.title ?? "")
                    .font(AstralTypography.largeTitle.weight(.medium)).foregroundStyle(p.text)
                if let subtitle = component.raw["subtitle"]?.stringValue {
                    markdown(subtitle).foregroundStyle(p.muted)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            ordinaryHero
        }
    }

    private var ordinaryHero: some View {
        let variant = component.variant ?? "default"
        return VStack(alignment: .leading, spacing: 0) {
            if variant == "gradient" {
                Rectangle().fill(p.gradient).frame(height: 3)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow = component.raw["eyebrow"]?.stringValue, !eyebrow.isEmpty {
                    Text(eyebrow).font(AstralTypography.caption.bold()).foregroundStyle(p.primary).textCase(.uppercase)
                }
                markdown(component.raw["heading"]?.stringValue ?? component.title ?? "")
                    .font(AstralTypography.title.bold()).foregroundStyle(p.text)
                if let sub = component.raw["subtitle"]?.stringValue ?? component.raw["subheading"]?.stringValue {
                    markdown(sub).foregroundStyle(p.muted)
                }
                let badges = component.raw["badges"]?.arrayValue ?? []
                if !badges.isEmpty {
                    HStack {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, b in
                            Text(b["label"]?.stringValue ?? b.displayText)
                                .font(AstralTypography.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(p.primary.opacity(0.18), in: Capsule())
                                .foregroundStyle(p.text)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(heroBackground(variant), in: RoundedRectangle(cornerRadius: AstralRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.lg).stroke(p.border))
        .clipShape(RoundedRectangle(cornerRadius: AstralRadius.lg))
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

    // MARK: list / keyvalue / timeline / rating

    private var listView: some View {
        let ordered = component.raw["ordered"]?.boolValue ?? false
        let items = component.listItems
        return VStack(alignment: .leading, spacing: 4) {
            titleLine
            if items.isEmpty {
                childViews
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(p.muted)
                        markdown(item).foregroundStyle(p.text)
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
                    Spacer(minLength: 12)
                    Text(pair.1).foregroundStyle(p.text)
                }
                .font(AstralTypography.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
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
                            Text(time).font(AstralTypography.caption2).foregroundStyle(p.muted)
                        }
                        markdown(item["title"]?.stringValue ?? item["label"]?.stringValue ?? item.displayText)
                            .font(AstralTypography.callout).foregroundStyle(p.text)
                        if let desc = item["description"]?.stringValue, !desc.isEmpty {
                            markdown(desc).font(AstralTypography.caption).foregroundStyle(p.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var ratingView: some View {
        let rawValue = component.raw["value"]?.numberValue ?? 0
        let value = Int(rawValue.rounded())
        let maxValue = Int(component.raw["max_value"]?.numberValue ?? component.raw["max"]?.numberValue ?? 5)
        return VStack(alignment: .leading, spacing: 2) {
            if let label = component.label ?? component.title, !label.isEmpty {
                markdown(label).font(AstralTypography.caption).foregroundStyle(p.muted)
            }
            HStack(spacing: 2) {
                ForEach(0..<max(maxValue, 1), id: \.self) { i in
                    Image(systemName: i < value ? "star.fill" : "star")
                        .foregroundStyle(p.accent)
                }
                // The stars round — the number is the honest value (web shows
                // it by default; 3.5/5 must not read as four stars flat).
                if component.raw["show_value"]?.boolValue != false {
                    Text("\(rawValue.formatted(.number.precision(.fractionLength(0...1))))/\(maxValue)")
                        .font(AstralTypography.caption.weight(.semibold)).foregroundStyle(p.text)
                        .padding(.leading, 4)
                }
            }
            if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                markdown(sub).font(AstralTypography.caption).foregroundStyle(p.muted)
            }
        }
    }

    // MARK: code / image / progress

    private var codeView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(component.textContent ?? component.raw["code"]?.stringValue ?? "")
                .font(AstralTypography.mono(16))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
        .foregroundStyle(Color(hex: 0x8BE9A0))
    }

    @ViewBuilder
    private var imageView: some View {
        if let url = (component.url ?? component.raw["src"]?.stringValue).flatMap(URL.init(string:)) {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        CanvasLoadedImage(image: image, node: captureNode, registry: model.canvasCapture)
                    } else {
                        ProgressView().tint(p.primary)
                            .onAppear {
                                if let node = captureNode { model.canvasCapture.retain(nil, for: node) }
                            }
                    }
                }
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: AstralRadius.md))
                if let caption = component.raw["caption"]?.stringValue ?? component.raw["alt"]?.stringValue,
                    !caption.isEmpty
                {
                    Text(caption).font(AstralTypography.caption).foregroundStyle(p.muted)
                }
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The wire caption field is `label` (progress has no `title`).
            if let label = component.label ?? component.title, !label.isEmpty {
                HStack {
                    markdown(label).font(AstralTypography.caption).foregroundStyle(p.muted)
                    Spacer(minLength: 8)
                    if component.raw["show_percentage"]?.boolValue != false {
                        Text("\(Int((progressFraction * 100).rounded()))%")
                            .font(AstralTypography.caption).foregroundStyle(p.muted)
                    }
                }
            }
            ProgressView(value: progressFraction).tint(p.primary)
        }
    }

    private var progressFraction: Double {
        let value = component.raw["value"]?.numberValue ?? 0
        // Web/others use 0–1; tolerate 0–100.
        return value > 1 ? min(value / 100, 1) : min(max(value, 0), 1)
    }

    // MARK: interactive

    @ViewBuilder
    private var buttonView: some View {
        let label = component.label ?? component.title ?? "Continue"
        let variant = component.variant ?? "primary"
        let button = Button {
            let action = component.raw["action"]?.stringValue ?? "component_action"
            model.emit(action, payload: component.raw["payload"]?.objectValue ?? [:])
        } label: {
            Text(label).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: variant == "primary" && !WorkspaceWelcome.isExample(component) ? .infinity : nil)
        }
        .disabled(component.raw["disabled"]?.boolValue == true || component.raw["enabled"]?.boolValue == false)
        if WorkspaceWelcome.isExample(component) {
            button.buttonStyle(WelcomeExampleButtonStyle(palette: p))
        } else {
            button.buttonStyle(AstralButtonStyle(palette: p, variant: variant))
        }
    }

    private var chatHistoryView: some View {
        let items = (component.raw["items"]?.arrayValue ?? []).compactMap { ChatSummary(historyItem: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            if items.isEmpty {
                Text("No conversations yet.").foregroundStyle(p.muted)
            } else {
                HistoryHeader(title: component.raw["title"]?.stringValue ?? "Recent chats", count: items.count)
                ForEach(Array(items.enumerated()), id: \.offset) { _, chat in
                    Button {
                        model.emit("load_chat", payload: ["chat_id": .string(chat.id)])
                    } label: {
                        HistoryRow(chat: chat)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var skeletonView: some View {
        let count = max(1, min(Int(component.raw["count"]?.numberValue ?? 3), 6))
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
            Text(component.type).font(AstralTypography.caption2).foregroundStyle(p.muted.opacity(0.7))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.3), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
    }

    // MARK: shared pieces

    @ViewBuilder
    private var titleLine: some View {
        if let title = component.title, !title.isEmpty {
            HStack(spacing: 6) {
                Rectangle().fill(p.gradient).frame(width: 3, height: 16)
                markdown(title).font(AstralTypography.headline).foregroundStyle(p.text)
            }
        }
    }

    /// FR-033-style redirect: file upload lives in the chat input, so this
    /// component is informational here — never a dead button.
    private var fileUploadHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = component.label ?? component.title, !label.isEmpty {
                markdown(label).foregroundStyle(p.text)
            }
            Label(
                "Attach files with the paperclip in the chat input",
                systemImage: "paperclip"
            )
            .font(AstralTypography.caption).foregroundStyle(p.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
    }

    @ViewBuilder
    private var childViews: some View {
        CanvasComponentChildren(raw: component.raw, path: capturePath)
    }

    private func markdown(_ string: String) -> Text {
        Text(InlineMarkdown.attributed(string))
    }

    private func isTruthy(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return value.boolValue == true
            || (value.numberValue ?? 0) > 0
            || (value.stringValue?.isEmpty == false)
    }
}

// MARK: - Button style (parity with the web primary/secondary/ghost)

struct AstralButtonStyle: ButtonStyle {
    let palette: AstralPalette
    let variant: String

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(AstralTypography.callout.weight(.semibold))
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
                label.foregroundStyle(.white)
                    .background(palette.error, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .opacity(configuration.isPressed ? 0.8 : 1))
        default:
            return AnyView(
                label.foregroundStyle(.white)
                    .background(palette.gradient, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                    .opacity(configuration.isPressed ? 0.85 : 1))
        }
    }
}

// MARK: - Interactive component subviews

/// Authenticated file download (file_download / download_card). The web's
/// anchor click carries the session cookie; the native twin must fetch with
/// the Bearer token (root-relative `/api/download/...` URLs resolve against
/// the configured server) and then hand the file to the platform: a share
/// sheet on iOS/iPadOS, a save panel on macOS. Off-origin URLs (e.g. GitHub
/// release assets) are fetched without credentials.
struct DownloadComponent: View {
    let component: AstralComponent
    var automaticallyStart = false
    var workspaceExport: AppModel.WorkspaceActionContext? = nil
    var componentExport: AppModel.ComponentActionContext? = nil
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    @State private var phase = Phase.idle
    @State private var downloadTask: Task<Void, Never>?
    @State private var temporaryFile: URL?
    @State private var savePanel: NativeDownloadSaveLease?
    private var p: AstralPalette { theme.palette }

    enum Phase: Equatable {
        case idle, fetching
        case done(URL)
        case failed(String)
    }

    private var urlString: String? {
        // The unavailable variant ships download_url:"" — an empty URL is no URL.
        (component.raw["download_url"]?.stringValue ?? component.url)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
    private var filename: String? { component.raw["filename"]?.stringValue }
    private var label: String {
        component.label ?? filename ?? component.title ?? "Download"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The card's context (what this is, why it's trustworthy, which
            // platform) — web parity; the button alone says none of it.
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title))
                    .font(AstralTypography.subheadline.bold()).foregroundStyle(p.text)
            }
            if let desc = component.raw["description"]?.stringValue, !desc.isEmpty {
                Text(InlineMarkdown.attributed(desc))
                    .font(AstralTypography.caption).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let meta = [
                component.raw["version"]?.stringValue,
                component.raw["platform"]?.stringValue,
            ]
            .compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " • "))
                    .font(AstralTypography.caption2).foregroundStyle(p.muted)
            }
            switch phase {
            case .idle:
                Button {
                    download()
                } label: {
                    Label(label, systemImage: "arrow.down.circle")
                }
                .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                .disabled(urlString == nil && componentExport == nil)
                .accessibilityLabel("Download \(filename ?? label)")
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(AstralTypography.callout).foregroundStyle(p.muted)
                }
            case .done(let file):
                #if os(macOS)
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(p.success)
                        Text("Saved \(file.lastPathComponent)")
                            .font(AstralTypography.callout).foregroundStyle(p.text)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                        .font(AstralTypography.callout)
                        .tint(p.primary)
                    }
                #else
                    ShareLink(item: file) {
                        Label(
                            "Save or share \(file.lastPathComponent)",
                            systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                #endif
            case .failed(let why):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(p.warning)
                    Text(why).font(AstralTypography.caption).foregroundStyle(p.muted)
                    Button("Retry") { download() }
                        .font(AstralTypography.callout).tint(p.primary)
                }
            }
            if urlString == nil,
                let page = component.raw["html_url"]?.stringValue,
                let pageURL = URL(string: page), !page.isEmpty
            {
                Link("Open the releases page", destination: pageURL)
                    .font(AstralTypography.caption).tint(p.primary)
            }
        }
        .task {
            if automaticallyStart, case .idle = phase { download() }
        }
        .onDisappear { cancelDownload() }
        .onChange(of: model.downloadOwner) { _, _ in cancelDownload() }
        .onChange(of: model.activeChatId) { _, _ in
            if workspaceExport != nil { cancelDownload() }
        }
        .onChange(of: model.lastCommittedRenderRevision) { _, _ in
            if workspaceExport != nil { cancelDownload() }
        }
        .onChange(of: componentExport.map(model.componentActionIsCurrent) ?? true) { _, current in
            if !current { cancelDownload() }
        }

    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        let cancelledPanel = savePanel
        savePanel = nil
        cancelledPanel?.cancel()
        if let file = temporaryFile { RestClient.removeTemporaryDownload(file) }
        temporaryFile = nil
        phase = .idle
    }

    private func download() {
        guard componentExport != nil || urlString != nil else { return }
        if let componentExport, !model.componentActionIsCurrent(componentExport) { return }
        cancelDownload()
        phase = .fetching
        let owner = model.downloadOwner
        downloadTask = Task { @MainActor in
            do {
                let file: URL
                if let componentExport {
                    file = try await model.downloadComponentCSV(componentExport)
                } else if let workspaceExport {
                    file = try await model.downloadWorkspaceCanvas(workspaceExport)
                } else {
                    file = try await model.downloadArtifact(from: urlString!, suggestedFilename: filename)
                }
                guard !Task.isCancelled, model.downloadOwner == owner,
                    componentExport.map(model.componentActionIsCurrent) ?? true
                else {
                    RestClient.removeTemporaryDownload(file)
                    return
                }
                temporaryFile = file
                finish(with: file, owner: owner)
            } catch is CancellationError {} catch {
                if !Task.isCancelled, model.downloadOwner == owner,
                    componentExport.map(model.componentActionIsCurrent) ?? true
                {
                    phase = .failed("Download failed — check your connection and try again.")
                }
            }
        }
    }

    @MainActor
    private func finish(with file: URL, owner: AppModel.DownloadOwner) {
        #if os(macOS)
            let holder = NativeDownloadSaveLease(file: file)
            savePanel = holder
            let panel = holder.panel
            panel.nameFieldStringValue = file.lastPathComponent
            panel.canCreateDirectories = true
            panel.begin { response in
                defer {
                    RestClient.removeTemporaryDownload(file)
                    if savePanel === holder {
                        if temporaryFile == file { temporaryFile = nil }
                        savePanel = nil
                    }
                }
                guard savePanel === holder, temporaryFile == file, !holder.cancelled,
                    model.downloadOwner == owner,
                    workspaceExport.map(model.workspaceActionIsCurrent) ?? true,
                    componentExport.map(model.componentActionIsCurrent) ?? true
                else { return }
                if response == .OK, let destination = panel.url {
                    do {
                        if try holder.save(
                            to: destination, isCurrent: { savePanel === holder && temporaryFile == file })
                        {
                            phase = .done(destination)
                        }
                    } catch { phase = .failed("The file could not be saved.") }
                } else {
                    phase = .idle
                }
            }
        #else
            phase = .done(file)
        #endif
    }
}

@MainActor
final class NativeDownloadSaveLease {
    let file: URL
    private(set) var cancelled = false

    init(file: URL) { self.file = file }

    /// An old completion may arrive after a panel was cancelled or replaced.
    /// Check the actual presentation lifetime before any destination write.
    func save(to destination: URL, isCurrent: () -> Bool) throws -> Bool {
        guard !cancelled, isCurrent() else { return false }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= 64 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        try data.write(to: destination, options: .atomic)
        return true
    }

    func cancel() {
        cancelled = true
        #if os(macOS)
            panel.cancel(nil)
        #endif
    }

    #if os(macOS)
        let panel = NSSavePanel()
    #endif
}

/// Table with server-driven pagination (emits `table_paginate`).
struct TableComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title)).font(AstralTypography.headline).foregroundStyle(p.text)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if !component.tableHeaders.isEmpty {
                        GridRow {
                            ForEach(Array(component.tableHeaders.enumerated()), id: \.offset) { _, header in
                                Text(header).font(AstralTypography.caption.bold()).foregroundStyle(p.muted)
                            }
                        }
                        Divider().overlay(p.border)
                    }
                    ForEach(Array(component.tableRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(AstralTypography.callout).foregroundStyle(p.text)
                            }
                        }
                    }
                }
            }
            pager
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
    }

    @ViewBuilder
    private var pager: some View {
        if let total = component.raw["total_rows"]?.numberValue,
            let size = component.raw["page_size"]?.numberValue, size > 0
        {
            let offset = component.raw["page_offset"]?.numberValue ?? 0
            let start = Int(offset) + 1
            let end = min(Int(offset + size), Int(total))
            HStack {
                Button("‹ Prev") { paginate(offset: max(offset - size, 0), size: size) }
                    .disabled(offset <= 0)
                Spacer()
                Text("rows \(start)–\(end) of \(Int(total))").font(AstralTypography.caption).foregroundStyle(p.muted)
                Spacer()
                Button("Next ›") { paginate(offset: offset + size, size: size) }
                    .disabled(end >= Int(total))
            }
            .font(AstralTypography.caption)
            .tint(p.primary)
            .padding(.top, 4)
        }
    }

    private func paginate(offset: Double, size: Double) {
        guard let cid = component.componentId else { return }
        model.emit(
            "table_paginate",
            payload: [
                "component_id": .string(cid),
                "params": .object(["page_offset": .number(offset), "page_size": .number(size)]),
            ])
    }
}

/// Single-line input that submits its value through the standard event path.
struct InputComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    @State private var value = ""
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = component.label, !label.isEmpty {
                Text(label).font(AstralTypography.caption).foregroundStyle(p.muted)
            }
            HStack {
                TextField(component.raw["placeholder"]?.stringValue ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Send", action: submit).tint(p.primary)
            }
        }
        .onAppear { value = component.raw["value"]?.stringValue ?? "" }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let action = component.raw["action"]?.stringValue {
            model.emit(action, payload: ["value": .string(trimmed)])
        } else {
            model.emit("chat_message", payload: ["message": .string(trimmed)])
        }
    }
}

/// Multi-field form (param_picker) — text/boolean/select — submitting either a
/// templated chat message or a `submit_action` with `{fields:{…}}`.
struct ParamPickerComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    private var p: AstralPalette { theme.palette }

    private var fields: [JSONValue] { component.raw["fields"]?.arrayValue ?? [] }
    private var actions: [JSONValue] { component.raw["actions"]?.arrayValue ?? [] }
    private var hasLLMSave: Bool {
        component.raw["submit_action"]?.stringValue == "chrome_llm_save"
            || actions.contains { $0["action"]?.stringValue == "chrome_llm_save" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = component.title, !title.isEmpty {
                Text(InlineMarkdown.attributed(title))
                    .font(AstralTypography.headline).foregroundStyle(p.text)
                    .accessibilityIdentifier(
                        hasLLMSave ? "llm-provider-form-title" : "param-picker-form-title")
            }
            // The form's operative instructions live here (web parity).
            if let desc = component.raw["description"]?.stringValue, !desc.isEmpty {
                Text(InlineMarkdown.attributed(desc))
                    .font(AstralTypography.caption).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                fieldView(field)
            }
            if actions.isEmpty {
                let action = component.raw["submit_action"]?.stringValue
                paramButton(
                    label: component.raw["submit_label"]?.stringValue ?? "Submit",
                    action: action,
                    variant: "primary",
                    payload: component.raw["submit_payload"]?.objectValue ?? [:])
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, definition in
                        paramButton(
                            label: definition["label"]?.stringValue ?? "Submit",
                            action: definition["action"]?.stringValue,
                            variant: definition["variant"]?.stringValue ?? "secondary",
                            payload: definition["payload"]?.objectValue ?? [:])
                    }
                }
            }
            if hasLLMSave, let operation = model.llmFirstLoginOperation {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if operation.isLoading {
                        ProgressView().controlSize(.small).tint(p.primary)
                            .accessibilityHidden(true)
                    }
                    // The accessibility contract lives on the Text itself, with
                    // no `.accessibilityElement(children:)` wrapper: wrapping —
                    // even a Text — mints a generic AXGroup, and macOS AXGroups
                    // drop AXValue, so XCUIElement.value (and VoiceOver's value
                    // readout) read as empty on macOS.
                    Text(operation.presentedLabel)
                        .font(AstralTypography.caption)
                        .foregroundStyle(operation.errorCode == nil ? p.muted : p.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("llm-save-status")
                        .accessibilityLabel("AI provider setup status")
                        .accessibilityValue(operation.presentedLabel)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: AstralRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AstralRadius.lg).stroke(p.border))
    }

    @ViewBuilder
    private func fieldView(_ field: JSONValue) -> some View {
        if fieldIsVisible(field) { fieldBody(field) }
    }

    /// Server-declared conditional visibility (063): a field may carry
    /// `visible_when: {field, equals, default}` — hidden unless the named
    /// controller field's current value matches. Fields without the attribute
    /// are always visible, so servers can emit it freely for older clients.
    private func fieldIsVisible(_ field: JSONValue) -> Bool {
        guard let vw = field["visible_when"],
            let controller = vw["field"]?.stringValue,
            let expected = vw["equals"]?.stringValue
        else { return true }
        let current = values[controller] ?? vw["default"]?.stringValue ?? ""
        return current == expected
    }

    @ViewBuilder
    private func fieldBody(_ field: JSONValue) -> some View {
        let name = field["name"]?.stringValue ?? ""
        let label = field["label"]?.stringValue ?? name
        let kind = field["kind"]?.stringValue ?? field["type"]?.stringValue ?? "text"
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AstralTypography.caption).foregroundStyle(p.muted)
            switch kind {
            case "boolean", "checkbox":
                Toggle(
                    "",
                    isOn: Binding(
                        get: { flags[name] ?? (field["default"]?.boolValue ?? false) },
                        set: { flags[name] = $0 })
                )
                .labelsHidden().tint(p.primary)
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
                .accessibilityValue(
                    flags[name] ?? (field["default"]?.boolValue ?? false)
                        ? "Enabled" : "Disabled")
            case "select":
                let options =
                    field["options"]?.arrayValue?.compactMap { $0.stringValue ?? $0["value"]?.stringValue } ?? []
                Picker(
                    label,
                    selection: Binding(
                        get: { values[name] ?? options.first ?? "" },
                        set: { values[name] = $0 })
                ) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).tint(p.primary)
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
                .accessibilityValue(values[name] ?? options.first ?? "Not selected")
            case "checklist":
                let options =
                    field["options"]?.arrayValue?.compactMap { $0.stringValue ?? $0["value"]?.stringValue } ?? []
                ForEach(options, id: \.self) { option in
                    Toggle(
                        option,
                        isOn: Binding(
                            get: { flags["\(name).\(option)"] ?? false },
                            set: { flags["\(name).\(option)"] = $0 })
                    )
                    .font(AstralTypography.callout).tint(p.primary)
                    .accessibilityIdentifier("param-field-\(name)-\(option)")
                    .accessibilityLabel(option)
                    .accessibilityValue(
                        flags["\(name).\(option)"] == true ? "Selected" : "Not selected")
                }
            case "number":
                TextField(
                    field["help"]?.stringValue ?? "",
                    text: Binding(
                        get: {
                            values[name]
                                ?? (field["default"]?.stringValue
                                    ?? field["default"]?.numberValue.map { String($0) } ?? "")
                        },
                        set: { values[name] = $0 })
                )
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
            case "password":
                SecureField(
                    field["help"]?.stringValue ?? "",
                    text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
            case "textarea":
                TextEditor(
                    text: Binding(
                        get: { values[name] ?? (field["default"]?.stringValue ?? "") },
                        set: { values[name] = $0 })
                )
                .frame(minHeight: 80)
                // Param fields hold identifiers/keys (usernames, PEMs), never
                // prose — autocap/autocorrect would corrupt them (063).
                .autocorrectionDisabled(true)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
            default:
                TextField(
                    field["help"]?.stringValue ?? "",
                    text: Binding(
                        get: { values[name] ?? (field["default"]?.stringValue ?? "") },
                        set: { values[name] = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("param-field-\(name)")
                .accessibilityLabel(label)
            }
        }
    }

    @ViewBuilder
    private func paramButton(
        label: String,
        action: String?,
        variant: String,
        payload: [String: JSONValue]
    ) -> some View {
        Button(label) {
            submit(action: action, payload: payload)
        }
        .buttonStyle(AstralButtonStyle(palette: p, variant: variant))
        .disabled(
            action == "chrome_llm_save"
                && (model.llmFirstLoginOperation?.isLoading ?? false)
        )
        .accessibilityIdentifier(
            action == "chrome_llm_save" ? "llm-save-button" : "param-action-\(action ?? "message")"
        )
        .accessibilityLabel(label)
        .accessibilityValue(
            action == "chrome_llm_save" && (model.llmFirstLoginOperation?.isLoading ?? false)
                ? "Submitting"
                : "Ready")
    }

    private func submit(action: String?, payload: [String: JSONValue]) {
        var collected: [String: JSONValue] = [:]
        for field in fields {
            guard let name = field["name"]?.stringValue else { continue }
            let kind = field["kind"]?.stringValue ?? field["type"]?.stringValue ?? "text"
            if kind == "checklist" {
                let options =
                    field["options"]?.arrayValue?.compactMap { $0.stringValue ?? $0["value"]?.stringValue } ?? []
                let chosen = options.filter { flags["\(name).\($0)"] == true }
                collected[name] = .array(chosen.map { .string($0) })
            } else if let flag = flags[name] {
                collected[name] = .bool(flag)
            } else if let value = values[name] {
                collected[name] = .string(value)
            } else if let def = field["default"] {
                collected[name] = def
            }
        }
        if let action {
            _ = model.submitParamPicker(action: action, fields: collected, payload: payload)
        } else if let template = component.raw["submit_message_template"]?.stringValue {
            var message = template
            // Whole-form placeholder first (web parity: client.js substitutes
            // {__values_json__} with the full state) — the classify training
            // template relies on it; per-field {key} replacement can't fill it.
            if message.contains("{__values_json__}") {
                let json =
                    (try? JSONValue.object(collected).encoded())
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                message = message.replacingOccurrences(of: "{__values_json__}", with: json)
            }
            for (key, value) in collected {
                message = message.replacingOccurrences(of: "{\(key)}", with: value.displayText)
            }
            model.emit("chat_message", payload: ["message": .string(message)])
        }
    }
}

/// Tabs with local selection; renders the selected tab's children.
struct TabsComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) private var model
    @Environment(\.canvasCapturePath) private var capturePath
    @State private var selection = 0
    private var p: AstralPalette { theme.palette }

    private var tabs: [JSONValue] { component.raw["tabs"]?.arrayValue ?? [] }
    private var captureNode: CanvasCaptureNode? { model.canvasCapture.node(path: capturePath, component: component) }
    private func retainSelection() {
        model.canvasCapture.record(captureNode, state: .array([.number(Double(selection))]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button(tab["label"]?.stringValue ?? "Tab \(index + 1)") { selection = index }
                            .font(AstralTypography.callout.weight(selection == index ? .bold : .regular))
                            .foregroundStyle(selection == index ? p.primary : p.muted)
                    }
                }
            }
            if tabs.indices.contains(selection) {
                CanvasComponentChildren(raw: tabs[selection], path: capturePath.map { $0 + "/tabs/\(selection)" })
            }
        }
        .onAppear {
            if let retained = model.canvasCapture.state(for: captureNode)?.arrayValue?.first?.numberValue,
                retained >= 0, retained < Double(tabs.count)
            {
                selection = Int(retained)
            }
            retainSelection()
        }
        .onChange(of: selection) { _, _ in retainSelection() }
        .onChange(of: captureNode) { _, _ in retainSelection() }
    }
}

/// Collapsible disclosure (parity with web `<details>`).
struct CollapsibleComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) private var model
    @Environment(\.canvasCapturePath) private var capturePath
    @State private var expanded: Bool
    private var p: AstralPalette { theme.palette }
    private var captureNode: CanvasCaptureNode? { model.canvasCapture.node(path: capturePath, component: component) }
    private func retainExpansion() { model.canvasCapture.record(captureNode, state: .bool(expanded)) }

    init(component: AstralComponent) {
        self.component = component
        _expanded = State(initialValue: component.raw["default_open"]?.boolValue ?? false)
    }

    var body: some View {
        let welcome = WorkspaceWelcome.role(of: component) == .more
        VStack(alignment: welcome ? .center : .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(p.muted)
                    Text(InlineMarkdown.attributed(component.title?.isEmpty == false ? component.title! : "Details"))
                        .font(welcome ? AstralTypography.subheadline : AstralTypography.headline)
                        .foregroundStyle(welcome ? p.muted : p.text)
                    if !welcome { Spacer(minLength: 0) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                if welcome {
                    WelcomeExamplesLayout {
                        CanvasComponentChildren(raw: component.raw, path: capturePath)
                    }
                } else {
                    CanvasComponentChildren(raw: component.raw, path: capturePath)
                }
            }
        }
        .padding(welcome ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: welcome ? .center : .leading)
        .background(welcome ? Color.clear : p.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .astralChartBackdrop(p, color: p.surface, opacity: welcome ? 0 : 0.4)
        .onAppear {
            if let retained = model.canvasCapture.state(for: captureNode)?.boolValue { expanded = retained }
            retainExpansion()
        }
        .onChange(of: expanded) { _, _ in retainExpansion() }
        .onChange(of: captureNode) { _, _ in retainExpansion() }
    }

}

/// Color picker → live restyle + `save_theme` (feature 044 US5 parity).
struct ColorPickerComponent: View {
    let component: AstralComponent
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    private var p: AstralPalette { theme.palette }

    private let presets = ["#6366F1", "#8B5CF6", "#06B6D4", "#22C55E", "#F59E0B", "#EF4444"]

    var body: some View {
        HStack(spacing: 8) {
            Text(component.label ?? "Color").foregroundStyle(p.text)
            Spacer(minLength: 0)
            Menu {
                ForEach(presets, id: \.self) { hex in
                    Button(hex) { choose(hex) }
                }
            } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(cssHex: component.raw["value"]?.stringValue ?? "#6366F1") ?? p.primary)
                    .frame(width: 28, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            .accessibilityLabel("Choose \(component.label ?? "theme") color")
        }
    }

    private func choose(_ hex: String) {
        guard let key = component.raw["color_key"]?.stringValue else { return }
        theme.apply(spec: .object(["color_key": .string(key), "color_value": .string(hex)]))
        model.emit(
            "save_theme",
            payload: [
                "theme": .object([
                    "color_key": .string(key), "color_value": .string(hex),
                ])
            ])
    }
}

/// The native shell hosts the exact bundled web Plotly renderer in an isolated
/// ephemeral document. Server data never becomes executable HTML or authority.
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
                    .font(AstralTypography.subheadline.weight(.medium))
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
