import Foundation

/// A macOS privacy permission that programs running inside MyTerm may need.
///
/// macOS checks a pane's child processes against MyTerm as the responsible app, so MyTerm has to
/// declare the usage string and hardened-runtime entitlement for anything those programs touch,
/// and a grant made here applies to every program started in a pane.
public enum SystemPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case camera
    case bluetooth
    case calendars
    case reminders
    case contacts
    case photos
    case location
    case speechRecognition
    case desktopFolder
    case documentsFolder
    case downloadsFolder
    case removableVolumes
    case networkVolumes
    case localNetwork
    case fullDiskAccess
    case automation
    case accessibility
    case screenRecording
    case inputMonitoring

    public var id: String { rawValue }

    /// The Bonjour type the local network probe browses. It has to appear in `NSBonjourServices`.
    public static let localNetworkProbeServiceType = "_ssh._tcp"

    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case devices
        case personalData
        case filesAndNetwork
        case control

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .devices: "Devices"
            case .personalData: "Personal data"
            case .filesAndNetwork: "Files and network"
            case .control: "Control"
            }
        }

        public var permissions: [SystemPermission] {
            SystemPermission.allCases.filter { $0.group == self }
        }
    }

    public enum GrantStyle: Sendable {
        /// macOS shows its own prompt the first time the app asks.
        case prompt
        /// There is no status API; touching the resource prompts once and reports the outcome.
        case probe
        /// The only way to grant it is a toggle in System Settings.
        case systemSettingsOnly
        /// macOS asks when a program first uses it; there is nothing to request ahead of time.
        case informational
    }

    public var group: Group {
        switch self {
        case .microphone, .camera, .bluetooth:
            .devices
        case .calendars, .reminders, .contacts, .photos, .location, .speechRecognition:
            .personalData
        case .desktopFolder, .documentsFolder, .downloadsFolder, .removableVolumes, .networkVolumes,
             .localNetwork, .fullDiskAccess:
            .filesAndNetwork
        case .automation, .accessibility, .screenRecording, .inputMonitoring:
            .control
        }
    }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .bluetooth: "Bluetooth"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .location: "Location"
        case .speechRecognition: "Speech recognition"
        case .desktopFolder: "Desktop folder"
        case .documentsFolder: "Documents folder"
        case .downloadsFolder: "Downloads folder"
        case .removableVolumes: "Removable volumes"
        case .networkVolumes: "Network volumes"
        case .localNetwork: "Local network"
        case .fullDiskAccess: "Full Disk Access"
        case .automation: "Automation"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen recording"
        case .inputMonitoring: "Input monitoring"
        }
    }

    public var detail: String {
        switch self {
        case .microphone:
            "Voice input in coding agents, audio recording, and speech-to-text tools."
        case .camera:
            "Photo and video capture tools, such as imagesnap or ffmpeg."
        case .bluetooth:
            "Tools that list or connect Bluetooth devices, such as blueutil."
        case .calendars:
            "Tools that read or add calendar events, such as icalBuddy."
        case .reminders:
            "Tools that read or add reminders."
        case .contacts:
            "Tools that look up people in Contacts."
        case .photos:
            "Tools that export or process images from your photo library."
        case .location:
            "Tools that use your location, such as weather or time zone lookups."
        case .speechRecognition:
            "Tools that use Apple's speech recognition for dictation."
        case .desktopFolder:
            "Programs that read or write files on your Desktop."
        case .documentsFolder:
            "Programs that read or write files in Documents."
        case .downloadsFolder:
            "Programs that read or write files in Downloads."
        case .removableVolumes:
            "macOS asks the first time a program reads a removable drive."
        case .networkVolumes:
            "macOS asks the first time a program reads a network share."
        case .localNetwork:
            "Connections to other machines, dev servers, and devices on your network."
        case .fullDiskAccess:
            "Programs that read protected data such as Mail, Messages, or other apps' containers."
        case .automation:
            "Scripts that control other apps with osascript. MyTerm checks System Events here; other apps ask on first use."
        case .accessibility:
            "Tools that read or drive other apps' windows and controls."
        case .screenRecording:
            "Screenshot and screen capture tools."
        case .inputMonitoring:
            "Tools that watch keyboard or mouse input, such as key remappers."
        }
    }

    public var grantStyle: GrantStyle {
        switch self {
        case .microphone, .camera, .bluetooth, .calendars, .reminders, .contacts, .photos, .location,
             .speechRecognition, .accessibility, .screenRecording, .inputMonitoring:
            .prompt
        case .desktopFolder, .documentsFolder, .downloadsFolder, .localNetwork, .automation:
            .probe
        case .fullDiskAccess:
            .systemSettingsOnly
        case .removableVolumes, .networkVolumes:
            .informational
        }
    }

    /// The `Privacy_*` anchor in System Settings' Privacy & Security pane.
    public var systemSettingsAnchor: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .bluetooth: "Privacy_Bluetooth"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .photos: "Privacy_Photos"
        case .location: "Privacy_LocationServices"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .desktopFolder, .documentsFolder, .downloadsFolder, .removableVolumes, .networkVolumes:
            "Privacy_FilesAndFolders"
        case .localNetwork: "Privacy_LocalNetwork"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .automation: "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    public var systemSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(systemSettingsAnchor)")
    }

    /// Usage strings macOS needs before it will prompt for this permission.
    public var requiredInfoPlistKeys: [String] {
        switch self {
        case .microphone: ["NSMicrophoneUsageDescription"]
        case .camera: ["NSCameraUsageDescription"]
        case .bluetooth: ["NSBluetoothAlwaysUsageDescription"]
        case .calendars: ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"]
        case .reminders: ["NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription"]
        case .contacts: ["NSContactsUsageDescription"]
        case .photos: ["NSPhotoLibraryUsageDescription"]
        case .location: ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
        case .speechRecognition: ["NSSpeechRecognitionUsageDescription"]
        case .desktopFolder: ["NSDesktopFolderUsageDescription"]
        case .documentsFolder: ["NSDocumentsFolderUsageDescription"]
        case .downloadsFolder: ["NSDownloadsFolderUsageDescription"]
        case .removableVolumes: ["NSRemovableVolumesUsageDescription"]
        case .networkVolumes: ["NSNetworkVolumesUsageDescription"]
        // The Bonjour type the probe browses has to be declared, or macOS refuses the browse
        // instead of prompting. It limits only MyTerm's own browsing; programs in a pane are
        // separate processes and don't read MyTerm's Info.plist.
        case .localNetwork: ["NSLocalNetworkUsageDescription", "NSBonjourServices"]
        case .automation: ["NSAppleEventsUsageDescription"]
        case .fullDiskAccess, .accessibility, .screenRecording, .inputMonitoring: []
        }
    }

    /// Hardened-runtime entitlements without which macOS denies the request without prompting.
    public var requiredEntitlements: [String] {
        switch self {
        case .microphone: ["com.apple.security.device.audio-input"]
        case .camera: ["com.apple.security.device.camera"]
        case .calendars, .reminders: ["com.apple.security.personal-information.calendars"]
        case .contacts: ["com.apple.security.personal-information.addressbook"]
        case .photos: ["com.apple.security.personal-information.photos-library"]
        case .location: ["com.apple.security.personal-information.location"]
        case .automation: ["com.apple.security.automation.apple-events"]
        case .bluetooth, .speechRecognition, .desktopFolder, .documentsFolder, .downloadsFolder,
             .removableVolumes, .networkVolumes, .localNetwork, .fullDiskAccess, .accessibility,
             .screenRecording, .inputMonitoring:
            []
        }
    }

    /// The title of the button that asks macOS, or nil when asking again would do nothing.
    public func requestButtonTitle(for status: SystemPermissionStatus) -> String? {
        switch grantStyle {
        case .prompt:
            switch status {
            case .notDetermined, .notGranted: "Grant"
            case .granted, .denied, .restricted, .unknown, .informational: nil
            }
        case .probe:
            // A probe only prompts the first time, but running it again still reports the current
            // decision. That's the only way to notice a grant revoked in System Settings, so it
            // stays available once macOS has answered either way.
            switch status {
            case .unknown, .notDetermined: "Grant"
            case .granted, .denied, .notGranted: "Check Again"
            case .restricted, .informational: nil
            }
        case .systemSettingsOnly, .informational:
            nil
        }
    }
}

public enum SystemPermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    /// Off, but macOS doesn't say whether it was never asked or turned down.
    case notGranted
    /// Blocked by a configuration profile or parental controls.
    case restricted
    /// Not checked yet, because checking would itself prompt.
    case unknown
    /// Nothing to check or request ahead of time.
    case informational

    public var label: String {
        switch self {
        case .notDetermined: "Not requested"
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notGranted: "Off"
        case .restricted: "Restricted"
        case .unknown: "Not checked"
        case .informational: "Asks on first use"
        }
    }
}
