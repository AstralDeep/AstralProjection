// The screens shown while this device has no mesh: the three ways in, the one-time recovery words, and the join code with its QR.
// They drive MeshRuntime's creation and join state and leave the server sign-in path available as its own option.

import SwiftUI

struct MeshOnboardingView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModeStore.self) private var modeStore
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("AstralDeepLogo")
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240)
                    .padding(.top, 32)
                    .accessibilityLabel("AstralDeep")
                if mesh.join == .idle || mesh.join == .starting {
                    choices
                } else {
                    MeshJoinView()
                }
            }
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
    }

    @ViewBuilder
    private var choices: some View {
        if mesh.restoredInstall {
            Label("This device was restored from a backup. Join your mesh again or create a new one.", systemImage: "exclamationmark.triangle")
                .font(ConsoleTypography.footnote)
                .foregroundStyle(p.warning)
                .accessibilityIdentifier("mesh.restored")
        }
        Button {
            Task { await mesh.createMesh() }
        } label: {
            Text("Create a mesh on this device").frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)
        .accessibilityIdentifier("mesh.create")
        Button {
            Task { await mesh.beginJoin() }
        } label: {
            Text("Join my mesh").frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .accessibilityIdentifier("mesh.join")
        Button("Connect to a node") { modeStore.choose(.node) }
            .buttonStyle(.plain)
            .foregroundStyle(p.accent)
            .disabled(busy)
            .accessibilityIdentifier("mesh.node")
        progress
        if case .failed(let message) = mesh.join {
            error(message)
        }
    }

    private var busy: Bool {
        switch mesh.creation {
        case .signingIn, .finishing: return true
        default: return mesh.join == .starting
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch mesh.creation {
        case .signingIn:
            ProgressView("Signing in")
                .accessibilityIdentifier("mesh.create.progress")
        case .finishing:
            ProgressView("Creating your mesh")
                .accessibilityIdentifier("mesh.create.progress")
        case .failed(let message):
            error(message)
        default:
            if mesh.join == .starting { ProgressView() }
        }
    }

    private func error(_ message: String) -> some View {
        Text(message)
            .font(ConsoleTypography.footnote)
            .foregroundStyle(p.error)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("mesh.error")
    }
}

struct MeshJoinView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var copied = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 18) {
            Text("Join my mesh").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            if case .offered(let offer) = mesh.join {
                Text(MeshPresentation.groupedCode(offer.shortCode))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Comparison code " + offer.shortCode.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("mesh.join.code")
                MeshQRCodeView(text: offer.payload).frame(maxWidth: 260)
                Button {
                    copied = ComponentPasteboard.copy(offer.payload)
                } label: {
                    Label(copied ? "Copied" : "Copy pairing code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mesh.join.copy")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your other device to approve").font(ConsoleTypography.footnote)
                        .foregroundStyle(p.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mesh.join.waiting")
            } else if case .failed(let message) = mesh.join {
                Text(message).foregroundStyle(p.error).accessibilityIdentifier("mesh.join.error")
            }
            Button("Cancel") { mesh.cancelJoin() }
                .accessibilityIdentifier("mesh.join.cancel")
        }
    }
}

struct MeshRecoveryView: View {
    let words: [String]
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var written = false
    @State private var answers = ["", ""]
    @State private var mismatch = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Write these 24 words down")
                    .font(ConsoleTypography.title2)
                    .accessibilityAddTraits(.isHeader)
                Text("They are the only way to recover your mesh if you lose every device. They are shown once and are not saved on this device.")
                    .font(ConsoleTypography.footnote)
                    .foregroundStyle(p.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        Text("\(index + 1). \(word)")
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                            .accessibilityIdentifier("mesh.recovery.word.\(index + 1)")
                    }
                }
                Toggle("I wrote all 24 words down in order", isOn: $written)
                    .accessibilityIdentifier("mesh.recovery.written")
                if written {
                    ForEach(Array(MeshRecoveryConfirmation.positions.enumerated()), id: \.offset) { slot, position in
                        TextField("Word \(position)", text: $answers[slot])
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("mesh.recovery.answer.\(position)")
                    }
                    if mismatch {
                        Text("Those words do not match. Check your list.")
                            .font(ConsoleTypography.footnote).foregroundStyle(p.error)
                            .accessibilityIdentifier("mesh.recovery.mismatch")
                    }
                }
                Button {
                    mismatch = !mesh.confirmRecoveryWritten(answers: answers)
                } label: {
                    Text("Continue").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!written || answers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .accessibilityIdentifier("mesh.recovery.continue")
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
    }
}
