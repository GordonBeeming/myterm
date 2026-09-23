import SwiftUI
import UIKit
@preconcurrency import UserNotifications

@main
struct MyTermCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @State private var services = CompanionServices()

    var body: some Scene {
        WindowGroup {
            Group {
                if UITestConfiguration.showsTerminalFixture {
                    TerminalUITestFixture()
                } else if UITestConfiguration.showsTouchFixture {
                    TerminalTouchUITestFixture()
                } else if UITestConfiguration.showsWorkspaceFixture {
                    WorkspaceUITestFixture()
                } else {
                    SceneRootView(services: services)
                }
            }
                .task { await services.load() }
                .onReceive(NotificationCenter.default.publisher(for: .myTermAPNSToken)) { note in
                    guard let token = note.object as? Data else { return }
                    Task { await services.handleAPNSToken(token) }
                }
                .onOpenURL { url in
                    guard url.scheme == AppConfiguration.urlScheme, url.host == "pair" else { return }
                    Task {
                        do { _ = try await services.pair(url: url) }
                        catch { services.errorMessage = error.localizedDescription }
                    }
                }
        }
    }
}

final class CompanionAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // Cleared before any view reads it, so a fixture run starts without remembered panes.
        if UITestConfiguration.forgetsPaneSelection {
            PaneSelectionStore().clear(for: WorkspaceUITestFixture.workspace.id)
        }
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in APNSTokenBroker.shared.receiveToken(.success(deviceToken)) }
        NotificationCenter.default.post(name: .myTermAPNSToken, object: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in APNSTokenBroker.shared.receiveToken(.failure(error)) }
        NotificationCenter.default.post(name: .myTermAPNSToken, object: error)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if receiveEnrollmentChallenge(userInfo) || receiveTokenUpdate(userInfo) {
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        if receiveEnrollmentChallenge(response.notification.request.content.userInfo)
            || receiveTokenUpdate(response.notification.request.content.userInfo) { return }
        let info = response.notification.request.content.userInfo
        guard let relayOrigin = info["relay_origin"] as? String,
              let account = info["account_id"] as? String,
              let accountID = UUID(uuidString: account),
              let host = info["host_id"] as? String,
              let hostID = UUID(uuidString: host) else { return }
        let workspaceID = (response.notification.request.content.userInfo["workspace_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let tabID = (response.notification.request.content.userInfo["tab_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let sessionID = (response.notification.request.content.userInfo["session_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let connectionID = SavedConnectionID(relayOrigin: relayOrigin,
                                             accountID: accountID, hostID: hostID)
        let destination = NotificationDestination(connectionID: connectionID,
                                                  workspaceID: workspaceID,
                                                  tabID: tabID,
                                                  sessionID: sessionID)
        Task { @MainActor in
            NotificationRouteBroker.shared.publish(destination)
            NotificationCenter.default.post(name: .myTermNotificationRoute, object: nil)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if receiveEnrollmentChallenge(notification.request.content.userInfo)
            || receiveTokenUpdate(notification.request.content.userInfo) {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    @discardableResult
    private func receiveEnrollmentChallenge(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let enrollment = userInfo["enrollment"] as? [String: Any],
              let challenge = enrollment["challenge"] as? String,
              let data = Data(base64URL: challenge) else { return false }
        Task { @MainActor in APNSTokenBroker.shared.receiveChallenge(data) }
        return true
    }

    @discardableResult
    private func receiveTokenUpdate(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let update = userInfo["token_update"] as? [String: Any],
              let idValue = update["challenge_id"] as? String,
              let id = UUID(uuidString: idValue),
              let challengeValue = update["challenge"] as? String,
              let challenge = Data(base64URL: challengeValue) else { return false }
        Task { @MainActor in
            APNSTokenBroker.shared.receiveTokenUpdate(challengeID: id, challenge: challenge)
        }
        return true
    }
}
