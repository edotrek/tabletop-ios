import SwiftUI
import VisionKit

/// Lettore del QR "per l'app Tabletop Cam" mostrato nel riquadro Collega reflex.
struct QRScannerView: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerRepresentable { text in
                        onFound(text)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Lettore di QR non disponibile su questo dispositivo.")
                        .padding()
                }
            }
            .navigationTitle("Inquadra il QR piccolo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            do {
                try scanner.startScanning()
            } catch {
                log("ERRORE lettore QR: \(error)")
            }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
                if text.contains("code=") {
                    done = true
                    log("QR letto")
                    onFound(text)
                    return
                }
                log("QR ignorato (non è un QR di abbinamento)")
            }
        }
    }
}
