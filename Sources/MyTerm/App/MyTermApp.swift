import AppKit
import Observation
import SwiftUI

@main
struct MyTermApp: App {
    @NSApplicationDelegateAdaptor(MyTermApplicationDelegate.self) private var applicationDelegate
    @State private var startup = MyTermStartup()

    var body: some Scene {
        WindowGroup(MyTermChannel.active.displayName) {
            MyTermRootView(startup: startup)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MyTermCommands(startup: startup)
        }
    }
}

@MainActor
final class MyTermApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

@MainActor
@Observable
final class MyTermStartup {
    let model: AppModel?
    let errorDescription: String?

    init() {
        do {
            model = try AppModel()
            errorDescription = nil
        } catch {
            model = nil
            errorDescription = error.localizedDescription
        }
    }
}
