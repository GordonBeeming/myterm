import AppKit
import Observation
import SwiftUI

@main
struct MyTermApp: App {
    @NSApplicationDelegateAdaptor(MyTermApplicationDelegate.self) private var applicationDelegate
    @State private var startup = MyTermStartup()

    var body: some Scene {
        Window(MyTermChannel.active.displayName, id: "main") {
            MyTermRootView(startup: startup)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    applicationDelegate.connect(model: startup.model)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MyTermCommands(startup: startup)
        }

        Settings {
            if let settings = startup.model?.browserSettings {
                BrowserSettingsView(settings: settings)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

@MainActor
final class MyTermApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var pendingURLs: [URL] = []

    func connect(model: AppModel?) {
        self.model = model
        guard let model, !pendingURLs.isEmpty else { return }
        model.open(pendingURLs)
        pendingURLs.removeAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.open(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        application.activate(ignoringOtherApps: true)
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
