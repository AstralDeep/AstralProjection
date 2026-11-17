// The sheet where the owner mints one caller ticket: a node, a label, the caller's holder line, a lifetime and the tools it may call.
// It binds MeshCallerTicketModel, and the presence prompt that signs the ticket belongs to the Kernel.

import SwiftUI

struct MeshCallerTicketEditor: View {
    @State private var model: MeshCallerTicketModel
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    init(runtime: MeshRuntime) { _model = State(initialValue: MeshCallerTicketModel(runtime: runtime)) }

    var body: some View {
        NavigationStack {
            Group {
                if case .minted(let ticket) = model.phase {
                    MeshCallerMintedForm(ticket: ticket) { dismiss() }
                } else {
                    MeshCallerEditForm(model: model)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(p.bg)
            .navigationTitle("New Caller Ticket")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("mesh.caller.editor.close")
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

private struct MeshCallerEditForm: View {
    let model: MeshCallerTicketModel
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            MeshCallerNodeSection(model: model)
            Section {
                @Bindable var bound = model
                TextField("Label", text: $bound.label)
                    .accessibilityIdentifier("mesh.caller.editor.label")
                TextField(
                    "Holder line",
                    text: Binding(get: { model.holderLine }, set: { model.updateHolder($0) }), axis: .vertical
                )
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .accessibilityIdentifier("mesh.caller.editor.holder")
                if let notice = model.holderNotice {
                    Text(notice).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                        .accessibilityIdentifier("mesh.caller.editor.holder.notice")
                }
                Picker("Lasts", selection: $bound.lifetime) {
                    ForEach(MeshCallerLifetime.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("mesh.caller.editor.lifetime")
            } header: {
                Text("Caller")
            } footer: {
                Text("Paste the holder line from the caller. Never paste its private key.")
            }
            MeshCallerToolsSection(model: model)
            MeshCallerMintSection(model: model)
        }
    }
}

private struct MeshCallerNodeSection: View {
    let model: MeshCallerTicketModel

    var body: some View {
        Section("Node") {
            if model.nodes.isEmpty {
                Text("No node in your mesh yet.").accessibilityIdentifier("mesh.caller.editor.nonode")
            } else {
                Picker(
                    "Node",
                    selection: Binding(
                        get: { model.nodeId ?? "" }, set: { model.selectNode($0) })
                ) {
                    ForEach(model.nodes) { Text($0.label).tag($0.memberId) }
                }
                .accessibilityIdentifier("mesh.caller.editor.node")
            }
        }
    }
}

private struct MeshCallerToolsSection: View {
    let model: MeshCallerTicketModel
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        @Bindable var bound = model
        Section {
            if model.catalog.isEmpty {
                Text("This node has not published its tools yet.").foregroundStyle(p.muted)
                    .accessibilityIdentifier("mesh.caller.editor.notools")
            }
            ForEach(model.catalog, id: \.self) { name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: { model.chosenTools.contains(name) }, set: { model.setTool(name, chosen: $0) })
                )
                .accessibilityIdentifier("mesh.caller.editor.tool.\(name)")
            }
            Toggle("Send A2A messages", isOn: $bound.a2a)
                .accessibilityIdentifier("mesh.caller.editor.a2a")
        } header: {
            Text("Tools")
        } footer: {
            Text("Choose at least one.")
        }
    }
}

private struct MeshCallerMintSection: View {
    let model: MeshCallerTicketModel
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Section {
            if case .failed(let text) = model.phase {
                Text(text).foregroundStyle(p.error).accessibilityIdentifier("mesh.caller.editor.failure")
            }
            Button {
                Task { await model.mint() }
            } label: {
                if model.phase == .minting { ProgressView() } else { Text("Create Ticket") }
            }
            .disabled(!model.canMint)
            .accessibilityIdentifier("mesh.caller.editor.mint")
        }
    }
}

private struct MeshCallerMintedForm: View {
    let ticket: MeshCallerTicket
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(ticket.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("mesh.caller.minted.text")
                Button(copied ? "Copied" : "Copy Ticket") { copied = ComponentPasteboard.copy(ticket.text) }
                    .accessibilityIdentifier("mesh.caller.minted.copy")
            } header: {
                Text(ticket.label)
            } footer: {
                Text("Give this ticket to the caller. It does nothing without the caller's key.")
            }
            Section { Button("Done", action: done).accessibilityIdentifier("mesh.caller.minted.done") }
        }
    }
}
