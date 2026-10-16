import Foundation
import MyTermCore
import Observation

/// Checks GitHub for a newer release and works out how this copy should be upgraded.
///
/// Homebrew owns bundle replacement and its installation records; the app runs that upgrade
/// without a terminal and keeps its output available until the user restarts.
@MainActor
@Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case available(AppRelease)
        case failed(String)

        var release: AppRelease? {
            guard case .available(let release) = self else { return nil }
            return release
        }
    }

    /// How this copy of the app should be upgraded.
    enum UpgradeRoute: Equatable {
        /// Installed by Homebrew; the upgrade runs without a terminal.
        case homebrew(command: String)
        /// Anything else — a DMG drag, or a build from source. Send them to the release.
        case releasePage
    }

    enum Installation: Equatable {
        case ready
        case running
        case installed
        case failed(String)
    }

    typealias UpgradeRunner = @Sendable (String, @escaping @Sendable (Data) async -> Void) async throws -> Int32

    private(set) var installation: Installation = .ready
    private(set) var installationOutput = ""
    private var outputData = Data()
    private let runUpgrade: UpgradeRunner
    private let readInstalledVersion: @MainActor () throws -> String
    private(set) var verifiedInstalledVersion: AppVersion?

    static let caskToken = "gordonbeeming/tap/myterm"
    static let checkInterval: TimeInterval = 60 * 60 * 24
    /// The elapsed check is cheap, so poll often enough that a machine waking from sleep does not
    /// wait another whole interval before noticing it is due.
    private static let pollInterval: TimeInterval = 60 * 60

    private static let automaticChecksKey = "updates.automaticChecks"
    private static let lastCheckedAtKey = "updates.lastCheckedAt"
    private static let knownReleaseTagKey = "updates.knownRelease.tag"
    private static let knownReleaseURLKey = "updates.knownRelease.url"
    private static let skippedVersionKey = "updates.skippedVersion"

    private(set) var status: Status = .idle
    private(set) var lastCheckedAt: Date?
    /// A release the user chose not to be reminded about. Only that exact version goes quiet: a
    /// newer release brings the badge back.
    private(set) var skippedVersion: AppVersion?

    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            defaults.set(automaticallyChecks, forKey: Self.automaticChecksKey)
            if automaticallyChecks { startPolling() } else { stopPolling() }
        }
    }

    let currentVersion: String
    private let upgradeRoute: UpgradeRoute
    private let fetch: @Sendable (URL) async throws -> Data
    private let defaults: UserDefaults
    private let now: () -> Date
    private let poll = PollTimer()
    private var inFlightCheck: Task<Status, Never>?

    init(
        channel: MyTermChannel = .active,
        currentVersion: String = Bundle.main.shortVersionString,
        upgradeRoute: UpgradeRoute? = nil,
        defaults: UserDefaults? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil,
        runUpgrade: UpgradeRunner? = nil,
        installedVersion: (@MainActor () throws -> String)? = nil
    ) {
        let suiteName = environment["MYTERM_USER_DEFAULTS_SUITE"] ?? channel.bundleIdentifier
        let defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.runUpgrade = runUpgrade ?? Self.runHeadlessUpgrade
        self.readInstalledVersion = installedVersion ?? {
            // Bundle caches its Info.plist, including the old version after brew replaces it.
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let values = plist as? [String: Any],
                  let version = values["CFBundleShortVersionString"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return version
        }
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            return try await URLSession.shared.data(for: request).0
        }
        self.upgradeRoute = upgradeRoute ?? Self.detectUpgradeRoute()
        automaticallyChecks = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        skippedVersion = defaults.string(forKey: Self.skippedVersionKey).flatMap(AppVersion.init)
        // Only the check timestamp used to survive a relaunch, so a known update went quiet until
        // the next one fell due — up to a day of the app knowing and not saying.
        status = Self.restoredStatus(currentVersion: currentVersion, defaults: defaults)
        if automaticallyChecks { startPolling() }
    }

    /// The release the sidebar badge advertises. A skipped version stays in `status`, so "Check for
    /// Updates…" still reports it when asked.
    var unskippedRelease: AppRelease? {
        guard let release = status.release, release.version != skippedVersion else { return nil }
        return release
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.version
        defaults.set(release.version.description, forKey: Self.skippedVersionKey)
    }

    var isDueForCheck: Bool {
        guard let lastCheckedAt else { return true }
        return now().timeIntervalSince(lastCheckedAt) >= Self.checkInterval
    }

    /// The action offered alongside a found update.
    var upgradeActionTitle: String {
        switch upgradeRoute {
        case .homebrew: "Update Now"
        case .releasePage: "Open the Release"
        }
    }

    var upgradeCommand: String? {
        guard case .homebrew(let command) = upgradeRoute else { return nil }
        return command
    }

    var canRestartAfterUpdate: Bool {
        installation != .running && verifiedInstalledVersion != nil
    }

    func validateRestart() throws {
        guard let verifiedInstalledVersion,
              let diskVersion = AppVersion(try readInstalledVersion()), diskVersion >= verifiedInstalledVersion else {
            throw NSError(domain: "MyTermUpdate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The installed update could not be verified. Try installing again before restarting."
            ])
        }
    }

    func installation(for release: AppRelease) -> Installation {
        if installation == .running { return .running }
        if let verifiedInstalledVersion, verifiedInstalledVersion >= release.version { return .installed }
        return installation == .installed ? .ready : installation
    }

    /// Installation is independent of checking: a timer cannot erase progress or enable a second brew.
    func install(release requestedRelease: AppRelease? = nil) async {
        guard installation != .running, let command = upgradeCommand else { return }
        guard let release = requestedRelease ?? status.release else {
            installation = .failed("Check for an available update before installing.")
            return
        }
        guard installation(for: release) != .installed else { return }
        installation = .running
        outputData = Data()
        installationOutput = ""
        do {
            let code = try await runUpgrade(command) { [weak self] data in
                await self?.appendOutput(data)
            }
            guard code == 0 else {
                installation = .failed("Homebrew exited with status \(code). See the update log for details.")
                return
            }
            guard let version = AppVersion(try readInstalledVersion()), version >= release.version else {
                installation = .failed("Homebrew finished, but version \(release.version) is not installed yet. Try again once the cask is available.")
                return
            }
            verifiedInstalledVersion = version
            installation = .installed
        } catch {
            installation = .failed(error.localizedDescription)
        }
    }

    private func appendOutput(_ data: Data) {
        outputData.append(data)
        // A long Homebrew log should not grow the app's memory without bound.
        if outputData.count > 65_536 { outputData = Data(outputData.suffix(65_536)) }
        installationOutput = String(decoding: outputData, as: UTF8.self)
    }

    nonisolated static func runHeadlessUpgrade(
        command: String,
        output: @escaping @Sendable (Data) async -> Void
    ) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOMEBREW_NO_COLOR"] = "1"
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                await output(data)
            }
            pipe.fileHandleForReading.closeFile()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    /// Concurrent callers join the check already running rather than starting a second one.
    ///
    /// "Check Now" during an automatic poll would otherwise leave two checks in flight, and
    /// whichever response landed last would win — which is not necessarily the one asked for last.
    @discardableResult
    func check() async -> Status {
        if let inFlightCheck { return await inFlightCheck.value }
        let task = Task { @MainActor in await performCheck() }
        inFlightCheck = task
        let result = await task.value
        inFlightCheck = nil
        return result
    }

    private func performCheck() async -> Status {
        status = .checking
        do {
            let data = try await fetch(UpdateCheck.latestReleaseEndpoint)
            let availability = try UpdateCheck.availability(
                currentVersion: currentVersion,
                latestReleaseJSON: data
            )
            switch availability {
            case .upToDate(let version):
                status = .upToDate(version)
                forgetKnownRelease()
            case .available(let release):
                status = .available(release)
                remember(release)
            }
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        // Record the attempt either way. A failed check that immediately retried on every poll
        // would hammer the API while offline.
        lastCheckedAt = now()
        defaults.set(lastCheckedAt, forKey: Self.lastCheckedAtKey)
        return status
    }

    func checkIfDue() async {
        guard automaticallyChecks, isDueForCheck else { return }
        await check()
    }

    private func remember(_ release: AppRelease) {
        defaults.set(release.tag, forKey: Self.knownReleaseTagKey)
        defaults.set(release.releaseURL.absoluteString, forKey: Self.knownReleaseURLKey)
    }

    private func forgetKnownRelease() {
        defaults.removeObject(forKey: Self.knownReleaseTagKey)
        defaults.removeObject(forKey: Self.knownReleaseURLKey)
    }

    private static func restoredStatus(currentVersion: String, defaults: UserDefaults) -> Status {
        guard let tag = defaults.string(forKey: knownReleaseTagKey),
              let version = AppVersion(tag),
              let address = defaults.string(forKey: knownReleaseURLKey),
              let url = URL(string: address),
              let current = AppVersion(currentVersion),
              version > current else { return .idle }
        return .available(AppRelease(version: version, tag: tag, releaseURL: url))
    }

    private func startPolling() {
        poll.start(interval: Self.pollInterval) { [weak self] in
            await self?.checkIfDue()
        }
    }

    private func stopPolling() {
        poll.stop()
    }

    static func detectUpgradeRoute(
        bundleURL: URL = Bundle.main.bundleURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> UpgradeRoute {
        // Homebrew moves the app into /Applications and keeps its bookkeeping in the Caskroom.
        // Both have to be true: a Caskroom entry alone could belong to a copy that was since
        // replaced by a manual download.
        guard bundleURL.standardizedFileURL.path == "/Applications/myterm.app" else { return .releasePage }
        let prefixes = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
        guard let prefix = prefixes.first(where: { fileExists("\($0)/Caskroom/myterm") }) else { return .releasePage }
        return .homebrew(command: "\(prefix)/bin/brew upgrade --cask \(caskToken)")
    }
}

/// Owns the repeating timer outside the main actor, so it can still be torn down from `deinit`.
private final class PollTimer: @unchecked Sendable {
    private var timer: Timer?

    func start(interval: TimeInterval, tick: @escaping @Sendable () async -> Void) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { await tick() }
        }
        // Common mode, so the check still fires while a menu or resize tracking loop is running.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // Timers must be invalidated on the thread that scheduled them.
        guard let timer else { return }
        DispatchQueue.main.async { timer.invalidate() }
    }
}

extension Bundle {
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
