#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import IOKit.hid
import MyTermCore
import Network
import OSLog
import Photos
import Speech

@MainActor
public final class LiveSystemPermissionProvider: SystemPermissionProviding {
    private nonisolated static let logger = Logger(subsystem: "com.gordonbeeming.myterm", category: "permissions")
    private nonisolated static let systemEventsBundleIdentifier = "com.apple.systemevents"

    // Each of these has to outlive its request: macOS drops the prompt callback if the object
    // that asked is deallocated before the user answers.
    private var eventStore: EKEventStore?
    private var locationRequest: LocationAuthorizationRequest?
    private var bluetoothRequest: BluetoothAuthorizationRequest?

    public init() {}

    public func currentStatus(of permission: SystemPermission) async -> SystemPermissionStatus {
        switch permission {
        case .microphone:
            Self.status(from: AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            Self.status(from: AVCaptureDevice.authorizationStatus(for: .video))
        case .bluetooth:
            Self.status(from: CBManager.authorization)
        case .calendars:
            Self.status(from: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            Self.status(from: EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            Self.status(from: CNContactStore.authorizationStatus(for: .contacts))
        case .photos:
            Self.status(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .location:
            Self.status(from: CLLocationManager().authorizationStatus)
        case .speechRecognition:
            Self.status(from: SFSpeechRecognizer.authorizationStatus())
        case .automation:
            await Self.automationStatus(askUserIfNeeded: false)
        case .fullDiskAccess:
            await Self.fullDiskAccessStatus()
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .inputMonitoring:
            Self.status(from: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        case .desktopFolder, .documentsFolder, .downloadsFolder, .localNetwork:
            // Reading any of these is what triggers the prompt, so there is nothing safe to check.
            .unknown
        case .removableVolumes, .networkVolumes:
            .informational
        }
    }

    public func request(_ permission: SystemPermission) async -> SystemPermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .bluetooth:
            let request = BluetoothAuthorizationRequest()
            bluetoothRequest = request
            await request.run()
            bluetoothRequest = nil
        case .calendars:
            await requestEventStoreAccess(for: .event)
        case .reminders:
            await requestEventStoreAccess(for: .reminder)
        case .contacts:
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                Self.logger.error("Contacts access request failed: \(error.localizedDescription, privacy: .public)")
            }
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .location:
            let request = LocationAuthorizationRequest()
            locationRequest = request
            await request.run()
            locationRequest = nil
        case .speechRecognition:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .automation:
            return await requestAutomation()
        case .accessibility:
            // The prompt only points at System Settings; the toggle there is the actual grant,
            // which the next refresh picks up when MyTerm becomes active again.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .desktopFolder:
            return await Self.probeFolder(.desktopDirectory)
        case .documentsFolder:
            return await Self.probeFolder(.documentDirectory)
        case .downloadsFolder:
            return await Self.probeFolder(.downloadsDirectory)
        case .localNetwork:
            return await LocalNetworkProbe().run()
        case .fullDiskAccess, .removableVolumes, .networkVolumes:
            break
        }
        return await currentStatus(of: permission)
    }

    public func openSystemSettings(for permission: SystemPermission) {
        guard let url = permission.systemSettingsURL else {
            Self.logger.error("No System Settings URL for \(permission.rawValue, privacy: .public)")
            return
        }
        if !NSWorkspace.shared.open(url) {
            Self.logger.error("System Settings did not open \(url.absoluteString, privacy: .public)")
        }
    }

    private func requestEventStoreAccess(for entity: EKEntityType) async {
        let store = EKEventStore()
        eventStore = store
        defer { eventStore = nil }
        do {
            switch entity {
            case .event:
                _ = try await store.requestFullAccessToEvents()
            case .reminder:
                _ = try await store.requestFullAccessToReminders()
            @unknown default:
                Self.logger.error("Unexpected EventKit entity type \(entity.rawValue)")
            }
        } catch {
            Self.logger.error("EventKit access request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestAutomation() async -> SystemPermissionStatus {
        // AEDeterminePermissionToAutomateTarget can only ask about a running app.
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.systemEventsBundleIdentifier) else {
            Self.logger.error("System Events is not installed")
            return .unknown
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            Self.logger.error("Could not launch System Events: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
        return await Self.automationStatus(askUserIfNeeded: true)
    }

    /// Runs off the main actor because asking blocks until the user answers the prompt.
    private nonisolated static func automationStatus(askUserIfNeeded: Bool) async -> SystemPermissionStatus {
        await Task.detached(priority: .userInitiated) {
            var target = AEAddressDesc()
            let bundleIdentifier = Array(systemEventsBundleIdentifier.utf8)
            let createStatus = bundleIdentifier.withUnsafeBytes { bytes in
                AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
            }
            guard createStatus == noErr else {
                logger.error("AECreateDesc failed with \(createStatus)")
                return SystemPermissionStatus.unknown
            }
            defer { AEDisposeDesc(&target) }

            // A wildcard event can be checked but not asked about, so use the Get Data event every
            // `tell application "System Events" to get …` script sends.
            let result = AEDeterminePermissionToAutomateTarget(
                &target,
                AEEventClass(kAECoreSuite),
                AEEventID(kAEGetData),
                askUserIfNeeded
            )
            switch Int(result) {
            case Int(noErr):
                return .granted
            case Int(errAEEventNotPermitted):
                return .denied
            case Int(errAEEventWouldRequireUserConsent):
                return .notDetermined
            case Int(procNotFound):
                // System Events isn't running, so macOS won't say; this is the normal idle case.
                return .unknown
            default:
                logger.error("AEDeterminePermissionToAutomateTarget returned \(result)")
                return .unknown
            }
        }.value
    }

    /// Reading the TCC database never prompts; it only succeeds with Full Disk Access.
    private nonisolated static func fullDiskAccessStatus() async -> SystemPermissionStatus {
        await Task.detached(priority: .utility) {
            let database = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
            guard FileManager.default.fileExists(atPath: database.path) else {
                return SystemPermissionStatus.unknown
            }
            do {
                let handle = try FileHandle(forReadingFrom: database)
                try handle.close()
                return .granted
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                return .notGranted
            } catch {
                logger.error("Full Disk Access check failed: \(error.localizedDescription, privacy: .public)")
                return .unknown
            }
        }.value
    }

    /// Listing the folder is what makes macOS prompt; the call blocks until the user answers.
    private nonisolated static func probeFolder(_ directory: FileManager.SearchPathDirectory) async -> SystemPermissionStatus {
        await Task.detached(priority: .userInitiated) {
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
                logger.error("No user folder for search path \(directory.rawValue)")
                return SystemPermissionStatus.unknown
            }
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return .granted
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                return .denied
            } catch {
                logger.error("Folder probe for \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return .unknown
            }
        }.value
    }

    private static func status(from status: AVAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from authorization: CBManagerAuthorization) -> SystemPermissionStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .allowedAlways: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from status: EKAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        // Write-only lets a tool add events but not read them, which most CLI tools need.
        case .writeOnly: .notGranted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from status: CNAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .notGranted
        }
    }

    private static func status(from status: PHAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .limited: .notGranted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from status: CLAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from status: SFSpeechRecognizerAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func status(from access: IOHIDAccessType) -> SystemPermissionStatus {
        switch access {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }
}

/// Keeps a location manager alive until macOS reports a decision.
@MainActor
private final class LocationAuthorizationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let wait = PromptWait()

    func run() async {
        await wait.run {
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            // The delegate also fires with the current value as soon as it's attached.
            guard status != .notDetermined else { return }
            wait.finish()
        }
    }
}

/// Creating a central manager is what makes macOS ask for Bluetooth; the first state update
/// arrives once the user has answered.
@MainActor
private final class BluetoothAuthorizationRequest: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let wait = PromptWait()

    func run() async {
        await wait.run {
            manager = CBCentralManager(delegate: self, queue: .main)
        }
        manager = nil
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            wait.finish()
        }
    }
}

/// Waits for a delegate callback that only arrives once the user answers a prompt. The wait is
/// bounded because a prompt left open would otherwise keep the row's spinner going for good; the
/// caller re-reads the status either way, so giving up early only shows "Not requested" again.
@MainActor
private final class PromptWait {
    private static let timeout: Duration = .seconds(120)

    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(_ start: () -> Void) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.timeout)
                } catch {
                    // Cancelled because the answer arrived first.
                    return
                }
                self?.finish()
            }
            start()
        }
    }

    func finish() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume()
        continuation = nil
    }
}

