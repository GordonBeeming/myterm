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
    private let restoreWindowAfterCancelledTermination: @MainActor (NSApplication) -> Void
    private weak var model: AppModel?

    override init() {
        restoreWindowAfterCancelledTermination = Self.restoreMainWindow
        super.init()
    }

    init(restoreWindowAfterCancelledTermination: @escaping @MainActor (NSApplication) -> Void) {
        self.restoreWindowAfterCancelledTermination = restoreWindowAfterCancelledTermination
        super.init()
    }

    func connect(model: AppModel?) {
        self.model = model
        urlDispatcher.connect(handler: model)
        model?.startAgentNotifications()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Coming back to the app counts as reading whatever is on screen, the same as reaching the
        // tab does. Without this the cook would stay blue in the tab the user is already looking at.
        model?.markVisibleTabsAsRead()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.shouldTerminateApplication() != false else {
            restoreWindowAfterCancelledTermination(sender)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistBrowserURLs()
        // Snapshots read live session content, so they have to be captured before the sessions are torn down.
        model?.persistTerminalSnapshots()
        model?.terminateTerminalSessions()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urlDispatcher.dispatch(urls)
        guard Self.shouldActivate(for: urls) else { return }
        application.activate(ignoringOtherApps: true)
    }

    /// Whether an incoming batch of URLs is worth bringing MyTerm to the front for.
    ///
    /// A workspace browser route comes from a pane, often while the user is working in another app
    /// entirely, so taking focus for it is the interruption this exists to prevent. Every other kind
    /// of URL reaches the app because the user asked for it somewhere else, and still comes forward.
    static func shouldActivate(for urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        return !urls.allSatisfy { MyTermBrowserLauncher.browserDestination(from: $0) != nil }
    }

    private static func restoreMainWindow(_ application: NSApplication) {
        Task { @MainActor in
            guard let window = application.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
        }
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
