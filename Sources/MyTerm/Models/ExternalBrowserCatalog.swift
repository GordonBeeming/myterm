import AppKit
import Foundation
import MyTermCore

/// A web browser installed on this Mac, offered as a destination for web links.
struct ExternalBrowser: Equatable, Hashable, Identifiable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

/// What a `WebLinkDestination` means right now, on this Mac.
enum ExternalBrowserResolution: Equatable {
    /// Open the link in MyTerm's own browser.
    case myterm
    /// Hand the link to the given application.
    case application(URL)
    /// The chosen application cannot be used. MyTerm opens the link itself and reports this.
    case unavailable(String)
}

enum ExternalBrowserCatalog {
    /// A URL used only to ask macOS which applications handle web links.
    static let probeURL = URL(string: "https://example.com")!

    static func installedBrowsers(
        applicationURLs: [URL] = NSWorkspace.shared.urlsForApplications(toOpen: ExternalBrowserCatalog.probeURL),
        selfBundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        displayName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> [ExternalBrowser] {
        var seen = Set<String>()
        var browsers: [ExternalBrowser] = []
        for applicationURL in applicationURLs {
            guard !isSelf(applicationURL, selfBundleURL: selfBundleURL),
                  let identifier = bundleIdentifier(applicationURL),
                  seen.insert(identifier).inserted else {
                continue
            }
            browsers.append(
                ExternalBrowser(bundleIdentifier: identifier, name: displayName(applicationURL))
            )
        }
        return browsers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func resolve(
        _ destination: WebLinkDestination,
        defaultApplicationURL: () -> URL? = {
            NSWorkspace.shared.urlForApplication(toOpen: ExternalBrowserCatalog.probeURL)
        },
        applicationURL: (String) -> URL? = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        },
        selfBundleURL: URL = Bundle.main.bundleURL,
        displayName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> ExternalBrowserResolution {
        switch destination {
        case .myterm:
            return .myterm
        case .systemDefaultBrowser:
            guard let applicationURL = defaultApplicationURL() else {
                return .unavailable("MyTerm could not find the default web browser.")
            }
            guard !isSelf(applicationURL, selfBundleURL: selfBundleURL) else {
                // Handing the link back to the default browser would route it straight into MyTerm again.
                return .unavailable(
                    "MyTerm is the default web browser, so web links would come straight back. Choose a specific browser instead."
                )
            }
            return .application(applicationURL)
        case .application(let bundleIdentifier):
            guard let applicationURL = applicationURL(bundleIdentifier) else {
                return .unavailable("MyTerm could not find \(bundleIdentifier). It may have been removed.")
            }
            guard !isSelf(applicationURL, selfBundleURL: selfBundleURL) else {
                return .unavailable(
                    "\(displayName(applicationURL)) is MyTerm itself, so web links would come straight back."
                )
            }
            return .application(applicationURL)
        }
    }

    /// Compares paths rather than whole URLs. `URL(fileURLWithPath:)` asks the filesystem whether
    /// the path is a directory, so two URLs for the same bundle compare unequal whenever that
    /// bundle is absent, and MyTerm would then offer itself as a browser.
    private static func isSelf(_ applicationURL: URL, selfBundleURL: URL) -> Bool {
        applicationURL.standardizedFileURL.path == selfBundleURL.standardizedFileURL.path
    }
}
