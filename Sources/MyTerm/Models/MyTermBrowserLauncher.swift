import Foundation

enum MyTermBrowserLauncher {
    static func executableURL(
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let candidate = resourceURL?.appending(path: "myterm-browser", directoryHint: .notDirectory),
              fileManager.isExecutableFile(atPath: candidate.path)
        else {
            return nil
        }
        return candidate
    }

    static func environment(executableURL: URL?) -> [String: String] {
        executableURL.map { ["BROWSER": $0.path] } ?? [:]
    }
}
