// The tool permissions screen: the tools on this device and on other members with Grant and Revoke for the assistant.
// Granting draws the biometric consent sheet through the kernel's host signer, while revoking takes effect at once and asks for nothing.

import SwiftUI

struct MeshPermissionsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    private var local: [MeshToolEntry] { mesh.toolEntries.filter { $0.deviceId == nil } }
    private var remote: [MeshToolEntry] { mesh.toolEntries.filter { $0.deviceId != nil } }

    var body: some View {
        List {
            Section("On this device") {
                if local.isEmpty {
                    Text("This device offers no tools.").foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.permissions.none")
                }
                ForEach(local) { MeshToolRow(tool: $0, device: nil) }
            }
            Section {
                if remote.isEmpty {
                    Text("No other device offers tools yet.").foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.permissions.remote.none")
                }
                ForEach(remote) { MeshToolRow(tool: $0, device: mesh.memberLabel($0.deviceId)) }
            } header: {
                Text("On other devices")
            } footer: {
                Text("A grant lets the assistant use the tool without asking each time. The list shows the grants made on this device.")
            }
        }
        .navigationTitle("Tool permissions")
        .task { await mesh.refreshTools() }
    }
}

struct MeshToolRow: View {
    let tool: MeshToolEntry
    let device: String?
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                Spacer()
                if mesh.isGranted(tool) {
                    Label("Granted here", systemImage: "checkmark.circle.fill")
                        .font(ConsoleTypography.caption).foregroundStyle(p.success)
                        .accessibilityIdentifier("mesh.tool.granted.\(tool.id)")
                }
            }
            Text(tool.summary).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            Text("Can " + MeshToolScope.description(tool.scope) + (device.map { ". Runs on " + $0 } ?? ""))
                .font(ConsoleTypography.caption).foregroundStyle(p.muted)
            HStack {
                Button("Grant") { Task { await mesh.grant(tool) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.tool.grant.\(tool.id)")
                Button("Revoke", role: .destructive) { Task { await mesh.revoke(tool) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.tool.revoke.\(tool.id)")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.tool.\(tool.id)")
    }
}
