import Foundation
import MyTermCore
import MyTermUpdating
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
        case native
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
    private static let knownAssetURLKey = "updates.knownRelease.assetURL"
    private static let knownAssetSHAKey = "updates.knownRelease.assetSHA256"
    private static let skippedVersionKey = "updates.skippedVersion"

    private(set) var status: Status = .idle
    private(set) var lastCheckedAt: Date?
    /// A release the user chose not to be reminded about. Only that exact version goes quiet: a
    /// newer release brings the badge back.
    private(set) var skippedVersion: AppVersion?

    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            preferenceRoot.set(automaticallyChecks, forKey: Self.automaticChecksKey)
            if automaticallyChecks { startPolling() } else { stopPolling() }
        }
    }

    let currentVersion: String
    let installedChannel: UpdateCheck.Channel
    private(set) var selectedChannel: UpdateCheck.Channel
    var stableConfigurationChoice: ChannelConfigurationStore.StableChoice = .restoreStable {
        didSet { preferenceRoot.set(stableConfigurationChoice.rawValue, forKey: "updates.stableConfigurationChoice") }
    }
    private(set) var stagedUpdate: ApplicationUpdatePlan?
    private(set) var isPreparingRestart = false
    private let bundleURL: URL
    private let configurationDirectory: URL
    private let preferencesDomain: String
    private let preferenceRoot: UserDefaults
    private let suiteName: String
    private let usesInjectedDefaults: Bool
    private var checkGeneration = 0
    var needsStableConfigurationChoice: Bool { installedChannel == .beta && selectedChannel == .stable }
    var hasStableConfiguration: Bool {
        ChannelConfigurationStore(directory: configurationDirectory, preferencesDomain: preferencesDomain).hasStableSnapshot
    }
    var supportsInAppInstallation: Bool {
        if case .native = upgradeRoute { return true }
        return selectedChannel == .stable && upgradeCommand != nil
    }
    private let upgradeRoute: UpgradeRoute
    private let fetch: @Sendable (URL) async throws -> Data
    private var defaults: UserDefaults
    private let now: () -> Date
    private let poll = PollTimer()
    private var inFlightCheck: Task<Status, Never>?

    /// Selection belongs to the shared profile, while feed results belong to their own channel.
    init(
        channel: MyTermChannel = .active,
        currentVersion: String = Bundle.main.shortVersionString,
        releaseChannel: UpdateCheck.Channel = UpdateCheck.Channel(
            rawValue: Bundle.main.object(forInfoDictionaryKey: "MyTermReleaseChannel") as? String ?? "stable"
        ) ?? .stable,
        upgradeRoute: UpgradeRoute? = nil,
        defaults: UserDefaults? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil,
        runUpgrade: UpgradeRunner? = nil,
        installedVersion: (@MainActor () throws -> String)? = nil,
        bundleURL: URL = Bundle.main.bundleURL,
        configurationDirectory: URL? = nil
    ) {
        let injectedDefaults = defaults != nil
        let baseSuite = environment["MYTERM_USER_DEFAULTS_SUITE"] ?? channel.bundleIdentifier
        let root = defaults ?? UserDefaults(suiteName: baseSuite) ?? .standard
        let selected = root.string(forKey: "updates.selectedChannel").flatMap(UpdateCheck.Channel.init) ?? releaseChannel
        let suiteName = baseSuite + (selected == .beta ? ".beta-updates" : "")
        let defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        self.preferenceRoot = root
        self.stableConfigurationChoice = root.string(forKey: "updates.stableConfigurationChoice")
            .flatMap(ChannelConfigurationStore.StableChoice.init) ?? .restoreStable
        self.suiteName = baseSuite
        self.usesInjectedDefaults = injectedDefaults
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.installedChannel = releaseChannel
        self.selectedChannel = selected
        self.bundleURL = bundleURL
        self.configurationDirectory = configurationDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/myterm", isDirectory: true)
        self.preferencesDomain = channel.bundleIdentifier
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
        let isolatedProfile = environment["MYTERM_USER_DEFAULTS_SUITE"].map { !$0.isEmpty } == true
            || environment["MYTERM_APPLICATION_SUPPORT_DIRECTORY"].map { !$0.isEmpty } == true
        if upgradeRoute == nil, isolatedProfile {
            self.upgradeRoute = .releasePage
        } else if releaseChannel == .beta, let upgradeRoute, case .homebrew = upgradeRoute {
            self.upgradeRoute = .releasePage
        } else {
            self.upgradeRoute = upgradeRoute ?? Self.detectUpgradeRoute(bundleURL: bundleURL)
        }
        automaticallyChecks = root.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        skippedVersion = defaults.string(forKey: Self.skippedVersionKey).flatMap(AppVersion.init)
        // Only the check timestamp used to survive a relaunch, so a known update went quiet until
        // the next one fell due — up to a day of the app knowing and not saying.
        status = Self.restoredStatus(currentVersion: currentVersion, defaults: defaults, channel: selected, installedChannel: releaseChannel)
        if let path = root.string(forKey: "updates.stagedManifest") {
            do {
                let plan = try JSONDecoder().decode(ApplicationUpdatePlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                if plan.channel == releaseChannel, AppVersion(plan.version) == AppVersion(currentVersion) {
                    root.removeObject(forKey: "updates.stagedManifest")
                } else {
                try ApplicationUpdate.validatePlan(plan, manifest: URL(fileURLWithPath: path))
                guard !FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path) else {
                    throw ApplicationUpdateError.invalid("The previously prepared update was superseded. Check for updates again.")
                }
                guard plan.target == bundleURL, plan.sourceChannel == releaseChannel,
                      plan.channel == selected, plan.manifestURL.path == path else {
                    throw ApplicationUpdateError.invalid("The prepared update belongs to a different app or channel.")
                }
                stagedUpdate = plan
                verifiedInstalledVersion = AppVersion(plan.version)
                installation = .installed
                }
            } catch {
                root.removeObject(forKey: "updates.stagedManifest")
                installation = .failed("Could not restore the prepared update: \(error.localizedDescription)")
            }
        }
        if automaticallyChecks { startPolling() }
    }

    /// Channel changes discard in-flight responses and caches from the previous feed.
    func selectChannel(_ channel: UpdateCheck.Channel) {
        guard installation != .running, !isPreparingRestart, channel != selectedChannel else { return }
        checkGeneration += 1
        inFlightCheck?.cancel()
        inFlightCheck = nil
        if let stagedUpdate {
            do {
                try ApplicationUpdate.validatePlan(stagedUpdate, manifest: stagedUpdate.manifestURL)
                try ApplicationUpdate.retirePreparedUpdate(stagedUpdate)
            }
            catch { installation = .failed("Could not discard the staged update: \(error.localizedDescription)"); return }
        }
        stagedUpdate = nil
        preferenceRoot.removeObject(forKey: "updates.stagedManifest")
        verifiedInstalledVersion = nil
        installation = .ready
        selectedChannel = channel
        if needsStableConfigurationChoice && !hasStableConfiguration { stableConfigurationChoice = .tryBeta }
        preferenceRoot.set(channel.rawValue, forKey: "updates.selectedChannel")
        if !usesInjectedDefaults {
            defaults = UserDefaults(suiteName: suiteName + (channel == .beta ? ".beta-updates" : "")) ?? .standard
        }
        lastCheckedAt = nil
        skippedVersion = nil
        status = .idle
        defaults.removeObject(forKey: Self.lastCheckedAtKey)
        defaults.removeObject(forKey: Self.skippedVersionKey)
        forgetKnownRelease()
    }

    func preparedRestartProcess(relaunch: Bool = true) async throws -> Process? {
        guard !isPreparingRestart else { throw ApplicationUpdateError.invalid("Restart verification is already in progress.") }
        isPreparingRestart = true
        defer { isPreparingRestart = false }
        try validateRestart()
        guard var plan = stagedUpdate else { return nil }
        let verificationPlan = plan
        try await Task.detached {
            try ApplicationUpdate.validate(verificationPlan.staged, version: verificationPlan.version, channel: verificationPlan.channel)
            try ApplicationUpdate.verifySignature(verificationPlan.agentURL, identifier: ApplicationUpdate.bundleIdentifier + ".update-agent")
        }.value
        try Task.checkCancellation()
        plan.stableChoice = needsStableConfigurationChoice ? stableConfigurationChoice : nil
        plan.relaunch = relaunch
        try ApplicationUpdate.validatePlan(plan, manifest: plan.manifestURL)
        try plan.save()
        let helper = Process()
        helper.executableURL = plan.agentURL
        helper.arguments = [plan.manifestURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        return helper
    }

    /// A deleted or tampered handoff must not trap ordinary Quit or channel selection.
    func disarmPreparedUpdate(_ reason: String) {
        stagedUpdate = nil
        verifiedInstalledVersion = nil
        preferenceRoot.removeObject(forKey: "updates.stagedManifest")
        installation = .failed(reason)
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
        case .native: "Update Now"
        }
    }

    var upgradeCommand: String? {
        guard selectedChannel == .stable, case .homebrew(let command) = upgradeRoute else { return nil }
        return command
    }

    var canRestartAfterUpdate: Bool {
        installation != .running && !isPreparingRestart && verifiedInstalledVersion != nil
    }

    func validateRestart() throws {
        if let stagedUpdate {
            guard !FileManager.default.fileExists(atPath: stagedUpdate.directory.appendingPathComponent("superseded").path) else {
                throw ApplicationUpdateError.invalid("The prepared update was superseded. Check for updates again.")
            }
            try ApplicationUpdate.validatePlan(stagedUpdate, manifest: stagedUpdate.manifestURL)
            try ApplicationUpdate.validateSource(stagedUpdate)
            guard !needsStableConfigurationChoice || stableConfigurationChoice == .tryBeta || hasStableConfiguration else {
                throw ApplicationUpdateError.invalid("A stable configuration snapshot is required before returning to stable.")
            }
            return
        }
        guard let verifiedInstalledVersion,
              let diskVersion = AppVersion(try readInstalledVersion()), diskVersion >= verifiedInstalledVersion else {
            throw NSError(domain: "MyTermUpdate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The installed update could not be verified. Try installing again before restarting."
            ])
        }
    }

    func installation(for release: AppRelease) -> Installation {
        if installation == .running { return .running }
        if let stagedUpdate, stagedUpdate.version == release.version.description, stagedUpdate.channel == release.channel {
            return .installed
        }
        if stagedUpdate == nil, let verifiedInstalledVersion, verifiedInstalledVersion >= release.version { return .installed }
        return installation == .installed ? .ready : installation
    }

    /// Installation is independent of checking: a timer cannot erase progress or enable a second brew.
    func install(release requestedRelease: AppRelease? = nil) async {
        guard installation != .running, supportsInAppInstallation else { return }
        guard var release = requestedRelease ?? status.release else {
            installation = .failed("Check for an available update before installing.")
            return
        }
        guard release.channel == selectedChannel else {
            installation = .failed("That update belongs to a different release channel. Check for updates again.")
            return
        }
        guard installation(for: release) != .installed else { return }
        if needsStableConfigurationChoice && stableConfigurationChoice == .restoreStable && !hasStableConfiguration {
            installation = .failed("No stable configuration snapshot is available. Keep this app installed and restore a stable backup before switching.")
            return
        }
        installation = .running
        outputData = Data()
        installationOutput = ""
        do {
            if case .native = upgradeRoute {
                if release.asset == nil {
                    let data = try await fetch(release.channel.endpoint)
                    guard let refreshed = try UpdateCheck.availability(currentVersion: currentVersion,
                        latestReleaseJSON: data, channel: release.channel, installedChannel: installedChannel).release,
                          refreshed.tag == release.tag, refreshed.asset != nil else {
                        throw ApplicationUpdateError.invalid("The release changed or its verified download is not ready. Check for updates again.")
                    }
                    release = refreshed
                    remember(refreshed)
                }
                if installedChannel == .stable, release.channel == .beta {
                    try ChannelConfigurationStore(directory: configurationDirectory, preferencesDomain: preferencesDomain).checkStableCapture()
                }
                let prepared = try await ApplicationUpdate.prepare(release: release, target: bundleURL,
                    sourceChannel: installedChannel, sourceVersion: currentVersion, configurationDirectory: configurationDirectory,
                    preferencesDomain: preferencesDomain,
                    stableChoice: needsStableConfigurationChoice ? stableConfigurationChoice : nil) { [weak self] message in
                        await self?.appendOutput(Data((message + "\n").utf8))
                    }
                do {
                    if let previous = stagedUpdate { try ApplicationUpdate.retirePreparedUpdate(previous) }
                } catch {
                    do { try ApplicationUpdate.retirePreparedUpdate(prepared) }
                    catch { installationOutput += "\nCould not discard unused prepared update: \(error.localizedDescription)" }
                    throw error
                }
                stagedUpdate = prepared
                verifiedInstalledVersion = release.version
                preferenceRoot.set(stagedUpdate?.manifestURL.path, forKey: "updates.stagedManifest")
                installation = .installed
                return
            }
            guard let command = upgradeCommand else { throw ApplicationUpdateError.invalid("No installer is available.") }
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
        let generation = checkGeneration
        if let inFlightCheck { return await inFlightCheck.value }
        let task = Task { @MainActor in await performCheck() }
        inFlightCheck = task
        let result = await task.value
        if checkGeneration == generation { inFlightCheck = nil }
        return result
    }

    /// Ignore late responses from a previous channel and persist only releases belonging to the current selection.
    private func performCheck() async -> Status {
        let generation = checkGeneration
        let channel = selectedChannel
        status = .checking
        do {
            let data = try await fetch(channel.endpoint)
            guard generation == checkGeneration, channel == selectedChannel else { return status }
            let availability = try UpdateCheck.availability(
                currentVersion: currentVersion,
                latestReleaseJSON: data,
                channel: channel,
                installedChannel: installedChannel
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
            guard generation == checkGeneration else { return status }
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

    /// Cache the release and its verified archive metadata for this channel across restarts.
    private func remember(_ release: AppRelease) {
        defaults.set(release.tag, forKey: Self.knownReleaseTagKey)
        defaults.set(release.releaseURL.absoluteString, forKey: Self.knownReleaseURLKey)
        defaults.set(release.asset?.url.absoluteString, forKey: Self.knownAssetURLKey)
        defaults.set(release.asset?.sha256, forKey: Self.knownAssetSHAKey)
    }

    /// Clear the current channel’s cached release without changing another channel’s selection.
    private func forgetKnownRelease() {
        defaults.removeObject(forKey: Self.knownReleaseTagKey)
        defaults.removeObject(forKey: Self.knownReleaseURLKey)
        defaults.removeObject(forKey: Self.knownAssetURLKey)
        defaults.removeObject(forKey: Self.knownAssetSHAKey)
    }

    /// Rehydrate a remembered release only when its version and archive metadata are valid.
    private static func restoredStatus(
        currentVersion: String, defaults: UserDefaults, channel: UpdateCheck.Channel, installedChannel: UpdateCheck.Channel
    ) -> Status {
        guard let tag = defaults.string(forKey: knownReleaseTagKey),
              tag.hasSuffix("-beta") == (channel == .beta),
              let version = AppVersion(channel == .beta ? String(tag.dropLast(5)) : tag),
              let address = defaults.string(forKey: knownReleaseURLKey),
              let url = URL(string: address),
              let current = AppVersion(currentVersion),
              version > current || channel != installedChannel else { return .idle }
        let asset: AppRelease.Asset?
        let expected = "https://github.com/GordonBeeming/myterm/releases/download/\(tag)/myterm-\(version)-aarch64.dmg"
        if let address = defaults.string(forKey: knownAssetURLKey), address == expected,
           let download = URL(string: address), let digest = defaults.string(forKey: knownAssetSHAKey),
           digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) {
            asset = .init(url: download, sha256: digest)
        } else { asset = nil }
        return .available(AppRelease(version: version, tag: tag, releaseURL: url, asset: asset))
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
        if Bundle(url: bundleURL)?.bundleIdentifier == ApplicationUpdate.bundleIdentifier,
           fileExists(bundleURL.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent").path) {
            return .native
        }
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
