import AppKit
import MyTermCore
import MyTermUpdating
import MyTermPlatform
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

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
                .onChange(of: startup.model != nil) { _, ready in
                    if ready { applicationDelegate.connect(startup: startup) }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MyTermCommands(startup: startup)
        }

        // A plain window rather than the Settings scene: SwiftUI keeps a Settings window at a fixed
        // size, and this one needs to grow.
        Window("Settings", id: SettingsWindow.id) {
            if let model = startup.model {
                SettingsView(model: model)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .defaultSize(width: 880, height: 720)
        .windowResizability(.contentMinSize)
        // The main scene owns the Global Settings command and its scope selection.
        .commandsRemoved()
    }
}

@MainActor
final class MyTermApplicationDelegate: NSObject, NSApplicationDelegate {
    private let urlDispatcher = MyTermURLDispatcher()
    private let restoreWindowAfterCancelledTermination: @MainActor (NSApplication) -> Void
    private weak var model: AppModel?
    private var startup: MyTermStartup?
    private var secondaryTask: Task<Void, Never>?
    private var quitPreparationTask: Task<Void, Never>?
    private var secondaryURLs: [URL] = []
    private var confirmedInstanceReplacement = false
    private var hasVerifiedCallbackRouting = false

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
        if startup.needsInstalledRelaunch {
            let pending = urlDispatcher.takePendingURLs() + secondaryURLs
            secondaryURLs.removeAll()
            Task { @MainActor in startup.restartInstalledCopy(urls: pending) }
            return
        }
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
        guard model != nil, !hasVerifiedCallbackRouting else { return }
        hasVerifiedCallbackRouting = true
        do {
            try ApplicationCallbackRouting.verify(
                applicationURL: Bundle.main.bundleURL,
                scheme: MyTermChannel.active.authenticationCallbackScheme)
        } catch {
            Logger(subsystem: MyTermChannel.active.bundleIdentifier, category: "callback-routing")
                .error("Could not verify this app's callback registration: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A restart or shut down can stop terminal helpers before this app is asked to quit.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.systemWillPowerOff() }
        }
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
                    do {
                        if Bundle.main.bundleIdentifier == ApplicationUpdate.bundleIdentifier,
                           try !ApplicationUpdate.runningCodeMatchesFile(Bundle.main.bundleURL) {
                            startup.restartInstalledCopy(urls: self.secondaryURLs)
                            return
                        }
                        if let lease = try startup.coordinator.acquire() {
                            try startup.becomeOwner(lease: lease)
                            if startup.needsInstalledRelaunch {
                                let pending = self.secondaryURLs + self.urlDispatcher.takePendingURLs()
                                self.secondaryURLs.removeAll()
                                startup.restartInstalledCopy(urls: pending)
                                return
                            }
                            self.connect(startup: startup)
                            self.urlDispatcher.dispatch(self.secondaryURLs)
                            self.secondaryURLs.removeAll()
                            return
                        }
                    } catch {
                        startup.recordStartupFailure(error.localizedDescription)
                        return
                    }
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

    /// Prepare a pending update asynchronously, then allow AppKit to terminate after the final save.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmedInstanceReplacement { return .terminateNow }
        if quitPreparationTask != nil { return .terminateLater }
        guard model?.shouldTerminateApplication() != false else {
            restoreWindowAfterCancelledTermination(sender)
            return .terminateCancel
        }
        if let model, model.updates.stagedUpdate != nil, model.updates.installation != .running,
           !model.isRestartingAfterUpdate, !model.isSystemPoweringOff {
            quitPreparationTask = Task { @MainActor [weak self] in
                defer { self?.quitPreparationTask = nil }
                do {
                    guard let helper = try await model.prepareUpdateQuitProcess(relaunch: false) else {
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    helper.standardInput = FileHandle.nullDevice
                    helper.standardOutput = FileHandle.nullDevice
                    helper.standardError = FileHandle.nullDevice
                    try helper.run()
                    model.isRestartingAfterUpdate = true
                    sender.reply(toApplicationShouldTerminate: true)
                } catch {
                    let reason = "The prepared update could not be applied. Kept the installed app. " + error.localizedDescription
                    model.updates.disarmPreparedUpdate(reason)
                    let errorFile = model.store.persistenceURL.deletingLastPathComponent().appendingPathComponent("update-install-error.txt")
                    do { try Data(reason.utf8).write(to: errorFile, options: .atomic) }
                    catch { model.updateRestartError = error.localizedDescription }
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistBrowserURLs()
        // Snapshots read live session content, so they have to be captured before the sessions are torn down.
        model?.persistTerminalSnapshots()
        model?.detachTerminalSessions()
        // Last, so it carries the snapshots and browser URLs the lines above just recorded.
        model?.persistWorkspaceStore()
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
        let urls = CompanionExternalBrowserAuthentication.shared
            .consumeAuthenticationCallbacks(from: urls)
        guard !urls.isEmpty else { return }
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
    private var startupTrial: ApplicationUpdatePlan?
    private var didConfirmStartup = false
    private var pendingUpdateNoticeURL: URL?

    /// A receipt is emitted only after a real app model and its main window have appeared.
    func markStartupSucceeded() {
        guard model != nil, !isSecondary, !didConfirmStartup else { return }
        if let startupTrial {
            do { try UpdateStartupTrial.report(.loaded, plan: startupTrial) }
            catch { model?.errorDescription = "Could not confirm update startup: \(error.localizedDescription)"; return }
            do { try UpdateStartupTrial.commit(startupTrial) }
            catch { model?.errorDescription = "The update started, but cleanup metadata could not be saved: \(error.localizedDescription)" }
        }
        didConfirmStartup = true
        if let notice = pendingUpdateNoticeURL {
            do { try FileManager.default.removeItem(at: notice); pendingUpdateNoticeURL = nil }
            catch { model?.errorDescription = (model?.errorDescription ?? "") + "\nCould not clear the update notice: \(error.localizedDescription)" }
        }
    }
    private var preferencesDomain: String {
        ProcessInfo.processInfo.environment["MYTERM_USER_DEFAULTS_SUITE"] ?? MyTermChannel.active.bundleIdentifier
    }
    private(set) var needsInstalledRelaunch = false
    private var isRelaunchScheduled = false
    func recordStartupFailure(_ message: String) { errorDescription = message }

    /// An executable already starting during a swap must never load data using the new bundle's metadata.
    func restartInstalledCopy(urls: [URL] = []) {
        guard !isRelaunchScheduled else { return }
        isRelaunchScheduled = true
        do {
            let app = Bundle.main.bundleURL
            try ApplicationUpdate.verifyInstalledIdentity(app)
            let agent = app.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent")
            try ApplicationUpdate.verifySignature(agent, identifier: ApplicationUpdate.bundleIdentifier + ".update-agent")
            let helper = Process()
            helper.executableURL = agent
            helper.arguments = ["--open-after-exit", String(ProcessInfo.processInfo.processIdentifier), app.path]
                + urls.filter { $0.scheme != nil }.map(\.absoluteString)
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            NSApp.terminate(nil)
            if helper.isRunning { helper.terminate() }
        } catch {
            isRelaunchScheduled = false
            errorDescription = "The installed app changed. Close and reopen it to finish the update. \(error.localizedDescription)"
        }
    }
    var isRecoveringToStable = false
    var recoveryUpdate: UpdateController?
    var canRecoverToStable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MyTermReleaseChannel") as? String == "beta"
    }

    /// The channel escape hatch does not require a working beta AppModel.
    func recoverToStable() {
        guard !isRecoveringToStable else { return }
        let alert = NSAlert()
        alert.messageText = "Return to stable"
        alert.informativeText = "Choose the configuration for stable. If the beta configuration cannot load, your last stable snapshot is restored."
        alert.addButton(withTitle: "Restore Stable Configuration")
        alert.addButton(withTitle: "Try Beta Configuration")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        isRecoveringToStable = true
        Task { @MainActor in
            defer { isRecoveringToStable = false }
            do {
                guard let acquired = try coordinator.acquire() else {
                    throw ApplicationUpdateError.invalid("Another myterm instance is using this configuration. Close it before recovery.")
                }
                defer { acquired.stop() }
                let directory = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
                let updater = UpdateController(configurationDirectory: directory)
                recoveryUpdate = updater
                updater.selectChannel(.stable)
                updater.stableConfigurationChoice = response == .alertFirstButtonReturn ? .restoreStable : .tryBeta
                guard let release = (await updater.check()).release else {
                    throw ApplicationUpdateError.invalid("Could not find a stable recovery update. Check your connection and retry.")
                }
                await updater.install(release: release)
                guard updater.canRestartAfterUpdate else {
                    throw ApplicationUpdateError.invalid("Stable recovery could not be prepared: \(updater.installation)")
                }
                guard let helper = try await updater.preparedRestartProcess() else {
                    throw ApplicationUpdateError.invalid("The stable recovery installer was not prepared.")
                }
                helper.standardInput = FileHandle.nullDevice
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                try helper.run()
                NSApp.terminate(nil)
                if helper.isRunning { helper.terminate() }
            } catch { errorDescription = error.localizedDescription }
        }
    }

    func showConfigurationFolder() {
        let directory = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
        NSWorkspace.shared.open(directory)
    }

    /// Recovery is available even when configuration failure prevented construction of AppModel.
    func restoreConfigurationBackup() {
        let panel = NSOpenPanel()
        // Migration/recovery backups keep their .v1-backup and .recovery-backup suffixes.
        // The decoder, rather than the filename extension, validates the chosen file.
        panel.directoryURL = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a saved stable configuration snapshot or workspace JSON backup. The current bytes will be preserved first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let acquired = try coordinator.acquire() else {
                errorDescription = "Another myterm instance is using this configuration. Close it before restoring a backup."
                return
            }
            do {
                let directory = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
                let installed = UpdateCheck.Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "MyTermReleaseChannel") as? String ?? "stable") ?? .stable
                try ChannelConfigurationStore(directory: directory, preferencesDomain: preferencesDomain)
                    .restoreBackup(from: url, selectedChannel: installed)
                try becomeOwner(lease: acquired)
                model?.errorDescription = "Restored the selected configuration backup. The previous configuration was preserved."
            } catch { acquired.stop(); throw error }
        } catch { errorDescription = error.localizedDescription }
    }

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
            do { try startTrialMonitor() }
            catch { errorDescription = "Update startup monitoring was unavailable: \(error.localizedDescription)" }
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

    /// Start the detached monitor before loading configuration, so a failed first launch can recover its prior app.
    private func startTrialMonitor() throws {
        guard Bundle.main.bundleIdentifier == ApplicationUpdate.bundleIdentifier,
              try ApplicationUpdate.runningCodeMatchesFile(Bundle.main.bundleURL) else { return }
        let directory = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
        let channel = UpdateCheck.Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "MyTermReleaseChannel") as? String ?? "stable") ?? .stable
        guard let plan = try UpdateStartupTrial.pending(in: directory, app: Bundle.main.bundleURL,
            version: Bundle.main.shortVersionString, channel: channel) else { return }
        let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent")
        try ApplicationUpdate.verifySignature(agent, identifier: ApplicationUpdate.bundleIdentifier + ".update-agent")
        let monitor = Process()
        monitor.executableURL = agent
        monitor.arguments = ["--watch-trial", plan.manifestURL.path]
        monitor.standardInput = FileHandle.nullDevice
        monitor.standardOutput = FileHandle.nullDevice
        monitor.standardError = FileHandle.nullDevice
        try monitor.run()
    }

    /// Load configuration only while owning the profile lease, applying stable recovery before constructing the model.
    func becomeOwner(lease: SingleInstanceLease) throws {
        do {
            if Bundle.main.bundleIdentifier == ApplicationUpdate.bundleIdentifier,
               try !ApplicationUpdate.runningCodeMatchesFile(Bundle.main.bundleURL) {
                lease.stop()
                needsInstalledRelaunch = true
                errorDescription = "Opening the newly installed app…"
                return
            }
            let directory = MyTermChannel.active.persistenceURL(applicationSupportDirectory: supportDirectory).deletingLastPathComponent()
            let releaseChannel = UpdateCheck.Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "MyTermReleaseChannel") as? String ?? "stable") ?? .stable
            var updateNotices: [String] = []
            do {
                startupTrial = try UpdateStartupTrial.pending(in: directory, app: Bundle.main.bundleURL,
                    version: Bundle.main.shortVersionString, channel: releaseChannel)
                if let startupTrial { try UpdateStartupTrial.report(.starting, plan: startupTrial) }
            } catch {
                startupTrial = nil
                updateNotices.append("Update startup monitoring was unavailable; kept the installed app. \(error.localizedDescription)")
                do { try UpdateStartupTrial.quarantineRecord(in: directory) }
                catch { updateNotices.append("Could not archive the stale update marker: \(error.localizedDescription)") }
            }
            let updateError = directory.appendingPathComponent("update-install-error.txt")
            if FileManager.default.fileExists(atPath: updateError.path) {
                let handle = try FileHandle(forReadingFrom: updateError)
                defer { try? handle.close() }
                updateNotices.append(String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self))
                pendingUpdateNoticeURL = updateError
            }
            // Refresh before restored terminals can start an agent and load its hooks.
            var hookFailures: [String] = []
            for target in AgentHookTarget.all {
                let hooks = AgentHooksController(target: target)
                if case .failed(let message) = hooks.state {
                    hookFailures.append("Could not refresh \(target.displayName) hooks: \(message)")
                }
            }
            BrowserContextArtifacts.pruneExpired()
            let instance: AppModel
            if releaseChannel == .stable {
                let config = ChannelConfigurationStore(directory: directory, preferencesDomain: preferencesDomain)
                let (loaded, notice) = try config.loadStable {
                    try AppModel(channel: MyTermChannel.active, applicationSupportDirectory: supportDirectory)
                }
                instance = loaded
                if let notice { updateNotices.append(notice) }
            } else {
                instance = try AppModel(channel: MyTermChannel.active, applicationSupportDirectory: supportDirectory)
            }
            let notices = updateNotices + hookFailures
            if !notices.isEmpty { instance.errorDescription = notices.joined(separator: "\n") }
            self.lease = lease
            model = instance
            isSecondary = false
            errorDescription = nil
            if Bundle.main.bundleIdentifier == ApplicationUpdate.bundleIdentifier,
               ProcessInfo.processInfo.environment["MYTERM_USER_DEFAULTS_SUITE"] == nil,
               ProcessInfo.processInfo.environment["MYTERM_APPLICATION_SUPPORT_DIRECTORY"] == nil {
                let app = Bundle.main.bundleURL
                Task.detached {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    ApplicationUpdate.pruneCompletedUpdates(for: app)
                }
            }
        } catch {
            if let startupTrial {
                do { try UpdateStartupTrial.report(.failed, plan: startupTrial, message: error.localizedDescription) }
                catch { errorDescription = "Could not record failed startup: \(error.localizedDescription)" }
            }
            lease.stop()
            errorDescription = error.localizedDescription
            throw error
        }
    }
}
