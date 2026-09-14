import Foundation
import MyTermRemoteProtocol
import Observation
import UserNotifications

/// The `userInfo` key carrying the tab a banner belongs to. Read back from a nonisolated delegate
/// callback, so it sits outside the main-actor type.
private enum AgentNotificationKey {
    static let tab = "tabID"
}

/// Posts a banner when an agent needs the person and the tab is not in front of them, and opens
/// the tab when the banner is tapped.
///
/// Owns the person's switch as well, because turning it on is the moment to ask iOS for
/// permission: a request at launch, before the app has shown anything worth being told about, is
/// the one most people refuse.
@MainActor
@Observable
final class AgentNotifier: NSObject {
    /// Off until asked for, as on the Mac. Turning it on asks iOS for permission.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
            if isEnabled {
                requestAuthorization()
            }
        }
    }

    private static let isEnabledKey = "remote.agentNotifications"
    /// Written by a tap and read by `ConnectionView`, which already opens this tab as soon as it
    /// has a tree. Going through defaults is what lets a tap on a cold app survive the launch.
    private static let openTabKey = "remote.openTab"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        super.init()
        center.delegate = self
    }

    func apply(_ action: RemoteAgentNotificationAction) {
        switch action {
        case .post(let content):
            post(content)
        case .withdraw(let tabID):
            withdraw(tabID: tabID)
        case .none:
            break
        }
    }

    /// Takes a tab's banner down: the person reached the tab, or the Mac did.
    func withdraw(tabID: String) {
        let identifier = Self.requestIdentifier(tabID: tabID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func requestAuthorization() {
        // `@Sendable` is load-bearing on every handler Notification Centre calls back. Without it
        // the closure takes this type's main-actor isolation, and Swift traps when the framework
        // runs it on its own queue.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable _, _ in }
    }

    private func post(_ content: RemoteAgentNotificationContent) {
        center.getNotificationSettings { @Sendable [weak self] settings in
            // Only the status crosses back to the main actor. The settings object itself is not
            // safe to send.
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    self.send(content)
                default:
                    // Not asked yet, refused, or turned off in Settings. The cook in the tree
                    // still shows it, and the switch's footer says where to look.
                    break
                }
            }
        }
    }

    private func send(_ notification: RemoteAgentNotificationContent) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.workspaceID
        content.userInfo = [AgentNotificationKey.tab: notification.tabID]
        // One banner per tab. A second report for the same tab replaces the first rather than
        // stacking beneath it, which is also what lets `withdraw` find it.
        center.add(UNNotificationRequest(
            identifier: Self.requestIdentifier(tabID: notification.tabID),
            content: content,
            trigger: nil
        ))
    }

    private static func requestIdentifier(tabID: String) -> String {
        "agent.\(tabID)"
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {
    /// Shown even with the app in front. The policy has already decided the tab is not on screen,
    /// and a banner over the workspace list is the whole point of that decision.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tabID = response.notification.request.content.userInfo[AgentNotificationKey.tab] as? String
        Task { @MainActor [weak self] in
            guard let self, let tabID else { return }
            self.defaults.set(tabID, forKey: Self.openTabKey)
        }
        completionHandler()
    }
}
