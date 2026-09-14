import AppKit
import MyTermPlatform
import Observation
import SwiftUI

@main
struct MyTermApp: App {
    @NSApplicationDelegateAdaptor(MyTermApplicationDelegate.self) private var applicationDelegate
    @State private var startup: MyTermStartup

    init() {
        let startup = MyTermStartup()
        _startup = State(initialValue: startup)
        applicationDelegate.connect(startup: startup)
    }

    var body: some Scene {
        Window(MyTermChannel.active.displayName, id: "main") {
            MyTermRootView(startup: startup)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    applicationDelegate.connect(startup: startup)
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
    private var startup: MyTermStartup?
    private var secondaryTask: Task<Void, Never>?
    private var secondaryURLs: [URL] = []
    private var confirmedInstanceReplacement = false

    override init() {
        restoreWindowAfterCancelledTermination = Self.restoreMainWindow
        super.init()
    }

    init(restoreWindowAfterCancelledTermination: @escaping @MainActor (NSApplication) -> Void) {
        self.restoreWindowAfterCancelledTermination = restoreWindowAfterCancelledTermination
        super.init()
    }

    func connect(startup: MyTermStartup) {
        self.startup = startup
        guard !startup.isSecondary else {
            secondaryURLs.append(contentsOf: urlDispatcher.takePendingURLs())
            presentSecondaryDecision()
            return
        }
        connect(model: startup.model)
        startup.lease?.setOpenURLsHandler { [weak self] urls in
            guard let self else { return }
            self.urlDispatcher.dispatch(urls)
            if urls.isEmpty || Self.shouldActivate(for: urls) {
                Self.restoreMainWindow(NSApp)
            }
        }
        startup.lease?.setShutdownHandler { [weak self] in
            self?.prepareForConfirmedInstanceReplacement()
            NSApp.terminate(nil)
        }
    }

    func connect(model: AppModel?) {
        self.model = model
        urlDispatcher.connect(handler: model)
        model?.startAgentNotifications()
        model?.startCompanionHostIfEnabled()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    private func presentSecondaryDecision() {
        guard secondaryTask == nil, let startup, startup.isSecondary else { return }
        secondaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.secondaryTask = nil }
            let startupGraceDeadline = ProcessInfo.processInfo.systemUptime + 10
            while !Task.isCancelled {
                do {
                    let urls = self.secondaryURLs
                    let coordinator = startup.coordinator
                    _ = try await Task.detached { try coordinator.probe(urls: urls) }.value
                    self.secondaryURLs.removeFirst(min(urls.count, self.secondaryURLs.count))
                    if !self.secondaryURLs.isEmpty { continue }
                    NSApp.terminate(nil)
                    return
                } catch {
                    let instanceError = error as? SingleInstanceError
                    if [.ownerStarting, .ownerUnresponsive, .ownerUnknown].contains(instanceError),
                       ProcessInfo.processInfo.systemUptime < startupGraceDeadline {
                        do { try await Task.sleep(for: .milliseconds(250)) }
                        catch { return }
                        continue
                    }
                    if instanceError != .ownerUnresponsive && instanceError != .ownerStarting {
                        NSAlert(error: error).runModal()
                        NSApp.terminate(nil)
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "myterm appears hung"
                    alert.informativeText = "The existing app did not respond. Starting a new instance will terminate the previous app and may lose its running terminal work."
                    alert.addButton(withTitle: "Retry")
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Start New Instance")
                    alert.buttons[2].hasDestructiveAction = true
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        continue
                    case .alertThirdButtonReturn:
                        do {
                            let coordinator = startup.coordinator
                            let lease = try await Task.detached { try coordinator.replaceOwner() }.value
                            try startup.becomeOwner(lease: lease)
                            self.connect(startup: startup)
                            self.urlDispatcher.dispatch(self.secondaryURLs)
                            self.secondaryURLs.removeAll()
                            Self.restoreMainWindow(NSApp)
                            return
                        } catch {
                            let failure = NSAlert(error: error)
                            failure.runModal()
                        }
                    default:
                        NSApp.terminate(nil)
                        return
                    }
                }
            }
        }
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

    // The replacement launch already obtained explicit confirmation that terminal work will end.
    // Let applicationWillTerminate persist and tear down once, without a second modal on the old app.
    func prepareForConfirmedInstanceReplacement() {
        confirmedInstanceReplacement = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmedInstanceReplacement { return .terminateNow }
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
        if startup?.isSecondary == true {
            secondaryURLs.append(contentsOf: urls)
            presentSecondaryDecision()
            return
        }
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

    func takePendingURLs() -> [URL] {
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
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
    private(set) var model: AppModel?
    private(set) var errorDescription: String?
    private(set) var isSecondary = false
    let coordinator: SingleInstanceCoordinator
    private(set) var lease: SingleInstanceLease?
    private let supportDirectory: URL

    init() {
        let channel = MyTermChannel.active
        if let override = ProcessInfo.processInfo.environment["MYTERM_APPLICATION_SUPPORT_DIRECTORY"], !override.isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        }
        coordinator = SingleInstanceCoordinator(configuration: SingleInstanceConfiguration(
            profile: channel.bundleIdentifier,
            directory: supportDirectory.appendingPathComponent(channel.displayName, isDirectory: true)
        ))
        do {
            if let acquired = try coordinator.acquire() {
                try becomeOwner(lease: acquired)
            } else {
                isSecondary = true
                errorDescription = "Connecting to the existing myterm app…"
            }
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    func becomeOwner(lease: SingleInstanceLease) throws {
        do {
            let instance = try AppModel(channel: MyTermChannel.active, applicationSupportDirectory: supportDirectory)
            self.lease = lease
            model = instance
            isSecondary = false
            errorDescription = nil
        } catch {
            lease.stop()
            errorDescription = error.localizedDescription
            throw error
        }
    }
}
