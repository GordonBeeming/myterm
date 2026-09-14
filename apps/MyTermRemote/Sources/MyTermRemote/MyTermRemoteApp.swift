import SwiftUI
import UIKit

@main
struct MyTermRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The UI tests need a device that has never paired. Nothing else sets this.
        if ProcessInfo.processInfo.environment["MYTERM_REMOTE_RESET_STATE"] == "1",
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    var body: some Scene {
        WindowGroup {
            ConnectionView(notifier: appDelegate.notifier)
        }
    }
}

/// Exists to own the notifier from the first moment of the process.
///
/// A tap on a banner while the app is not running launches it, and iOS hands the tap to whatever
/// notification delegate is in place when launching finishes. A delegate installed by a view would
/// be too late for that, so the notifier is made here.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let notifier = AgentNotifier()
}
