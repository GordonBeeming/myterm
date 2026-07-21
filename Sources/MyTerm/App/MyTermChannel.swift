import Foundation

enum MyTermChannel: String, CaseIterable, Sendable {
    case development
    case production

    static var active: MyTermChannel {
        #if MYTERM_PRODUCTION
        .production
        #else
        .development
        #endif
    }

    var displayName: String {
        switch self {
        case .development: "myterm-dev"
        case .production: "myterm"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .development: "com.gordonbeeming.myterm.dev"
        case .production: "com.gordonbeeming.myterm"
        }
    }

    func persistenceURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appending(path: displayName, directoryHint: .isDirectory)
            .appending(path: "workspace-state.json", directoryHint: .notDirectory)
    }
}
