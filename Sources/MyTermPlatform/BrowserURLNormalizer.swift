import Foundation

public enum BrowserURLNormalizer {
    public static func normalize(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrowserURLNormalizationError.emptyAddress
        }

        let candidate = trimmed.lowercased().hasPrefix("file:") || trimmed.contains("://")
            ? trimmed
            : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased()
        else {
            throw BrowserURLNormalizationError.invalidAddress(address)
        }

        components.scheme = scheme
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else {
                throw BrowserURLNormalizationError.invalidAddress(address)
            }
            components.host = host.lowercased()
        case "file":
            guard let url = components.url,
                  url.isFileURL,
                  !url.path.isEmpty,
                  url.path.hasPrefix("/") else {
                throw BrowserURLNormalizationError.invalidAddress(address)
            }
            return url
        default:
            throw BrowserURLNormalizationError.invalidAddress(address)
        }

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
