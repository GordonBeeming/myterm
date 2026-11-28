import CryptoKit
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
        case .production:
            #if MYTERM_RUST_RELEASE_REHEARSAL
            "com.gordonbeeming.myterm.rust-rehearsal"
            #else
            "com.gordonbeeming.myterm"
            #endif
        }
    }

    var authenticationCallbackScheme: String {
        switch self {
        case .development: "myterm-dev"
        case .production:
            #if MYTERM_RUST_RELEASE_REHEARSAL
            "myterm-rust-rehearsal"
            #else
            "myterm"
            #endif
        }
    }

    static func rustWorkspacePreferencesDomain(applicationSupportOverride: URL?) -> String {
        let base = "com.gordonbeeming.myterm.dev.rust-workspaces"
        guard let directory = applicationSupportOverride else { return base }
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        return base + "." + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func persistenceURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appending(path: displayName, directoryHint: .isDirectory)
            .appending(path: "workspace-state.json", directoryHint: .notDirectory)
    }
}