/// What the local network probe has seen so far, reduced to the one decision that matters: has
/// macOS answered yet, and how.
enum LocalNetworkProbeEvent: Equatable, Sendable {
    case ready
    case policyDenied
    case resultsChanged
    case failed
    case timedOut

    /// The probe's answer, or nil to keep waiting.
    ///
    /// While the prompt is open macOS reports policy-denied, and it keeps doing so after a denial.
    /// Reaching `ready` or seeing results at any point, before or after that, means access is
    /// allowed. Only a probe that ends without either can be read as denied.
    static func outcome(of event: LocalNetworkProbeEvent, sawPolicyDenied: Bool) -> SystemPermissionStatus? {
        switch event {
        case .ready, .resultsChanged:
            .granted
        case .policyDenied:
            nil
        case .failed, .timedOut:
            sawPolicyDenied ? .denied : .unknown
        }
    }
}

/// Browsing for a Bonjour service is the lightest thing that makes macOS ask for local network
/// access.
private final class LocalNetworkProbe: @unchecked Sendable {
    private static let policyDenied: Int32 = -65570
    private static let timeoutSeconds = 30

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.local-network-probe")
    private var continuation: CheckedContinuation<SystemPermissionStatus, Never>?
    private var browser: NWBrowser?
    private var sawPolicyDenied = false

    func run() async -> SystemPermissionStatus {
        await withCheckedContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    private func start(_ continuation: CheckedContinuation<SystemPermissionStatus, Never>) {
        self.continuation = continuation
        let browser = NWBrowser(
            for: .bonjour(type: SystemPermission.localNetworkProbeServiceType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                handle(.ready)
            case .waiting(let error):
                if case .dns(let code) = error, code == Self.policyDenied {
                    handle(.policyDenied)
                }
            case .failed:
                handle(.failed)
            case .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [self] _, _ in handle(.resultsChanged) }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(Self.timeoutSeconds)) { [self] in
            handle(.timedOut)
        }
    }

    private func handle(_ event: LocalNetworkProbeEvent) {
        if event == .policyDenied { sawPolicyDenied = true }
        guard let status = LocalNetworkProbeEvent.outcome(of: event, sawPolicyDenied: sawPolicyDenied) else { return }
        finish(status)
    }

    private func finish(_ status: SystemPermissionStatus) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel()
        browser = nil
        continuation.resume(returning: status)
    }
}
#endif
