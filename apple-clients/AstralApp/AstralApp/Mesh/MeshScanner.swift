// A QR scanner for the pairing code, built on VisionKit's data scanner and available only on iPhone and iPad hardware that supports it.
// It reports the first payload string it reads to its caller and never stores images.

#if os(iOS)
    import SwiftUI
    import VisionKit

    enum MeshScanner {
        @MainActor static var isAvailable: Bool {
            DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        }
    }

    struct MeshScannerScreen: View {
        let onScan: (String) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            MeshScannerRepresentable { text in
                onScan(text)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct MeshScannerRepresentable: UIViewControllerRepresentable {
        let onScan: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        @MainActor
        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onScan: (String) -> Void
            private var delivered = false

            init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

            func dataScanner(
                _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                guard !delivered else { return }
                for item in addedItems {
                    if case .barcode(let barcode) = item, let text = barcode.payloadStringValue, !text.isEmpty {
                        delivered = true
                        dataScanner.stopScanning()
                        onScan(text)
                        return
                    }
                }
            }
        }
    }
#endif
