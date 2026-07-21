import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DefaultTerminalController {
    enum State: Equatable {
        case ready
        case registering
        case registered
        case failed(String)
    }

    private static let commandScript = UTType(importedAs: "com.apple.terminal.shell-script")
    private static let handledContentTypes: [UTType] = [
        .shellScript,
        commandScript,
        .unixExecutable,
    ]

    private(set) var state: State = .ready
    private(set) var isDefault = false

    init() {
        refresh()
    }

    func makeDefault() {
        guard state != .registering else { return }
        state = .registering
        let applicationURL = Bundle.main.bundleURL

        Task {
            do {
                for contentType in Self.handledContentTypes {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: applicationURL,
                        toOpen: contentType
                    )
                }
                try await NSWorkspace.shared.setDefaultApplication(
                    at: applicationURL,
                    toOpenURLsWithScheme: "ssh"
                )
                refresh()
                state = .registered
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func refresh() {
        let applicationURL = Bundle.main.bundleURL.standardizedFileURL
        let handlesFiles = Self.handledContentTypes.allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == applicationURL
        }
        guard let sshURL = URL(string: "ssh://example.com") else {
            isDefault = false
            return
        }
        let handlesSSH = NSWorkspace.shared.urlForApplication(toOpen: sshURL)?.standardizedFileURL == applicationURL
        isDefault = handlesFiles && handlesSSH
    }
}
