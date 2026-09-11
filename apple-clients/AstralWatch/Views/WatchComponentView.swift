import AstralCore
// Feature 051 US5 — compact watch renderers for the profile's native set,
// readable-text fallback for everything else, and the "continue on another
// device" affordance for over-budget interactivity (FR-032/FR-033).
// The SERVER already degraded this payload via the watch ROTE profile; this
// view is the last line of defense — it must never render blank.
import SwiftUI

struct WatchComponentView: View {
    let component: AstralComponent
    @Environment(WatchModel.self) var model
    @State private var expanded = false

    var body: some View {
        if WorkspaceWelcome.role(of: component) == .more {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Label(component.title ?? "More examples", systemImage: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    ForEach(Array(component.children.enumerated()), id: \.offset) { _, child in
                        WatchComponentView(component: child)
                    }
                }
            }
            .font(AstralTypography.footnote)
        } else if WorkspaceWelcome.role(of: component) == .intro {
            markdown(component.fallbackText)
                .font(AstralTypography.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            rendered
        }
    }

    @ViewBuilder
    private var rendered: some View {
        switch component.type {
        case "text":
            // ROTE can degrade an image to an empty text node — never a blank row.
            let content = component.textContent ?? component.fallbackText
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else if component.variant == "caption" {
                markdown(content)
                    .font(AstralTypography.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                markdown(content)
                    .font(fontForTextVariant(component.variant))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "alert":
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: iconForVariant)
                VStack(alignment: .leading, spacing: 1) {
                    if let title = component.title, !title.isEmpty {
                        markdown(title).font(AstralTypography.footnote.bold())
                    }
                    markdown(component.message ?? component.fallbackText)
                        .font(AstralTypography.footnote)
                }
            }
            .foregroundStyle(alertColor)
        case "metric":
            VStack(alignment: .leading, spacing: 0) {
                markdown(component.title ?? component.label ?? "")
                    .font(AstralTypography.caption2)
                    .foregroundStyle(.secondary)
                Text(component.value ?? "—")
                    .font(AstralTypography.title3.bold())
                    .minimumScaleFactor(0.6)
                // Carries the server's "(chart condensed for watch)" note and
                // any agent-authored context — dropping it left a bare number.
                if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                    markdown(sub).font(AstralTypography.caption2).foregroundStyle(.secondary)
                }
            }
        case "badge":
            Text(component.label ?? component.fallbackText)
                .font(AstralTypography.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.3), in: Capsule())
        case "list":
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                ForEach(Array(component.listItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        markdown(item)
                    }
                    .font(AstralTypography.footnote)
                }
            }
        case "keyvalue":
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                ForEach(Array(component.keyValuePairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top) {
                        Text(pair.0).font(AstralTypography.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(pair.1).font(AstralTypography.footnote)
                    }
                }
            }
        case "progress":
            VStack(alignment: .leading, spacing: 2) {
                // The wire caption field is `label` (progress has no `title`).
                if let label = component.label ?? component.title, !label.isEmpty {
                    HStack {
                        markdown(label).font(AstralTypography.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if component.raw["show_percentage"]?.boolValue != false {
                            Text("\(Int((progressFraction * 100).rounded()))%")
                                .font(AstralTypography.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ProgressView(value: progressFraction)
            }
        case "card", "container", "grid", "collapsible":
            // A childless untitled container (grid collapse can produce one)
            // must not draw an empty gray lozenge.
            if component.title?.isEmpty != false && component.children.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    ForEach(Array(component.children.enumerated()), id: \.offset) { _, child in
                        WatchComponentView(component: child)
                    }
                }
                .padding(6)
                .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        case "divider":
            Divider()
        case "button":
            if WorkspaceWelcome.chatMessage(of: component) != nil {
                Button(component.label ?? component.fallbackText) {
                    model.sendWelcomeExample(component)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(component.raw["aria-label"]?.stringValue ?? component.label ?? "Run example")
            } else {
                handoff
            }
        case "input", "file_upload", "color_picker", "param_picker":
            handoff
        default:
            // Deterministic fallback chain terminates in readable text —
            // zero blank canvases (FR-032).
            VStack(alignment: .leading, spacing: 2) {
                markdown(component.fallbackText)
                    .font(AstralTypography.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(component.type)
                    .font(AstralTypography.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.label ?? component.title ?? component.fallbackText)
                .font(AstralTypography.footnote).foregroundStyle(.secondary)
            Label("Continue on your phone or desktop", systemImage: "iphone.and.arrow.forward")
                .font(AstralTypography.caption2).foregroundStyle(.tint)
        }
    }

    /// Wire text is markdown (parity with the phone/desktop renderers):
    /// flatten block structure to plain lines, then parse inline spans — the
    /// wrist shows neither literal asterisks nor literal `##`/fence syntax.
    private func markdown(_ string: String) -> Text {
        Text(InlineMarkdown.attributed(MarkdownBlocks.plainText(string)))
    }

    @ViewBuilder
    private var titleLine: some View {
        if let title = component.title, !title.isEmpty {
            markdown(title).font(AstralTypography.caption.bold())
        }
    }

    private func fontForTextVariant(_ variant: String?) -> Font {
        switch variant {
        case "h1", "h2": return AstralTypography.headline
        case "h3": return AstralTypography.subheadline.weight(.semibold)
        default: return AstralTypography.footnote
        }
    }

    private var iconForVariant: String {
        switch component.variant {
        case "error": return "xmark.octagon"
        case "warning": return "exclamationmark.triangle"
        case "success": return "checkmark.circle"
        default: return "info.circle"
        }
    }

    private var alertColor: Color {
        switch component.variant {
        case "error", "danger": return WatchBrand.error
        case "warning": return WatchBrand.warning
        default: return .primary
        }
    }

    private var progressFraction: Double {
        // Wire value is a 0–1 fraction; tolerate 0–100 (mirrors the iOS
        // renderer — treating everything as percent renders ~0% bars).
        let value = component.raw["value"]?.numberValue ?? 0
        return value > 1 ? min(value / 100, 1) : min(max(value, 0), 1)
    }
}
