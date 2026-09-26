// Compact watch renderers for the server's ROTE-degraded component set, falling back to readable text for
// anything else so the wrist view never renders blank; used by WatchChatView, WatchHomeView, and
// WatchGuidanceSurfaceView.

import AstralCore
import SwiftUI

struct WatchComponentView: View {
    let component: AstralComponent
    var workRead = false
    var guidance = false
    var consoleSurface = false
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
                        WatchComponentView(
                            component: child, workRead: workRead, guidance: guidance, consoleSurface: consoleSurface)
                    }
                }
            }
            .font(ConsoleTypography.footnote)
        } else if WorkspaceWelcome.role(of: component) == .intro {
            markdown(component.fallbackText)
                .font(ConsoleTypography.title3.weight(.medium))
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
            let content = component.textContent ?? component.fallbackText
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else if component.variant == "caption" {
                markdown(content)
                    .font(ConsoleTypography.caption2)
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
                        markdown(title).font(ConsoleTypography.footnote.bold())
                    }
                    markdown(component.message ?? component.fallbackText)
                        .font(ConsoleTypography.footnote)
                }
            }
            .foregroundStyle(alertColor)
        case "metric":
            VStack(alignment: .leading, spacing: 0) {
                markdown(component.title ?? component.label ?? "")
                    .font(ConsoleTypography.caption2)
                    .foregroundStyle(.secondary)
                Text(component.value ?? "—")
                    .font(ConsoleTypography.title3.bold())
                    .minimumScaleFactor(0.6)
                if let sub = component.raw["subtitle"]?.stringValue, !sub.isEmpty {
                    markdown(sub).font(ConsoleTypography.caption2).foregroundStyle(.secondary)
                }
            }
        case "badge":
            Text(component.label ?? component.fallbackText)
                .font(ConsoleTypography.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.3), in: Capsule())
        case "list":
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                ForEach(Array(WatchComponentText.listItems(in: component).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        markdown(item)
                    }
                    .font(ConsoleTypography.footnote)
                }
            }
        case "keyvalue":
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                ForEach(Array(WatchComponentText.keyValueRows(in: component).enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .top) {
                            Text(pair.label).font(ConsoleTypography.caption2).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(pair.value).font(ConsoleTypography.footnote)
                        }
                        if !pair.hint.isEmpty {
                            markdown(pair.hint).font(ConsoleTypography.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case "skeleton":
            ProgressView(component.label ?? "Loading…")
        case "progress":
            VStack(alignment: .leading, spacing: 2) {
                if let label = component.label ?? component.title, !label.isEmpty {
                    HStack {
                        markdown(label).font(ConsoleTypography.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if component.raw["show_percentage"]?.boolValue != false {
                            Text("\(Int((progressFraction * 100).rounded()))%")
                                .font(ConsoleTypography.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ProgressView(value: progressFraction)
            }
        case "card", "container", "grid", "collapsible":
            if component.title?.isEmpty != false && component.children.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    ForEach(Array(component.children.enumerated()), id: \.offset) { _, child in
                        WatchComponentView(
                            component: child, workRead: workRead, guidance: guidance, consoleSurface: consoleSurface)
                    }
                }
                .padding(6)
                .background(model.theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        case "divider":
            Divider()
        case "button":
            if consoleSurface, model.consoleSurface?.permits(component) == true {
                Button(component.label ?? "") { model.sendConsoleComponent(component) }
                    .buttonStyle(.bordered)
                    .disabled(!model.connected)
                    .frame(minHeight: model.consolePresentation?.minimumControlHeight ?? 44)
            } else if guidance, let action = component.raw["action"]?.stringValue,
                let payload = component.raw["payload"],
                let request = GuidanceRequest(action: action, payload: payload)
            {
                Button {
                    _ = model.sendGuidanceRequest(action: request.action, payload: request.payload)
                } label: {
                    Text(verbatim: component.label ?? "")
                }
                .buttonStyle(.bordered)
                .disabled(component.raw["disabled"]?.boolValue != false || !model.connected)
                .accessibilityLabel(component.label ?? "")
            } else if workRead, let payload = component.raw["payload"], WorkReadRequest(payload: payload) != nil {
                Button(component.label ?? "") { model.sendWorkComponent(component) }
                    .buttonStyle(.bordered)
                    .disabled(component.raw["disabled"]?.boolValue != false || !model.connected)
                    .accessibilityLabel(component.label ?? "")
            } else if WorkspaceWelcome.chatMessage(of: component) != nil {
                Button(component.label ?? component.fallbackText) {
                    model.sendWelcomeExample(component)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(component.raw["aria-label"]?.stringValue ?? component.label ?? "Run example")
            } else {
                handoff
            }
        case "param_picker":
            if guidance, let form = GuidanceForm(component: component) {
                WatchGuidanceFormView(form: form)
            } else {
                handoff
            }
        case "input", "file_upload", "color_picker":
            handoff
        default:
            VStack(alignment: .leading, spacing: 2) {
                markdown(component.fallbackText)
                    .font(ConsoleTypography.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(component.type)
                    .font(ConsoleTypography.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.label ?? component.title ?? component.fallbackText)
                .font(ConsoleTypography.footnote).foregroundStyle(.secondary)
            Label("Continue on your phone or desktop", systemImage: "iphone.and.arrow.forward")
                .font(ConsoleTypography.caption2).foregroundStyle(.tint)
        }
    }

    private func markdown(_ string: String) -> Text {
        (workRead || guidance || consoleSurface)
            ? Text(verbatim: string) : Text(InlineMarkdown.attributed(MarkdownBlocks.plainText(string)))
    }

    @ViewBuilder
    private var titleLine: some View {
        if let title = component.title, !title.isEmpty {
            markdown(title).font(ConsoleTypography.caption.bold())
        }
    }

    private func fontForTextVariant(_ variant: String?) -> Font {
        switch variant {
        case "h1", "h2": return ConsoleTypography.headline
        case "h3": return ConsoleTypography.subheadline.weight(.semibold)
        default: return ConsoleTypography.footnote
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
        case "error", "danger": return model.theme.palette.error
        case "warning": return model.theme.palette.warning
        default: return .primary
        }
    }

    private var progressFraction: Double {
        // Value is 0 to 1; also tolerate legacy 0 to 100
        let value = component.raw["value"]?.numberValue ?? 0
        return value > 1 ? min(value / 100, 1) : min(max(value, 0), 1)
    }
}
