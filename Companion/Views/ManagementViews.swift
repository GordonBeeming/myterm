@preconcurrency import AVFoundation
import MyTermCore
import MyTermRemote
import SwiftUI

struct AddHostView: View {
    let services: CompanionServices
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var showingScanner = false
    @State private var isPairing = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing") {
                    Menu {
                        Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                            showingScanner = true
                        }
                        PasteButton(payloadType: String.self) { values in
                            guard let value = values.first else { return }
                            startPairing(value)
                        }
                    } label: {
                        Label(isPairing ? "Pairing…" : "Pair Mac", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(isPairing)
                    .accessibilityIdentifier("pair-mac")
                    if isPairing { ProgressView("Complete sign-in and approve this phone on your Mac.") }
                }
                Section {
                    Text("Show the pairing code in MyTerm on your Mac. Sign in with your passkey if asked, then approve this phone on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Mac")
            .toolbar { Button("Cancel", role: .cancel) {
                pairingTask?.cancel()
                services.cancelSignIn()
                dismiss()
            } }
            .sheet(isPresented: $showingScanner, onDismiss: {
                guard let value = scannedCode else { return }
                scannedCode = nil
                startPairing(value)
            }) {
                NavigationStack {
                    QRScannerView { value in
                        scannedCode = value
                        showingScanner = false
                    } onError: { message in
                        scannedCode = nil
                        showingScanner = false
                        errorMessage = message
                    }
                    .navigationTitle("Scan pairing code")
                    .toolbar {
                        Button("Cancel", role: .cancel) {
                            scannedCode = nil
                            showingScanner = false
                        }
                    }
                }
            }
            .alert("Pairing failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        }
        .interactiveDismissDisabled(isPairing)
    }

    private func startPairing(_ value: String) {
        guard !isPairing else { return }
        pairingTask = Task { await pair(value) }
    }

    private func pair(_ value: String) async {
        guard !isPairing else { return }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = invalidPairingMessage
            return
        }
        do { _ = try PairingTicket.decode(qrURL: url) }
        catch {
            errorMessage = invalidPairingMessage
            return
        }
        isPairing = true
        defer { isPairing = false }
        do {
            _ = try await services.pair(url: url)
            dismiss()
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }

    private var invalidPairingMessage: String {
        "This pairing code is invalid or expired. Scan the current code shown by MyTerm on your Mac."
    }
}

struct HostActionsView: View {
    let services: CompanionServices
    let scene: SceneModel
    let connectionID: SavedConnectionID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let host {
                    Section("Mac") {
                        LabeledContent("Name", value: host.name)
                        LabeledContent("Relay", value: host.relay.canonicalOrigin)
                    }
                    Section {
                        Button("Reconnect") {
                            Task { await scene.connect(to: host, services: services) }
                            dismiss()
                        }
                        Button("Sign in again") {
                            Task {
                                do {
                                    try await services.signInAgain(for: host)
                                    await scene.connect(to: host, services: services)
                                    dismiss()
                                } catch { services.errorMessage = error.localizedDescription }
                            }
                        }
                        Button("Remove pairing", role: .destructive) {
                            Task {
                                await scene.disconnect()
                                await services.remove(host)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Mac")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var host: SavedHostDescriptor? {
        services.savedHosts.first { SavedConnectionID($0) == connectionID }
    }
}

struct CompanionSettingsView: View {
    @AppStorage("workspacePresentation") private var workspacePresentation = WorkspacePresentationStyle.adaptive.rawValue
    @Environment(\.dismiss) private var dismiss
    let services: CompanionServices
    let scene: SceneModel
    @State private var confirmsNotificationReset = false

    var body: some View {
        Form {
            Section("Workspace view") {
                Picker("Open workspaces", selection: $workspacePresentation) {
                    ForEach(WorkspacePresentationStyle.allCases, id: \.rawValue) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Text("Adaptive panes mirrors the Mac layout on wider screens and uses a terminal picker on narrow screens. This setting applies only to this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Allow terminal alerts", isOn: Binding(
                    get: { services.notificationEnrollment.isEnabled },
                    set: { enabled in Task { await services.setNotificationsEnabled(enabled) } }
                ))
                .disabled(services.notificationEnrollment.isWorking)
                Text(services.notificationEnrollment.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if services.notificationEnrollment.recoveryRequired {
                    Button("Reset local notification setup", role: .destructive) {
                        confirmsNotificationReset = true
                    }
                    .disabled(services.notificationEnrollment.isWorking)
                }
            }
            Section("Connections") {
                Text("Each app window connects independently. Returning to the foreground reloads the latest terminal screen before input is enabled.")
            }
            Section("Current workspace") {
                if let workspaceID = scene.selectedWorkspaceID,
                   let workspace = scene.projection?.workspaces.first(where: {
                       $0.id.rawValue == workspaceID
                   }), let preferences = workspace.preferences {
                    NavigationLink("Mac terminal settings") {
                        RemoteSettingsEditor(scene: scene, workspaceID: workspaceID,
                                             preferences: preferences)
                    }
                } else {
                    Text("Choose a workspace before changing its settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("companion-settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("close-settings")
            }
        }
        .alert("Reset local notification setup?", isPresented: $confirmsNotificationReset) {
            Button("Reset local setup", role: .destructive) {
                Task { await services.resetLocalNotificationSetup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved notification session, grants, and routes from this device. Remote grants could not be revoked, so alerts may still arrive until notifications for MyTerm are disabled in iOS Settings.")
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onError: onError) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = context.coordinator.onCode
        controller.onError = context.coordinator.onError
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator {
        let onCode: (String) -> Void
        let onError: (String) -> Void
        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
        }
    }
}

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didEmitCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await configureCamera() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configureCamera() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else {
            onError?("Camera access is required to scan a pairing code. You can paste the pairing URL instead.")
            return
        }
        guard let camera = AVCaptureDevice.default(for: .video) else {
            onError?("No camera is available. Paste the pairing URL instead.")
            return
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: camera) }
        catch {
            onError?("The camera could not start: \(error.localizedDescription)")
            return
        }
        guard session.canAddInput(input) else {
            onError?("The camera input is unavailable. Paste the pairing URL instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("QR scanning is unavailable. Paste the pairing URL instead.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        session.startRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else {
            return
        }
        guard !didEmitCode else { return }
        didEmitCode = true
        session.stopRunning()
        onCode?(code)
    }
}
