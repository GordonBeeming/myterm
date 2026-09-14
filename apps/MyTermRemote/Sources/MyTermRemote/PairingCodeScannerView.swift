import AVFoundation
import SwiftUI
import UIKit

/// Scans a QR code encoding a `myterm-remote://` pairing URL, in place of sending the user to the
/// Camera app. Presented inside a `NavigationStack` in a sheet; the caller supplies its own Cancel
/// button, so this view adds none.
struct PairingCodeScannerView: View {
    let onScan: (URL) -> Void

    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    /// Checked once up front so the Simulator, which reports no video device, never reaches a
    /// permission prompt or a session it cannot start.
    @State private var hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        content
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        if !hasCamera {
            ContentUnavailableView(
                "No Camera",
                systemImage: "video.slash",
                description: Text("Use the Camera app on another device, or add the Mac by hand.")
            )
        } else {
            switch authorization {
            case .authorized:
                CameraScannerView(onScan: onScan)
            case .notDetermined:
                Color.clear.task { await requestAccess() }
            default:
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "camera.fill")
                } description: {
                    Text("MyTerm Remote needs camera access to scan the pairing code shown on your Mac.")
                } actions: {
                    Button("Open Settings", action: openSettings)
                }
            }
        }
    }

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = granted ? .authorized : .denied
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The live preview plus the viewfinder and hint text drawn over it.
private struct CameraScannerView: View {
    let onScan: (URL) -> Void

    var body: some View {
        ZStack {
            CameraPreviewRepresentable(onScan: onScan)
                .ignoresSafeArea()
            ViewfinderOverlay()
        }
        .overlay(alignment: .bottom) {
            Text("Point at the code shown on your Mac.")
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 32)
        }
    }
}

/// A square, rounded frame marking where a code should sit, drawn at a fraction of the shorter
/// side so it reads the same on a phone held either way up.
private struct ViewfinderOverlay: View {
    private let sideFraction: CGFloat = 0.65

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * sideFraction
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

/// Bridges the AVFoundation capture pipeline into SwiftUI. The pipeline itself lives in
/// `ScannerCoordinator`, which this hands the view's layer to and starts on appear.
private struct CameraPreviewRepresentable: UIViewRepresentable {
    let onScan: (URL) -> Void

    func makeCoordinator() -> ScannerCoordinator {
        ScannerCoordinator(onScan: onScan)
    }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView(session: context.coordinator.session)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: ScannerPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: ScannerCoordinator) {
        coordinator.stop()
    }
}

/// Hosts the capture preview layer and keeps it filling the view's bounds as the view resizes.
private final class ScannerPreviewView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

/// Owns the capture session and turns decoded QR payloads into a single `onScan` call.
///
/// `AVCaptureSession` predates Swift concurrency and is not `Sendable`, but every touch of it here
/// happens on `sessionQueue` — configuration, start, and stop all hop through that queue, and it is
/// also the queue the metadata delegate callback arrives on — so the class is safe to mark
/// `@unchecked Sendable` even though the compiler cannot see that on its own.
private final class ScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let onScan: (URL) -> Void
    private let sessionQueue = DispatchQueue(label: "dev.myterm.remote.qr-scanner")
    /// Guards `onScan` to exactly one call per presentation: the delegate can keep firing for the
    /// same code for several frames before the sheet is dismissed.
    private var hasScanned = false

    init(onScan: @escaping (URL) -> Void) {
        self.onScan = onScan
    }

    /// Both configuring the session and calling `startRunning()` block the calling thread, so this
    /// whole step runs off the main actor to keep the UI responsive while the camera spins up.
    func start() {
        sessionQueue.async { [self] in
            // `startRunning()` raises an Objective-C exception, which Swift cannot catch, if it is
            // called between `beginConfiguration()` and `commitConfiguration()`. So the session is
            // configured and committed first, and started only once that has succeeded.
            guard configure() else { return }
            session.startRunning()
        }
    }

    /// Adds the camera and the QR output. Returns false when the device has no usable camera, in
    /// which case the session is left empty and never started.
    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return false }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: sessionQueue)
        output.metadataObjectTypes = [.qr]
        return true
    }

    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            !hasScanned,
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let payload = object.stringValue,
            let url = URL(string: payload),
            url.scheme == "myterm-remote"
        else { return }
        hasScanned = true

        // DispatchQueue's closure parameter carries no Sendable requirement, unlike Task's, so
        // this hop needs no extra ceremony to send a captured `(URL) -> Void` to the main actor.
        DispatchQueue.main.async { [onScan] in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan(url)
        }
    }
}

#Preview {
    NavigationStack {
        PairingCodeScannerView { url in
            print("Scanned \(url)")
        }
    }
}
