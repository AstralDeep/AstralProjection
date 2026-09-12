import AstralCore
// Feature 055 (US4/US5) — chrome for one TOP-LEVEL canvas component:
// the provenance badge (T036, wire-contract §6: render the server-stamped
// `provenance` field, distinct per value, absent = nothing — web footer
// parity) and the context menu carrying the refine affordance (T040 →
// `component_refine` ui_event via a small text sheet) plus the CSV export
// entry for tables (T045, opened in the system browser). Nested children
// keep rendering bare ComponentViews; chrome never recurses.
import SwiftUI

struct RefineTarget: Identifiable, Equatable {
    let componentId: String
    let title: String
    var id: String { componentId }
}

struct ComponentChrome: View {
    let component: AstralComponent
    /// False while viewing a timeline snapshot — the badge still renders
    /// (read-only trust mark) but mutating affordances are withheld.
    var interactive: Bool = true
    var onRefine: ((RefineTarget) -> Void)?
    @Environment(ThemeStore.self) var theme
    @Environment(AppModel.self) var model
    @State private var showingExport = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // A bare long-press/right-click gesture on menu-less components
            // would still fire the preview — attach only when entries exist.
            if hasMenu {
                baseComponent.contextMenu { menuEntries }
            } else {
                baseComponent
            }
            ProvenanceBadge(kind: component.raw["provenance"]?.stringValue)
        }
        .sheet(isPresented: $showingExport) {
            if let url = csvExportURL {
                ExportDownloadSheet(url: url, filename: "astraldeep-table.csv")
            }
        }
    }

    private var baseComponent: some View {
        ComponentView(component: component)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Refinable = carries a persistent workspace identity. `wel_` welcome
    /// components are ephemeral by contract (never persisted) — no affordance.
    private var refinableId: String? {
        guard let cid = component.componentId, !cid.isEmpty,
            !cid.hasPrefix("wel_")
        else { return nil }
        return cid
    }

    // CSV export is a table-only route (422 otherwise) — offer it only where
    // it can succeed.
    private var csvExportURL: URL? {
        guard component.type == "table", let cid = refinableId else { return nil }
        return model.exportComponentURL(cid)
    }

    private var hasMenu: Bool {
        interactive && !model.mutationsLocked && ((refinableId != nil && onRefine != nil) || csvExportURL != nil)
    }

    @ViewBuilder
    private var menuEntries: some View {
        if let cid = refinableId, let onRefine {
            Button {
                onRefine(RefineTarget(componentId: cid, title: component.title ?? ""))
            } label: {
                Label("Refine…", systemImage: "wand.and.stars")
            }
        }
        if csvExportURL != nil {
            Button {
                showingExport = true
            } label: {
                Label("Export as CSV", systemImage: "square.and.arrow.up")
            }
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
            HStack(spacing: 3) {
                Text(icon)
                Text(label)
            }
            .font(AstralTypography.caption2)
            .foregroundStyle(color.opacity(0.75))
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

/// Small instruction-entry sheet backing the "Refine…" context-menu item.
struct RefineSheet: View {
    let target: RefineTarget
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
        instructionFocused = false  // Resign before model-driven canvas updates, like the chat composer.
        model.refineComponent(target.componentId, instruction: trimmed)
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
    let url: URL
    let filename: String
    var workspaceExport: AppModel.WorkspaceActionContext? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DownloadComponent(
                component: AstralComponent(
                    type: "file_download",
                    raw: .object([
                        "type": .string("file_download"), "download_url": .string(url.absoluteString),
                        "filename": .string(filename), "label": .string("Export"),
                    ])), automaticallyStart: true, workspaceExport: workspaceExport
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
