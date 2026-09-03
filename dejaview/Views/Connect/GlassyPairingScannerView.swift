import AVFoundation
import SwiftUI
import VisionKit

/// Camera access is requested only when the user chooses to scan a pairing code.
@MainActor
struct GlassyPairingScannerView: View {
    private enum CameraState {
        case checking, ready, denied, unavailable
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var cameraState = CameraState.checking
    let onScan: (String) -> Void

    var body: some View {
        Group {
            switch cameraState {
            case .checking:
                ProgressView("Preparing Camera…")
                    .frame(maxWidth: .infinity, minHeight: 260)
            case .ready:
                PairingCameraPreview(onScan: onScan) {
                    cameraState = .unavailable
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("Camera scanner for the Glassy Host pairing QR code")
            case .denied:
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "camera.fill")
                } description: {
                    Text("Allow camera access in Settings to scan your Mac’s QR code, or enter its pairing code below.")
                } actions: {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
            case .unavailable:
                ContentUnavailableView(
                    "Camera Unavailable",
                    systemImage: "camera.fill",
                    description: Text("You can still connect by entering the pairing code shown on your Mac.")
                )
            }
        }
        .task { await prepareCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await prepareCamera() }
            } else {
                // Removing the preview tears down scanning while inactive.
                cameraState = .checking
            }
        }
    }

    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            cameraState = .unavailable
            return
        }

        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard !Task.isCancelled else { return }
        guard status == .authorized else {
            cameraState = status == .denied ? .denied : .unavailable
            return
        }
        cameraState = DataScannerViewController.isAvailable ? .ready : .unavailable
    }
}

@MainActor
private struct PairingCameraPreview: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.hasDeliveredResult else { return }
        do {
            try scanner.startScanning()
        } catch {
            Task { @MainActor in onUnavailable() }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
        scanner.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var hasDeliveredResult = false
        let onScan: (String) -> Void
        let onUnavailable: () -> Void

        init(onScan: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !hasDeliveredResult,
                      case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                hasDeliveredResult = true
                scanner.stopScanning()
                onScan(value)
                break
            }
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            scanner.stopScanning()
            onUnavailable()
        }
    }
}
