// Accepts someone's contact invitation by scan, paste or an opened link, then moves to the code comparison.
// Nothing here asks for presence, since only the Codes match action does.

import SwiftUI

struct MeshContactAcceptView: View {
    @State private var model: MeshContactAcceptModel
    @State private var scanning = false
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }
    private let service: any MeshContactService

    init(service: any MeshContactService, initialText: String = "") {
        self.service = service
        _model = State(initialValue: MeshContactAcceptModel(service: service, initial: initialText))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if case .comparing(let exchange) = model.phase {
                    MeshContactCodeView(model: MeshContactCompareModel(service: service, exchange: exchange))
                } else {
                    form
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
        .navigationTitle("Add a Contact")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) { scanner }
        #endif
    }

    private var form: some View {
        VStack(spacing: 14) {
            Text("Use their invitation").font(ConsoleTypography.title3).accessibilityAddTraits(.isHeader)
            #if os(iOS)
                if MeshScanner.isAvailable {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan Their Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier(MeshContactID.acceptScan)
                }
            #endif
            Button {
                model.input = MeshPasteboardReader.string()
                model.classify()
            } label: {
                Label("Paste Invitation", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .meshBordered().controlSize(.large)
            .accessibilityIdentifier(MeshContactID.acceptPaste)
            TextField("Or type the invitation", text: $model.input, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.input) { model.classify() }
                .accessibilityLabel("Invitation text")
                .accessibilityIdentifier(MeshContactID.acceptInput)
            if let preview = model.preview { previewLine(preview) }
            TextField("Your name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Your name")
                .accessibilityIdentifier(MeshContactID.acceptName)
            if case .failed(let message) = model.phase {
                Text(message).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.contacts.accept.error")
            }
            Button {
                Task { await model.submit() }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .meshBordered().controlSize(.large)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier(MeshContactID.acceptSubmit)
        }
    }

    private func previewLine(_ preview: MeshContactInvite) -> some View {
        Label {
            Text(verbatim: preview.name.isEmpty ? "An invitation" : "Invitation from " + preview.name)
        } icon: {
            Image(systemName: "envelope.badge")
        }
        .font(ConsoleTypography.subheadline).foregroundStyle(p.muted)
        .accessibilityIdentifier("mesh.contacts.accept.preview")
    }

    #if os(iOS)
        private var scanner: some View {
            NavigationStack {
                MeshScannerScreen { scanned in
                    model.input = scanned
                    model.classify()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } }
                }
            }
        }
    #endif
}
