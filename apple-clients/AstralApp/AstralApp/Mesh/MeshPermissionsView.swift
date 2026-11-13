// The tool permissions screen: the tools on this device and on other devices, each showing whether the assistant may use it and one action to change that.
// Granting draws the biometric consent sheet through the kernel's host signer, while revoking takes effect at once and asks for nothing.

import SwiftUI

struct MeshPermissionsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    private var local: [MeshToolEntry] { mesh.toolEntries.filter { $0.deviceId == nil } }
    private var remoteByDevice: [(deviceId: String, tools: [MeshToolEntry])] {
        let remote = mesh.toolEntries.filter { $0.deviceId != nil }
        return Dictionary(grouping: remote, by: { $0.deviceId ?? "" }).map { ($0.key, $0.value) }
            .sorted { mesh.memberLabel($0.0) < mesh.memberLabel($1.0) }
    }

    var body: some View {
        Form {
            Section {
                if local.isEmpty {
                    Text("This device offers no tools.").foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.permissions.none")
                }
                ForEach(local) { MeshToolRow(tool: $0) }
            } header: {
                Text("This device")
            } footer: {
                Text("A granted tool runs without asking each time. Granting asks for your approval. Revoking does not.")
            }
            if remoteByDevice.isEmpty {
                Section("Other devices") {
                    Text("No other device offers tools yet.").foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.permissions.remote.none")
                }
            }
            ForEach(remoteByDevice, id: \.deviceId) { group in
                Section(mesh.memberLabel(group.deviceId)) {
                    ForEach(group.tools) { MeshToolRow(tool: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(p.bg)
        .navigationTitle("Tool permissions")
        .task { await mesh.refreshTools() }
    }
}

struct MeshToolRow: View {
    let tool: MeshToolEntry
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var working = false
    private var p: AstralPalette { theme.palette }

    private var granted: Bool { mesh.isGranted(tool) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MeshPresentation.toolTitle(tool)).font(ConsoleTypography.headline)
                Text(tool.name).font(.system(.caption, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                Text(tool.summary).font(ConsoleTypography.subheadline).foregroundStyle(p.muted)
                Text(detail).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(ConsoleTypography.footnote).foregroundStyle(p.success)
                        .accessibilityIdentifier("mesh.tool.granted.\(tool.id)")
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.tool.\(tool.id)")
    }

    private var detail: String {
        var text = MeshPresentation.toolEffect(tool)
        if let by = mesh.grant(for: tool)?.grantedBy { text += " Granted by " + mesh.memberLabel(by) }
        return text
    }

    @ViewBuilder
    private var action: some View {
        if granted {
            Button("Revoke", role: .destructive) { run { await mesh.revoke(tool) } }
                .meshBordered()
                .accessibilityIdentifier("mesh.tool.revoke.\(tool.id)")
        } else {
            Button("Grant") { run { await mesh.grant(tool) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mesh.tool.grant.\(tool.id)")
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !working else { return }
        working = true
        Task {
            await work()
            working = false
        }
    }
}
