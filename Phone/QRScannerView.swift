import IMMCompanion
import SwiftUI
import VisionKit

/// The camera view inside the pairing panel: scans QR codes and hands each distinct payload to the model.
/// Falls back to an explanation when the device cannot scan (simulator) or camera access is off.
struct QRScannerView: View {
    let model: CompanionModel

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            QRScannerRepresentable { payload in
                Task { await model.handleScanned(payload) }
            }
        } else {
            ScannerUnavailableView(isSupported: DataScannerViewController.isSupported)
        }
    }
}

private struct ScannerUnavailableView: View {
    let isSupported: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(isSupported ? "Camera access is off" : "This device can't scan codes")
                .font(.headline)
                .foregroundStyle(Color.white)
            Text(
                isSupported
                    ? "Allow camera access in Settings to scan the code that IMM shows on your Mac."
                    : "Pair from an iPhone with a camera."
            )
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.7))
            .multilineTextAlignment(.center)
            if isSupported {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> ScannerController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: false,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        return ScannerController(scanner: scanner)
    }

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: Coordinator) {
        if controller.scanner.isScanning { controller.scanner.stopScanning() }
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        context.coordinator.onScan = onScan
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: @MainActor (String) -> Void
        private var lastPayload: String?

        init(onScan: @escaping @MainActor (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                    let payload = barcode.payloadStringValue, !payload.isEmpty, payload != lastPayload
                else { continue }
                lastPayload = payload
                onScan(payload)
            }
        }
    }
}

/// Hosts the system scanner as a child so scanning starts when the view is on screen and stops when it leaves
/// (`DataScannerViewController` is not open for subclassing).
private final class ScannerController: UIViewController {
    let scanner: DataScannerViewController

    init(scanner: DataScannerViewController) {
        self.scanner = scanner
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if scanner.isScanning { scanner.stopScanning() }
    }
}
