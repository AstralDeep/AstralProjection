// Settings for mesh mode: the model provider form, the allowance for this device, the mailbox address, tool permissions, the mesh identity and the switch back to a node.
// The provider key is passed once to the kernel's sealed store and is never kept in this view's state after saving.

import SwiftUI

struct MeshSettingsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModeStore.self) private var modeStore
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var theme
    @State private var confirmingNode = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var copied = false
    private var p: AstralPalette { theme.palette }

    private var thisDevice: MeshMember? { mesh.members.first(where: \.isThisDevice) }

    var body: some View {
        Form {
            Section("This device") {
                if let device = thisDevice {
                    LabeledContent("Name") {
                        HStack {
                            Text(device.label)
                            Button("Rename") {
                                draft = device.label
                                renaming = true
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("mesh.settings.rename")
                        }
                    }
                }
                Button {
                    model.onDeviceVoice.showingSetup = true
                } label: {
                    LabeledContent {
                        Text(voiceStatus).foregroundStyle(p.muted)
                    } label: {
                        Label("Voice", systemImage: "waveform")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mesh.settings.voice")
            }
            Section("Assistant") {
                NavigationLink { MeshModelProviderView() } label: {
                    Label("Model provider", systemImage: "sparkles")
                }
                .accessibilityIdentifier("mesh.settings.models")
                NavigationLink { MeshPermissionsView() } label: {
                    Label("Tool permissions", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("mesh.settings.permissions")
                NavigationLink { MeshAllowanceView() } label: {
                    Label("Allowance", systemImage: "gauge.with.dots.needle.33percent")
                }
                .accessibilityIdentifier("mesh.settings.allowance")
            }
            Section("Network") {
                NavigationLink { MeshMailboxView() } label: {
                    Label("Mailbox", systemImage: "tray")
                }
                .accessibilityIdentifier("mesh.settings.mailbox")
            }
            #if os(macOS)
                MacNodeHostSection()
            #endif
            Section("Your mesh") {
                if let meshId = mesh.status.meshId {
                    LabeledContent("Mesh ID") {
                        HStack {
                            Text(meshId.suffix(12)).font(.system(.footnote, design: .monospaced))
                            Button(copied ? "Copied" : "Copy") {
                                copied = ComponentPasteboard.copy(meshId)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("mesh.settings.copy-id")
                        }
                    }
                }
                LabeledContent("Keys", value: mesh.status.hardwareBacked ? "In secure hardware" : "In the Keychain")
                LabeledContent("Identity", value: mesh.status.attested ? "Verified" : "Not verified")
                NavigationLink { MeshRecoveryInfoView() } label: {
                    Label("Recovery words", systemImage: "key")
                }
                .accessibilityIdentifier("mesh.settings.recovery")
            }
            MeshSafetySection()
            Section {
                Button("Sign in to a Server Instead") { confirmingNode = true }
                    .accessibilityIdentifier("mesh.settings.node")
            } header: {
                Text("Account")
            } footer: {
                Text("Use an AstralDeep server account in this app. Your mesh stays on this device.")
            }
            if let version = mesh.kernelVersion {
                Section {
                    DisclosureGroup("Diagnostics") {
                        LabeledContent("Runtime", value: version)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Settings")
        .confirmationDialog("Sign in to a server instead?", isPresented: $confirmingNode, titleVisibility: .visible) {
            Button("Use a Server") { modeStore.choose(.node) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This app will use a server account. Your mesh stays on this device.")
        }
        .alert("Rename Device", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Save") {
                if let device = thisDevice { Task { _ = await mesh.renameDevice(device, to: draft) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This name shows on every device.")
        }
    }

    private var voiceStatus: String {
        guard let store = model.onDeviceVoice.store else { return "Not available" }
        switch store.state {
        case .installed: return "Installed"
        case .notInstalled: return "Download " + store.manifest.sizeDescription
        case .downloading(let progress): return "Downloading " + Int(progress.fraction * 100).formatted() + "%"
        case .failed: return "Needs attention"
        case .unsupported: return "Not available"
        }
    }
}

struct MeshRecoveryInfoView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var backup: URL?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section {
                Text("Your 24 recovery words are not saved on this device. Keep the list you wrote down.")
                Text("If you lose every device, the words and a backup file bring your mesh back.")
                    .foregroundStyle(p.muted)
            }
            Section {
                Button("Make a Backup File") {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("astraldeep-mesh-backup.bin")
                    try? FileManager.default.removeItem(at: url)
                    Task {
                        await mesh.exportBackup(to: url)
                        backup = FileManager.default.fileExists(atPath: url.path) ? url : nil
                    }
                }
                .accessibilityIdentifier("mesh.recovery.backup")
                if let backup {
                    ShareLink(item: backup) { Label("Save or Share the Backup", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("mesh.recovery.share")
                }
            } footer: {
                Text("The backup is encrypted. It is useless without your words.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Recovery words")
    }
}

struct MeshModelProviderView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var problem: MeshProviderInputError?
    @State private var saved = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section("Configured") {
                if mesh.providers.isEmpty {
                    Text(mesh.onDeviceModelAvailable ? "Only the on-device model is available." : "No model is set up.")
                        .foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.models.none")
                }
                ForEach(mesh.providers) { provider in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.model).font(ConsoleTypography.headline)
                        Text(provider.baseURL).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                        Text(provider.hasKey ? "Key stored in sealed storage" : "No key")
                            .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mesh.models.provider.\(provider.providerId)")
                }
            }
            Section("OpenAI-compatible provider") {
                TextField("Base URL", text: $baseURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("mesh.models.url")
                TextField("Model", text: $model)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("mesh.models.model")
                SecureField("API key", text: $key)
                    .accessibilityIdentifier("mesh.models.key")
                if let problem {
                    Text(problem.message).foregroundStyle(p.error).accessibilityIdentifier("mesh.models.error")
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(p.success)
                        .accessibilityIdentifier("mesh.models.saved")
                }
                Button("Save") {
                    Task {
                        problem = await mesh.saveProvider(baseURL: baseURL, model: model, key: key)
                        saved = problem == nil
                        if problem == nil { key = "" }
                    }
                }
                .accessibilityIdentifier("mesh.models.save")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Model provider")
    }
}

struct MeshAllowanceView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            if let allowance = mesh.allowance {
                Section {
                    LabeledContent("Share", value: MeshPresentation.share(allowance.share))
                        .accessibilityIdentifier("mesh.allowance.share")
                    if let end = allowance.periodEndsAt {
                        LabeledContent("Resets") { Text(end, style: .relative) }
                    }
                    if let blocked = allowance.blocked {
                        Label(MeshPresentation.refusal(blocked), systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(p.error)
                            .accessibilityIdentifier("mesh.allowance.blocked")
                    }
                } footer: {
                    Text(
                        allowance.share == .fresh
                            ? "This device has heard from your mesh today."
                            : "This device has not heard from another device today, so it uses a smaller share.")
                }
                Section("Remaining today") {
                    ForEach(allowance.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(line.effectClass, value: "\(line.remaining) of \(line.limit)")
                            ProgressView(value: Double(line.remaining), total: Double(max(line.limit, 1)))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let remaining = allowance.modelTokensRemaining, let limit = allowance.modelTokensLimit {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Model tokens", value: "\(remaining) of \(limit)")
                            ProgressView(value: Double(remaining), total: Double(max(limit, 1)))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text("The allowance is not known yet.").foregroundStyle(p.muted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Allowance")
    }
}

struct MeshMailboxView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var address = ""
    @State private var problem: MeshMailboxInputError?
    @State private var saving = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            Section {
                TextField("Mailbox address", text: $address, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("mesh.mailbox.address")
                if let problem {
                    Text(problem.message).foregroundStyle(p.error).accessibilityIdentifier("mesh.mailbox.error")
                }
                Button("Save") {
                    Task {
                        saving = true
                        problem = await mesh.saveMailbox(address)
                        address = mesh.mailboxAddress ?? ""
                        saving = false
                    }
                }
                .disabled(saving || address.trimmingCharacters(in: .whitespacesAndNewlines) == (mesh.mailboxAddress ?? ""))
                .accessibilityIdentifier("mesh.mailbox.save")
            } footer: {
                Text("A mailbox holds encrypted updates for your devices while they are offline. Leave this empty to use none. Saving restarts the mesh connection.")
            }
            Section("Status") {
                Text(MeshPresentation.mailbox(mesh.mailbox))
                    .accessibilityIdentifier("mesh.mailbox.status")
                if mesh.mailbox.pendingNotices > 0 {
                    LabeledContent("Notices waiting", value: "\(mesh.mailbox.pendingNotices)")
                }
                if mesh.mailbox.truncated {
                    Text("More is waiting in the mailbox and arrives on the next exchange.")
                        .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Mailbox")
        .onAppear { address = mesh.mailboxAddress ?? "" }
        .task {
            while !Task.isCancelled {
                await mesh.refreshMailbox()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
