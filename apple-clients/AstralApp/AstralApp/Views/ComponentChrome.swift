import AstralCore
// Top-level provenance and component actions use the server-owned 088 chrome.
// Nested children remain bare components; action descriptors grant no authority.
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct ComponentActionTarget: Identifiable, Equatable {
    let context: AppModel.ComponentActionContext
    var id: UUID { context.id }
    var title: String { context.component.title ?? "" }
}

/// A server-owned action row on top-level canvas components. Nested component
/// renderers remain bare; client inference cannot add a missing descriptor.
struct ComponentChrome: View {
    let component: AstralComponent
    var onAction: ((ComponentActionTarget) -> Void)?
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ComponentView(component: component)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProvenanceBadge(kind: component.raw["provenance"]?.stringValue)
            if onAction != nil {
                AstralToolbarLayout(wraps: true, spacing: 12) {
                    ForEach(ComponentChromeModel.actions(from: component.raw["component_chrome"])) { descriptor in
                        if let context = model.componentActionContext(for: descriptor.kind, component: component) {
                            Button {
                                // Capture again at the actual tap, not an earlier body evaluation.
                                if let current = model.componentActionContext(
                                    for: descriptor.kind, component: component)
                                {
                                    onAction?(ComponentActionTarget(context: current))
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if model.componentActionInFlight(context) {
                                        ProgressView().controlSize(.mini).accessibilityLabel(
                                            "Submitting component action")
                                    }
                                    Text(descriptor.icon).accessibilityHidden(true)
                                    Text(descriptor.label)
                                }
                                .font(AstralTypography.sans(10, relativeTo: .caption2))
                                .foregroundStyle(theme.palette.muted.opacity(0.7))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.componentActionInFlight(context))
                            .help(descriptor.title)
                            .accessibilityLabel(descriptor.label)
                            .accessibilityHint(descriptor.title)
                            .accessibilityIdentifier(
                                "component-action-\(context.componentId)-\(descriptor.kind.rawValue)")
                        }
                    }
                }
            }
        }
    }
}

struct ComponentActionSheet: View {
    let target: ComponentActionTarget
    var body: some View {
        switch target.context.action {
        case .refine: RefineSheet(target: target)
        case .history: ComponentHistorySheet(target: target)
        case .csv:
            ExportDownloadSheet(url: nil, filename: "astraldeep-table.csv", componentExport: target.context)
        case .share: ComponentShareSheet(target: target)
        }
    }
}

/// Compact trust mark under the component (web `_provenance_footer` parity:
/// same icons/labels, trailing-aligned). Unknown or absent values render
/// nothing — the server stamps exactly grounded|estimated|generated.
struct ProvenanceBadge: View {
    let kind: String?
    @Environment(ThemeStore.self) var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        if let (icon, label, color) = style {
            HStack(spacing: 4) {
                Text(icon)
                Text(label)
            }
            .font(AstralTypography.sans(10, relativeTo: .caption2))
            .foregroundStyle(color.opacity(0.7))
            .accessibilityLabel("Provenance: \(label)")
        }
    }

    private var style: (String, String, Color)? {
        switch kind {
        case "grounded": return nil
        case "estimated": return ("≈", "estimated", p.warning)
        case "generated": return ("✦", "AI-generated", p.muted)
        default: return nil
        }
    }
}

/// Small instruction-entry sheet backing the server-described Refine action.
struct RefineSheet: View {
    let target: ComponentActionTarget
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @FocusState private var instructionFocused: Bool
    private var p: AstralPalette { theme.palette }

