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
            if let model = startup.model {
                SettingsView(model: model)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

@MainActor
final class MyTermApplicationDelegate: NSObject, NSApplicationDelegate {
    private let urlDispatcher = MyTermURLDispatcher()
    private weak var model: AppModel?

    func connect(model: AppModel?) {
        self.model = model
        urlDispatcher.connect(handler: model)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shouldTerminateApplication() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistTerminalSnapshots()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urlDispatcher.dispatch(urls)
        application.activate(ignoringOtherApps: true)
    }
}

@MainActor
protocol MyTermURLHandling: AnyObject {
    func open(_ urls: [URL])
}

extension AppModel: MyTermURLHandling {}

@MainActor
final class MyTermURLDispatcher {
    private weak var handler: (any MyTermURLHandling)?
    private var pendingURLs = [URL]()

    func connect(handler: (any MyTermURLHandling)?) {
        self.handler = handler
        guard let handler, !pendingURLs.isEmpty else { return }
        handler.open(pendingURLs)
        pendingURLs.removeAll()
    }

    func dispatch(_ urls: [URL]) {
        guard let handler else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        handler.open(urls)
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
