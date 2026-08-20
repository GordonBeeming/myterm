import AppKit
import MyTermCore
import SwiftUI
import UserNotifications

@MainActor
protocol AgentNotificationPosting: AnyObject {
    /// Called when the user clicks a banner, so the app can bring that tab forward.
    var openTab: ((WorkspaceID, TabID) -> Void)? { get set }

    func requestAuthorization()
    func post(_ notification: AgentNotification)
}

/// Posts agent banners through Notification Centre, and brings the tab forward when one is clicked.
/// The `userInfo` keys carrying the tab a banner belongs to. Read back from a nonisolated
/// delegate callback, so they sit outside the main-actor type.
private enum AgentNotificationKey {
    static let workspace = "workspaceID"
    static let tab = "tabID"
}

@MainActor
final class UserNotificationPoster: NSObject, AgentNotificationPosting {
    var openTab: ((WorkspaceID, TabID) -> Void)?

    private let center: UNUserNotificationCenter
    /// One file per colour, written once and reused. Notification Centre reads the attachment from
    /// disk when the banner is shown, so the file has to outlive the call that posts it.
    private var swatchURLs: [WorkspaceColor: URL] = [:]

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notification: AgentNotification) {
        center.getNotificationSettings { settings in
            // Only the status crosses back to the main actor. The settings object itself is not
            // safe to send.
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .notDetermined:
                    self.requestAuthorization()
                case .authorized, .provisional:
                    self.send(notification)
                default:
                    // Denied, or turned off in System Settings. The cook in the tab still shows it.
                    break
                }
            }
        }
    }

    private func send(_ notification: AgentNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // Banners for one workspace stack together rather than filling the corner of the screen.
        content.threadIdentifier = notification.workspaceID.rawValue.uuidString
        content.userInfo = [
            AgentNotificationKey.workspace: notification.workspaceID.rawValue.uuidString,
            AgentNotificationKey.tab: notification.tabID.rawValue.uuidString,
        ]
        if let color = notification.color, let attachment = swatchAttachment(for: color) {
            content.attachments = [attachment]
        }
        center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// A plain square of the folder's colour. Notification Centre has no tint of its own, so the
    /// attachment thumbnail is the only place the colour can go.
    private func swatchAttachment(for color: WorkspaceColor) -> UNNotificationAttachment? {
        guard let url = swatchURL(for: color) else { return nil }
        return try? UNNotificationAttachment(identifier: color.rawValue, url: url)
    }

    private func swatchURL(for color: WorkspaceColor) -> URL? {
        if let existing = swatchURLs[color], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        let side = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(color.swiftUIColor).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
            xRadius: CGFloat(side) / 5,
            yRadius: CGFloat(side) / 5
        ).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-\(color.rawValue).png", directoryHint: .notDirectory)
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        swatchURLs[color] = url
        return url
    }
}

extension UserNotificationPoster: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let workspace = (userInfo[AgentNotificationKey.workspace] as? String).flatMap(UUID.init(uuidString:))
        let tab = (userInfo[AgentNotificationKey.tab] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let workspace, let tab else { return }
            NSApp.activate(ignoringOtherApps: true)
            self?.openTab?(WorkspaceID(rawValue: workspace), TabID(rawValue: tab))
        }
        // The handler only tells the system the response was taken, so it does not wait for the
        // window to come forward.
        completionHandler()
    }
}