    private var trimmed: String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title.isEmpty ? "Refine this component" : "Refine \(target.title)")
                .font(AstralTypography.headline).foregroundStyle(p.text)
            Text("Describe the change. The component updates in place — earlier versions stay restorable.")
                .font(AstralTypography.caption).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. sort by total, highest first", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($instructionFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                Button("Refine") { submit() }
                    .buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        #if os(macOS)
            .frame(minWidth: 380)
        #endif
        .presentationDetents([.medium])
        .background(p.bg)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        guard model.componentActionIsCurrent(target.context) else {
            close()
            return
        }
        instructionFocused = false  // Resign before model-driven canvas updates, like the chat composer.
        model.refineComponent(target.context, instruction: trimmed)
        dismiss()
    }

    private func close() {
        // Retire the field's keyboard focus before removing the sheet over the
        // lazy canvas. Keeping it focused during dismissal can stall layout.
        instructionFocused = false
        dismiss()
    }
}

/// Exports use the authenticated download facade already used by generated
/// files. A system browser cannot inherit this app's bearer session.
struct ExportDownloadSheet: View {
    let url: URL?
    let filename: String
    var workspaceExport: AppModel.WorkspaceActionContext? = nil
    var componentExport: AppModel.ComponentActionContext? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DownloadComponent(
                component: AstralComponent(
                    type: "file_download",
                    raw: .object([
                        "type": .string("file_download"), "download_url": .string(url?.absoluteString ?? ""),
                        "filename": .string(filename), "label": .string("Export"),
                    ])), automaticallyStart: true, workspaceExport: workspaceExport, componentExport: componentExport
            )
            .padding(24)
            .frame(minWidth: 280, minHeight: 150)
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Restorable metadata, in the same order and plain-text form as the web popover.
private struct ComponentHistorySheet: View {
    let target: ComponentActionTarget
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let versions = ComponentChromeModel.versions(from: target.context.component.raw["versions"])
                    if versions.isEmpty {
                        Text(ComponentChromeModel.emptyHistory)
                            .font(AstralTypography.caption).foregroundStyle(theme.palette.muted)
                    }
                    ForEach(versions) { version in
                        Button {
                            guard model.componentActionIsCurrent(target.context) else {
                                dismiss()
                                return
                            }
                            model.restoreComponent(target.context, version: version.number)
                            dismiss()
                        } label: {
                            Text(version.displayTitle)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(version.restoreHint)
                        .accessibilityHint(version.restoreHint)
                        .accessibilityIdentifier("component-restore-\(version.number)")
                    }
                }.padding(20)
            }
            .foregroundStyle(theme.palette.text)
            .background(theme.palette.bg)
            .navigationTitle("Version history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The minted capability stays private until the user explicitly chooses Copy
/// or Share. Cancelling or changing the initiating context clears the sheet.
private struct ComponentShareSheet: View {
    let target: ComponentActionTarget
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let url, model.componentActionIsCurrent(target.context) {
                    Text(url.absoluteString).font(AstralTypography.caption).textSelection(.enabled)
                    HStack {
                        Button(copied ? "Copied" : "Copy link") {
                            guard model.componentActionIsCurrent(target.context) else {
                                dismiss()
                                return
                            }
                            #if os(macOS)
                                NSPasteboard.general.clearContents()
                                copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            #else
                                UIPasteboard.general.string = url.absoluteString
                                copied = true
                            #endif
                        }
                        .buttonStyle(AstralButtonStyle(palette: theme.palette, variant: "secondary"))
                        ShareLink(item: url) { Text("Share link") }
                            .buttonStyle(AstralButtonStyle(palette: theme.palette, variant: "primary"))
                    }
                } else if let failure {
                    Text(failure).font(AstralTypography.callout)
                } else {
                    ProgressView("Creating share link…")
                }
            }
            .padding(20)
            .frame(minWidth: 280, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(theme.palette.text)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Share component")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationBackground(theme.palette.bg)
        .task {
            do {
                let result = try await model.shareComponent(target.context)
                guard !Task.isCancelled, model.componentActionIsCurrent(target.context) else { return }
                url = result
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, model.componentActionIsCurrent(target.context) else { return }
                failure =
                    error as? WorkspaceShareError == .phiBlocked
                    ? "Sharing refused: the content matched the PHI gate." : "Couldn't create the share link."
            }
        }
        .onDisappear {
            url = nil
            failure = nil
            copied = false
        }
    }
}
