// The remote MCP manager stores bearer credentials through the kernel and reviews exact tool definitions before approval.
// Tool use separately requires the ordinary permission grant and per-action gates.

import SwiftUI

nonisolated struct MeshRemoteMCPConfig: Sendable {
    let name: String
    let endpoint: String
    let bearer: String?
}

nonisolated struct MeshRemoteMCPServer: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let endpoint: String
    let credentialConfigured: Bool
}

nonisolated struct MeshRemoteMCPTool: Identifiable, Equatable, Sendable {
    var id: String { server + "__" + name }
    let server: String
    let endpoint: String
    let configurationRevision: String
    let name: String
    let description: String
    let inputSchemaJSON: String
    let annotationsJSON: String
    let definitionHash: String
    var status: String

    var entry: MeshToolEntry {
        let annotations = MeshToolAnnotations(json: annotationsJSON)
        return MeshToolEntry(
            name: id, summary: description,
            effect: .outsideEffect,
            deviceId: nil, annotations: annotations)
    }
}

struct MeshRemoteMCPView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var servers: [MeshRemoteMCPServer] = []
    @State private var name = ""
    @State private var endpoint = ""
    @State private var bearer = ""
    @State private var error: String?
    @State private var working = false
    @State private var removing: MeshRemoteMCPServer?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section("Configured servers") {
                if servers.isEmpty { Text("No remote MCP server is configured.").foregroundStyle(p.muted) }
                ForEach(servers) { server in
                    HStack {
                        NavigationLink {
                            MeshRemoteMCPToolsView(server: server)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.endpoint).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                                if server.credentialConfigured {
                                    Text("Credential stored on this device").font(ConsoleTypography.caption)
                                        .foregroundStyle(p.muted)
                                }
                            }
                        }
                        .accessibilityIdentifier("mesh.mcp.server.\(server.name)")
                        Button("Remove", role: .destructive) { removing = server }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("mesh.mcp.remove.\(server.name)")
                    }
                }
            }
            Section {
                TextField("Name", text: $name)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mesh.mcp.name")
                TextField("Endpoint URL", text: $endpoint)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mesh.mcp.endpoint")
                SecureField("Bearer token (optional)", text: $bearer)
                    .accessibilityIdentifier("mesh.mcp.bearer")
                Button("Save server") {
                    let config = MeshRemoteMCPConfig(
                        name: name, endpoint: endpoint, bearer: bearer.isEmpty ? nil : bearer)
                    bearer = ""
                    run {
                        try await mesh.setRemoteMCPServer(config)
                        name = ""
                        endpoint = ""
                        servers = try await mesh.remoteMCPServers()
                    }
                }
                .disabled(working || name.isEmpty || endpoint.isEmpty)
                .accessibilityIdentifier("mesh.mcp.save")
            } header: {
                Text("Add server")
            } footer: {
                Text(
                    "Use lowercase letters, digits and hyphens for the name. Saving an existing name replaces it and clears its tool approvals."
                )
            }
            if let error { Section { Text(error).foregroundStyle(p.error).accessibilityIdentifier("mesh.mcp.error") } }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Remote MCP tools")
        .task { run { servers = try await mesh.remoteMCPServers() } }
        .confirmationDialog(
            "Remove this MCP server?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            if let server = removing {
                Button("Remove \(server.name)", role: .destructive) {
                    removing = nil
                    run {
                        try await mesh.removeRemoteMCPServer(server.name)
                        servers = try await mesh.remoteMCPServers()
                    }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await work() } catch { self.error = MeshRuntime.describe(error) }
        }
    }
}

private struct MeshRemoteMCPToolsView: View {
    let server: MeshRemoteMCPServer
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var tools: [MeshRemoteMCPTool] = []
    @State private var error: String?
    @State private var working = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section {
                Text(server.endpoint).font(ConsoleTypography.footnote)
                Button("Refresh tools") { Task { await refresh() } }
                    .disabled(working)
                    .accessibilityIdentifier("mesh.mcp.refresh")
            }
            Section("Tools") {
                if tools.isEmpty { Text("No tools are available.").foregroundStyle(p.muted) }
                ForEach(tools) { tool in
                    NavigationLink {
                        MeshRemoteMCPReviewView(tool: tool)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(tool.name)
                            Text(tool.status.capitalized).font(ConsoleTypography.caption).foregroundStyle(
                                tool.status == "changed" ? p.error : p.muted)
                        }
                    }
                    .accessibilityIdentifier("mesh.mcp.tool.\(tool.name)")
                }
            }
            if let error { Section { Text(error).foregroundStyle(p.error).accessibilityIdentifier("mesh.mcp.error") } }
        }
        .formStyle(.grouped)
        .navigationTitle(server.name)
        .task { await refresh() }
    }

    private func refresh() async {
        working = true
        error = nil
        tools = []
        defer { working = false }
        do { tools = try await mesh.refreshRemoteMCPTools(server.name) } catch {
            self.error = MeshRuntime.describe(error)
        }
    }
}

private struct MeshRemoteMCPReviewView: View {
    @State var tool: MeshRemoteMCPTool
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var error: String?
    @State private var working = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section("Definition") {
                LabeledContent("Server", value: tool.server)
                Text(tool.endpoint).font(ConsoleTypography.footnote).textSelection(.enabled)
                    .accessibilityIdentifier("mesh.mcp.review.endpoint")
                Text(tool.description)
                LabeledContent("Status", value: tool.status.capitalized)
                Text(tool.definitionHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("mesh.mcp.definition-hash")
            }
            Section("Input schema") {
                Text(tool.inputSchemaJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("Annotations") {
                Text(tool.annotationsJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section {
                if tool.status == "approved" {
                    MeshToolRow(tool: tool.entry)
                    Button("Revoke definition approval", role: .destructive) {
                        run {
                            try await mesh.revokeRemoteMCPTool(server: tool.server, tool: tool.name)
                            tool.status = "new"
                        }
                    }
                    .accessibilityIdentifier("mesh.mcp.revoke")
                } else {
                    Button("Approve this definition") {
                        run {
                            try await mesh.approveRemoteMCPTool(tool)
                            tool.status = "approved"
                            await mesh.refreshTools()
                        }
                    }
                    .accessibilityIdentifier("mesh.mcp.approve")
                }
            } footer: {
                Text(
                    "Definition approval covers this exact hash. Tool permission and any action approval are checked separately."
                )
            }
            if let error { Section { Text(error).foregroundStyle(p.error).accessibilityIdentifier("mesh.mcp.error") } }
        }
        .disabled(working)
        .formStyle(.grouped)
        .navigationTitle(tool.name)
        .task { await mesh.refreshTools() }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await work() } catch { self.error = MeshRuntime.describe(error) }
        }
    }
}
