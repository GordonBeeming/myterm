import Foundation

public enum BrowserURLNormalizer {
    public static func normalize(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrowserURLNormalizationError.emptyAddress
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty
        else {
            throw BrowserURLNormalizationError.invalidAddress(address)
        }

        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url else {
            throw BrowserURLNormalizationError.invalidAddress(address)
        }
        return url
    }
}

public enum BrowserURLNormalizationError: Error, Equatable, Sendable {
    case emptyAddress
    case invalidAddress(String)
}
