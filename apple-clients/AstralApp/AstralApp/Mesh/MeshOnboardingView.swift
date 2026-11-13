// The screens shown while this device has no mesh: the four ways in, the one-time recovery words, and the join code with its QR.
// They drive MeshRuntime's creation and join state and leave the server sign-in path available as its own option.

import SwiftUI

struct MeshOnboardingView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModeStore.self) private var modeStore
    @Environment(ThemeStore.self) private var theme
    @State private var recovering = false
    @State private var joining = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    Image("AstralDeepLogo")
                        .resizable().scaledToFit()
                        .frame(maxWidth: 220)
                        .accessibilityLabel("AstralDeep")
                    if recovering {
                        MeshRestoreView { recovering = false }
                    } else if case .offered = mesh.join {
                        MeshJoinView()
                    } else if case .accepted(let accepted) = mesh.join {
                        MeshJoinAcceptedView(accepted: accepted)
                    } else if joining || isFailedJoin {
                        MeshJoinStartView(
                            onShowCode: { Task { await mesh.beginJoin() } },
                            onBack: {
                                joining = false
                                mesh.cancelJoin()
                            })
                    } else {
                        choices
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 420)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(p.bg)
    }

    @ViewBuilder
    private var choices: some View {
        VStack(spacing: 8) {
            Text("Your personal mesh").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            Text("A mesh links your devices. Your chats and assistant follow you, and no server holds them.")
                .font(ConsoleTypography.body)
                .foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("mesh.explainer")
        }
        if mesh.restoredInstall {
            Label(
                "This device was restored from a backup. Recover your mesh with your words, join it again or create a new one.",
                systemImage: "exclamationmark.triangle")
                .font(ConsoleTypography.footnote)
                .foregroundStyle(p.warning)
                .accessibilityIdentifier("mesh.restored")
        }
        Button {
            Task { await mesh.createMesh() }
        } label: {
            Text("Create a Mesh").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(busy)
        .accessibilityIdentifier("mesh.create")
        Button {
            joining = true
        } label: {
            Text("Join My Mesh").frame(maxWidth: .infinity)
        }
        .meshBordered()
        .controlSize(.large)
        .disabled(busy)
        .accessibilityIdentifier("mesh.join")
        HStack(spacing: 20) {
            Button("Recover my mesh") { recovering = true }
                .disabled(busy)
                .accessibilityIdentifier("mesh.recover")
            Button("Sign in to a server") { modeStore.choose(.node) }
                .disabled(busy)
                .accessibilityIdentifier("mesh.node")
        }
        .buttonStyle(.borderless)
        .font(ConsoleTypography.subheadline)
        progress
        if case .failed(let message) = mesh.join {
            error(message)
        }
    }

    private var isFailedJoin: Bool {
        if case .failed = mesh.join { return true }
        return false
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
            Text("Show this on your other device").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            if case .offered(let offer) = mesh.join {
                MeshExpiring(expiresAt: offer.expiresAt) { expired in
                    if expired { expiredOffer } else { offerBody(offer) }
                }
            } else if case .failed(let message) = mesh.join {
                Text(message).foregroundStyle(p.error).accessibilityIdentifier("mesh.join.error")
            }
            Button("Cancel") { mesh.cancelJoin() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mesh.join.cancel")
        }
    }

    private var expiredOffer: some View {
        VStack(spacing: 14) {
            Text("The code ran out of time.").font(ConsoleTypography.title3)
                .accessibilityIdentifier("mesh.join.error")
            Button {
                Task {
                    mesh.cancelJoin()
                    await mesh.beginJoin()
                }
            } label: {
                Text("Start again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("mesh.join.restart")
        }
    }

    private func offerBody(_ offer: MeshPairingOffer) -> some View {
        VStack(spacing: 18) {
            Text("On a device that is already on your mesh, open Devices, choose Add Device, then use the code from the new device. Scan this code or send it there.")
                .font(ConsoleTypography.subheadline)
                .foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("mesh.join.instructions")
            Text(MeshPresentation.groupedCode(offer.shortCode))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel("Comparison code " + offer.shortCode.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("mesh.join.code")
            MeshQRCodeView(text: offer.payload).frame(maxWidth: 260)
            if let expires = offer.expiresAt { MeshCountdownLabel(expiresAt: expires) }
            HStack(spacing: 12) {
                ShareLink(item: offer.payload) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Send the pairing code with AirDrop or Messages")
                .accessibilityIdentifier("mesh.join.share")
                Button {
                    copied = ComponentPasteboard.copy(offer.payload)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .meshBordered()
                .accessibilityLabel(copied ? "Copied pairing code" : "Copy pairing code")
                .accessibilityIdentifier("mesh.join.copy")
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your other device to approve").font(ConsoleTypography.footnote)
                    .foregroundStyle(p.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mesh.join.waiting")
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
                Text("They are the only way to get your mesh back if you lose every device. Write them on paper. They are shown once and are not saved on this device.")
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
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
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
