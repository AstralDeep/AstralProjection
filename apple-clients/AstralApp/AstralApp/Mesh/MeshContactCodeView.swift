// The comparison screen: the 12 digit code in three groups, a QR code to scan for a quick check, and the Codes match and Codes differ choices.
// Codes match asks for presence through the Kernel's consent prompt, and Codes differ writes nothing.

import SwiftUI

struct MeshContactCodeView: View {
    @State var model: MeshContactCompareModel
    @State private var scanning = false
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 18) {
            switch model.phase {
            case .comparing, .failed: comparing
            case .verifying:
                ProgressView("Waiting for your approval").accessibilityIdentifier("mesh.contacts.code.verifying")
            case .verified(let contact):
                done(Text(verbatim: contact.name + " is verified."), icon: "checkmark.seal.fill")
            case .differed: done(Text("Nothing was saved. They stay unverified."), icon: "xmark.shield")
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        #if os(iOS)
            .sheet(isPresented: $scanning) { scanner }
        #endif
    }

    private var comparing: some View {
        VStack(spacing: 16) {
            Text("Check the codes match").font(ConsoleTypography.title3).accessibilityAddTraits(.isHeader)
            Text(verbatim: "Ask " + model.exchange.name + " to read their code, or scan it.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            MeshComparisonCode(code: model.exchange.code, identifier: MeshContactID.code)
            MeshQRCodeView(text: model.exchange.codeQR, label: "Comparison QR code", identifier: MeshContactID.codeQR)
                .frame(maxWidth: 160)
            scanRow
            if case .failed(let message) = model.phase {
                Text(message).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.contacts.code.error")
            }
            Button {
                Task { await model.codesMatch() }
            } label: {
                Label("Codes match", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityHint("Asks for your approval")
            .accessibilityIdentifier(MeshContactID.codesMatch)
            Button {
                Task { await model.codesDiffer() }
            } label: {
                Text("Codes differ").frame(maxWidth: .infinity)
            }
            .meshBordered().controlSize(.large)
            .accessibilityIdentifier(MeshContactID.codesDiffer)
        }
    }

    @ViewBuilder
    private var scanRow: some View {
        switch model.scan {
        case .matches:
            Label("The scanned code matches.", systemImage: "checkmark.circle.fill").foregroundStyle(p.success)
                .accessibilityIdentifier("mesh.contacts.code.scan.matches")
        case .differs:
            Label("The scanned code differs. Do not continue.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(p.error)
                .accessibilityIdentifier("mesh.contacts.code.scan.differs")
        case .none: EmptyView()
        }
        #if os(iOS)
            if MeshScanner.isAvailable {
                Button("Scan Their Code") { scanning = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(MeshContactID.codeScan)
            }
        #endif
    }

    private func done(_ text: Text, icon: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(p.accent).accessibilityHidden(true)
            text.font(ConsoleTypography.title3).multilineTextAlignment(.center)
                .accessibilityIdentifier("mesh.contacts.code.done")
        }
    }

    #if os(iOS)
        private var scanner: some View {
            NavigationStack {
                MeshScannerScreen { scanned in model.scanned(scanned) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } }
                    }
            }
        }
    #endif
}
