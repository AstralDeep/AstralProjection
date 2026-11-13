// The add-a-device sheet shown on a device that is already on the mesh: start on the new device, bring its pairing code here, compare the codes and approve.
// It drives MeshRuntime's add-device state, so approval is signed through the consent sheet and a failure leaves the person on the code step.

import SwiftUI
import UniformTypeIdentifiers

struct MeshAddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MeshRuntime.self) private var mesh

    var body: some View {
        NavigationStack {
            MeshAddDeviceView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closeTitle) { dismiss() }
                            .accessibilityIdentifier("mesh.add.close")
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
        #endif
        .interactiveDismissDisabled(mesh.addDevice == .approving)
    }

    private var closeTitle: String {
        if case .added = mesh.addDevice { return "Done" }
        return "Cancel"
    }
}

struct MeshAddDeviceView: View {
    private enum Step { case start, code }

    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.start
    @State private var payload = ""
    @State private var clipboardHasText = false
    @State private var dropTargeted = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch mesh.addDevice {
                case .idle, .failed:
                    if step == .start { start } else { code }
                case .previewing(let preview, _):
                    comparison(preview)
                case .approving:
                    ProgressView("Waiting for your approval")
                        .padding(.top, 60)
                        .accessibilityIdentifier("mesh.add.approving")
                case .added(let label):
                    added(label)
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
        .navigationTitle("Add Device")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { mesh.resetAddDevice() }
    }

    private func header(_ number: Int, icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Text("Step \(number) of 3").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(p.accent).accessibilityHidden(true)
            Text(title).font(ConsoleTypography.title2).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(text).font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mesh.add.step.\(number)")
    }

    private var start: some View {
        VStack(spacing: 24) {
            header(
                1, icon: "iphone.and.arrow.forward", title: "Open AstralDeep on the new device",
                text: "Choose Join my mesh. The new device shows a pairing code for you to bring here.")
            Button {
                step = .code
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mesh.add.start")
        }
    }

    private var code: some View {
        VStack(spacing: 20) {
            #if os(iOS)
                header(
                    2, icon: "qrcode.viewfinder", title: "Get the pairing code",
                    text: "Scan the code on the new device, or paste it if you sent it to this phone.")
                if MeshScanner.isAvailable {
                    NavigationLink {
                        MeshScannerScreen { scanned in
                            payload = scanned
                            Task { await mesh.previewAddDevice(payload: scanned) }
                        }
                    } label: {
                        Label("Scan Code", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("mesh.add.scan")
                }
                Button {
                    payload = MeshPasteboardReader.string()
                    Task { await mesh.previewAddDevice(payload: payload) }
                } label: {
                    Label("Paste Code", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(MeshScanAvailableStyle())
                .controlSize(.large)
                .accessibilityIdentifier("mesh.add.paste")
                field
            #else
                header(
                    2, icon: "doc.on.clipboard", title: "Get the pairing code",
                    text: "A Mac cannot scan a QR code. On the new device tap Share or Copy under its code, then send it here with AirDrop or Universal Clipboard.")
                pasteTarget
                if clipboardHasText {
                    Button {
                        payload = MeshPasteboardReader.string()
                        Task { await mesh.previewAddDevice(payload: payload) }
                    } label: {
                        Label("Use the Code on the Clipboard", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("mesh.add.clipboard")
                }
            #endif
            if case .failed(let message) = mesh.addDevice {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(ConsoleTypography.subheadline)
                    .foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.add.error")
            }
            Button {
                Task { await mesh.previewAddDevice(payload: payload) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(clipboardHasText ? nil : .defaultAction)
            .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("mesh.add.continue")
        }
        .onAppear(perform: refreshClipboard)
        #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshClipboard()
            }
        #endif
    }

    private func refreshClipboard() { clipboardHasText = MeshPasteboardReader.hasString() }

    private var field: some View {
        TextField("Or type the code here", text: $payload, axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("mesh.add.payload")
    }

    private var pasteTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AstralRadius.lg)
                .fill(dropTargeted ? p.accent.opacity(0.12) : p.surface)
            RoundedRectangle(cornerRadius: AstralRadius.lg)
                .strokeBorder(dropTargeted ? p.accent : p.fieldBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            if payload.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title2).accessibilityHidden(true)
                    Text("Paste or drop the pairing code here").font(ConsoleTypography.headline)
                }
                .foregroundStyle(p.muted)
                .allowsHitTesting(false)
            }
            TextEditor(text: $payload)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .opacity(payload.isEmpty ? 0.02 : 1)
                .accessibilityLabel("Pairing code")
                .accessibilityIdentifier("mesh.add.payload")
        }
        .frame(minHeight: 130)
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first, !text.isEmpty else { return false }
            payload = text
            Task { await mesh.previewAddDevice(payload: text) }
            return true
        } isTargeted: {
            dropTargeted = $0
        }
    }

    private func comparison(_ preview: MeshPairingPreview) -> some View {
        let groups = MeshPresentation.codeGroups(preview.comparisonCode)
        return VStack(spacing: 20) {
            header(
                3, icon: "checkmark.shield", title: "Check the codes match",
                text: "Make sure \(preview.deviceLabel) shows " + groups.joined(separator: " ") + ".")
            HStack(spacing: 14) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.lg))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Comparison code " + groups.joined(separator: " "))
            .accessibilityIdentifier("mesh.add.code")
            VStack(spacing: 2) {
                Text(preview.deviceLabel).font(ConsoleTypography.headline)
                Text(MeshPresentation.kind(preview.deviceKind) + " · " + preview.fingerprint)
                    .font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
            .accessibilityElement(children: .combine)
            Text("If the codes differ, cancel. Someone else may be trying to join your mesh.")
                .font(ConsoleTypography.footnote).foregroundStyle(p.muted).multilineTextAlignment(.center)
            Button {
                Task { await mesh.approveAddDevice() }
            } label: {
                Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Asks for your approval")
            .accessibilityIdentifier("mesh.add.approve")
            Button {
                mesh.resetAddDevice()
                step = .code
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("mesh.add.cancel")
        }
    }

    private func added(_ label: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(p.success)
                .accessibilityHidden(true)
            Text("\(label) was added").font(ConsoleTypography.title2).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Your chats will sync to it once it connects.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mesh.add.done")
        }
        .padding(.top, 40)
        .accessibilityElement(children: .contain)
    }
}

private struct MeshScanAvailableStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
            if MeshScanner.isAvailable {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                    .buttonStyle(.bordered)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                    .buttonStyle(.borderedProminent)
            }
        #else
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
        #endif
    }
}
