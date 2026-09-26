// Presents server-owned agent introductions with the web console's scenario rows and tool chips.
// ROTE controls the layout; AppModel validates every offered prompt before loading or dispatching it.

import AstralCore
import SwiftUI

private struct IntroContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ConsoleIntroSurfaceView: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let components: [AstralComponent]
    let presentation: ConsolePresentation
    let maximumHeight: CGFloat
    @State private var contentHeight: CGFloat = 1
    private var p: AstralPalette { theme.palette }
    private var compact: Bool { presentation.settingsPresentation == .sheet }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                    if component.raw["console_role"]?.stringValue != "surface_subtitle" {
                        row(component)
                    }
                }
            }
            .padding(compact ? 16 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: IntroContentHeight.self, value: geometry.size.height)
                })
        }
        .onPreferenceChange(IntroContentHeight.self) { contentHeight = $0 }
        .frame(height: compact ? maximumHeight : min(maximumHeight, contentHeight))
    }

    @ViewBuilder
    private func row(_ component: AstralComponent) -> some View {
        switch component.type {
        case "text":
            if component.variant == "h3" {
                Text(component.textContent ?? "").textCase(.uppercase)
                    .font(ConsoleTypography.caption.weight(.bold)).tracking(0.6).foregroundStyle(p.muted)
            } else {
                Text(component.textContent ?? "").font(ConsoleTypography.subheadline)
                    .foregroundStyle(p.text.opacity(0.75)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "badge":
            Text(component.label ?? "").font(ConsoleTypography.sans(11).weight(.medium))
                .foregroundStyle(component.variant == "success" ? p.accent : p.muted)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(p.primary.opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(p.primary.opacity(0.6)))
        case "card":
            scenario(component)
        case "list":
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(component.listItems.enumerated()), id: \.offset) { _, item in chip(item) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(component.listItems.enumerated()), id: \.offset) { _, item in chip(item) }
                }
            }
        case "button":
            offeredButton(component)
        default:
            ComponentView(component: component)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(ConsoleTypography.caption).foregroundStyle(p.text.opacity(0.75))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().stroke(p.border))
    }

    private func scenario(_ component: AstralComponent) -> some View {
        let copy = VStack(alignment: .leading, spacing: 4) {
            Text(component.title ?? "").font(ConsoleTypography.subheadline.weight(.semibold)).foregroundStyle(p.text)
            ForEach(Array(component.children.filter { $0.type == "text" }.enumerated()), id: \.offset) { _, text in
                Text(text.textContent ?? "").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let actions = HStack(spacing: 6) {
            ForEach(Array(component.children.flatMap(\.children).enumerated()), id: \.offset) { _, action in
                offeredButton(action, scenario: component.title)
            }
        }
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    copy
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        copy.frame(maxWidth: .infinity, alignment: .leading)
                        actions.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        copy
                        actions
                    }
                }
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    @ViewBuilder
    private func offeredButton(_ component: AstralComponent, scenario: String? = nil) -> some View {
        if component.type == "button", let action = component.raw["action"]?.stringValue {
            Button(component.label ?? "") {
                model.sendEvent(action, component.raw["payload"] ?? .object([:]))
            }
            .buttonStyle(
                ConsoleButtonStyle(
                    primary: component.variant == "primary", minimumHeight: presentation.minimumControlHeight)
            )
            .disabled(component.raw["disabled"]?.boolValue == true || !model.connected)
            .accessibilityLabel([component.label, scenario].compactMap { $0 }.joined(separator: ": "))
        }
    }
}
