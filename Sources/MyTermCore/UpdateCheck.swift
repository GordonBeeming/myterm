import Foundation

/// A `major.minor[.patch]` version, as stamped into `CFBundleShortVersionString` at bundle time.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts `0.23`, `v0.23`, and `0.23.1`. Anything else is not a version this app publishes.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // 0.23 and 0.23.0 are the same release, so compare against a padded copy rather than
        // treating the shorter one as smaller.
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var padded = components
        while padded.count < 3 { padded.append(0) }
        hasher.combine(padded)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let releaseURL: URL
    public let name: String?

    public init(version: AppVersion, tag: String, releaseURL: URL, name: String? = nil) {
        self.version = version
        self.tag = tag
        self.releaseURL = releaseURL
        self.name = name
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate(current: AppVersion)
    case available(AppRelease)

    public var release: AppRelease? {
        guard case .available(let release) = self else { return nil }
        return release
    }
}

public enum UpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case unreadableCurrentVersion(String)
    case unreadableResponse(reason: String)
    case noPublishedRelease

    public var errorDescription: String? {
        switch self {
        case .unreadableCurrentVersion(let raw): "This build reports an unreadable version (\(raw))."
        case .unreadableResponse(let reason): "Could not read the release information: \(reason)"
        case .noPublishedRelease: "There is no published release to compare against."
        }
    }
}

public enum UpdateCheck {
    /// GitHub's `releases/latest` already excludes drafts and prereleases.
    public static let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/GordonBeeming/myterm/releases/latest"
    )!

    /// The whole comparison, with the network left to the caller so this stays testable.
    public static func availability(
        currentVersion: String,
        latestReleaseJSON data: Data
    ) throws -> UpdateAvailability {
        guard let current = AppVersion(currentVersion) else {
            throw UpdateCheckError.unreadableCurrentVersion(currentVersion)
        }
        let release = try parseRelease(data)
        return release.version > current ? .available(release) : .upToDate(current: current)
    }

    static func parseRelease(_ data: Data) throws -> AppRelease {
        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UpdateCheckError.unreadableResponse(reason: "the response was not an object")
            }
            payload = object
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.unreadableResponse(reason: error.localizedDescription)
        }

        if payload["tag_name"] == nil, let message = payload["message"] as? String {
            // A repository with no releases answers 404 with a message body rather than a release.
            throw message.localizedCaseInsensitiveContains("not found")
                ? UpdateCheckError.noPublishedRelease
                : UpdateCheckError.unreadableResponse(reason: message)
        }
        guard let tag = payload["tag_name"] as? String else {
            throw UpdateCheckError.unreadableResponse(reason: "the response had no tag_name")
        }
        guard let version = AppVersion(tag) else {
            throw UpdateCheckError.unreadableResponse(reason: "could not read a version from tag \(tag)")
        }
        guard let address = payload["html_url"] as? String, let url = URL(string: address) else {
            throw UpdateCheckError.unreadableResponse(reason: "the response had no usable html_url")
        }
        let name = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppRelease(version: version, tag: tag, releaseURL: url, name: name)
    }
}
