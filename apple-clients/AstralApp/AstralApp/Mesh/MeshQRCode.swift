// Renders a pairing payload as a QR code with Core Image so the iOS simulator and Mac can show it without a camera.
// The new device shows this code and the existing device reads or pastes the same payload.

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

nonisolated enum MeshQRCode {
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct MeshQRCodeView: View {
    let text: String

    var body: some View {
        if let image = MeshQRCode.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: AstralRadius.md))
                .accessibilityElement()
                .accessibilityLabel("Pairing QR code")
                .accessibilityIdentifier("mesh.join.qr")
        }
    }
}
