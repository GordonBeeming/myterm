import Foundation
import MyTermCore
import Observation

/// Checks GitHub for a newer release and works out how this copy should be upgraded.
///
/// Deliberately not a self-updater. myterm ships as a notarized DMG and a Homebrew cask, and
/// replacing the bundle in place would leave Homebrew's records pointing at a version that is no
/// longer installed. Instead the app finds the update and hands the actual upgrade to whichever
/// mechanism installed it.
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
        /// Installed by Homebrew; the upgrade is a command the user can watch run.
        case homebrew(command: String)
        /// Anything else — a DMG drag, or a build from source. Send them to the release.
        case releasePage
    }

    static let caskToken = "gordonbeeming/tap/myterm"
    static let checkInterval: TimeInterval = 60 * 60 * 24
    /// The elapsed check is cheap, so poll often enough that a machine waking from sleep does not
    /// wait another whole interval before noticing it is due.
    private static let pollInterval: TimeInterval = 60 * 60

    private static let automaticChecksKey = "updates.automaticChecks"
    private static let lastCheckedAtKey = "updates.lastCheckedAt"
    private static let knownReleaseTagKey = "updates.knownRelease.tag"
    private static let knownReleaseURLKey = "updates.knownRelease.url"

    private(set) var status: Status = .idle
    private(set) var lastCheckedAt: Date?

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

    init(
        channel: MyTermChannel = .active,
        currentVersion: String = Bundle.main.shortVersionString,
        upgradeRoute: UpgradeRoute? = nil,
        defaults: UserDefaults? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        let suiteName = environment["MYTERM_USER_DEFAULTS_SUITE"] ?? channel.bundleIdentifier
        let defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            return try await URLSession.shared.data(for: request).0
        }
        self.upgradeRoute = upgradeRoute ?? Self.detectUpgradeRoute()
        automaticallyChecks = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        // Only the check timestamp used to survive a relaunch, so a known update went quiet until
        // the next one fell due — up to a day of the app knowing and not saying.
        status = Self.restoredStatus(currentVersion: currentVersion, defaults: defaults)
        if automaticallyChecks { startPolling() }
    }

    var isDueForCheck: Bool {
        guard let lastCheckedAt else { return true }
        return now().timeIntervalSince(lastCheckedAt) >= Self.checkInterval
    }

    /// The action offered alongside a found update.
    var upgradeActionTitle: String {
        switch upgradeRoute {
        case .homebrew: "Update in a New Tab"
        case .releasePage: "Open the Release"
        }
    }

    var upgradeCommand: String? {
        guard case .homebrew(let command) = upgradeRoute else { return nil }
        return command
    }

    @discardableResult
    func check() async -> Status {
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

    private static func detectUpgradeRoute(
        bundleURL: URL = Bundle.main.bundleURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> UpgradeRoute {
        // Homebrew moves the app into /Applications and keeps its bookkeeping in the Caskroom.
        // Both have to be true: a Caskroom entry alone could belong to a copy that was since
        // replaced by a manual download.
        guard bundleURL.standardizedFileURL.path == "/Applications/myterm.app" else { return .releasePage }
        let prefixes = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
        guard prefixes.contains(where: { fileExists("\($0)/Caskroom/myterm") }) else { return .releasePage }
        return .homebrew(command: "brew upgrade --cask \(caskToken)")
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
