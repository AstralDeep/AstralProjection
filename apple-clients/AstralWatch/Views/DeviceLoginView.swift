// The signed-out watch screen: server-generated QR code, short code, and expiry countdown, with no credential
// entry available on the watch itself.

import AstralCore
import SwiftUI

struct DeviceLoginView: View {
    @Environment(WatchModel.self) var model

    var body: some View {
        ScrollView {
            switch model.phase {
            case .waitingApproval, .signedOut:
                pending
            case .loginFailed(let reason):
                failure(title: "Not signed in", message: reason)
            case .unavailable(let detail):
                failure(title: "Sign-in unavailable", message: detail)
            case .signedIn:
                EmptyView()
            }
        }
        .navigationTitle("AstralDeep")
    }

    @ViewBuilder
    private var pending: some View {
        VStack(spacing: 6) {
            if let login = model.login {
                if let png = login.qrPNG, let image = UIImage(data: png) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .containerRelativeFrame(.horizontal) { length, _ in
                            length * 0.65
                        }
                        .accessibilityLabel("Sign-in QR code")
                } else {
                    ProgressView()
                }
                Text(login.userCode)
                    .font(.system(.title3, design: .monospaced).bold())
                    .accessibilityLabel("Sign-in code \(login.userCode)")
                Text("Scan with your phone camera, or enter the code at")
                    .font(AstralTypography.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(login.verificationURI)
                    .font(AstralTypography.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                CountdownLine(until: model.loginExpiresAt)
            } else {
                ProgressView("Getting sign-in code…")
            }
        }
    }

    private func failure(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(AstralTypography.title2)
                .foregroundStyle(WatchBrand.warning)
            Text(title).font(AstralTypography.headline)
            Text(message)
                .font(AstralTypography.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { model.beginDeviceLogin() }
        }
    }
}

struct CountdownLine: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(until.timeIntervalSince(context.date)))
            Text(remaining > 0 ? "Code refreshes in \(remaining)s" : "Refreshing…")
                .font(AstralTypography.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
