import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class WebLinkRoutingTests: XCTestCase {
    func testCatalogListsInstalledBrowsersWithoutMyTermItself() {
        // These paths must not exist. `URL(fileURLWithPath:)` asks the filesystem whether a path is
        // a directory, so fixtures that happen to be installed would compare equal for that reason
        // alone and hide a broken self-check on the machine that runs the suite.
        let myterm = URL(fileURLWithPath: "/MyTermFixtures/MyTerm.app")
        let safari = URL(fileURLWithPath: "/MyTermFixtures/Safari.app")
        let chrome = URL(fileURLWithPath: "/MyTermFixtures/Google Chrome.app")

        let browsers = ExternalBrowserCatalog.installedBrowsers(
            applicationURLs: [chrome, myterm, safari, safari],
            selfBundleURL: URL(fileURLWithPath: "/MyTermFixtures/MyTerm.app/"),
            bundleIdentifier: { url in
                switch url.lastPathComponent {
                case "Safari.app": "com.apple.Safari"
                case "Google Chrome.app": "com.google.Chrome"
                default: "com.gordonbeeming.myterm"
                }
            },
            displayName: { $0.deletingPathExtension().lastPathComponent }
        )

        XCTAssertEqual(browsers.map(\.bundleIdentifier), ["com.google.Chrome", "com.apple.Safari"])
        XCTAssertEqual(browsers.map(\.name), ["Google Chrome", "Safari"])
    }

    func testResolutionRefusesToSendLinksBackToMyTerm() {
        let myterm = URL(fileURLWithPath: "/Applications/MyTerm.app")
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")

        XCTAssertEqual(
            ExternalBrowserCatalog.resolve(
                .myterm,
                defaultApplicationURL: { safari },
                applicationURL: { _ in safari },
                selfBundleURL: myterm,
                displayName: { $0.lastPathComponent }
            ),
            .myterm
        )

        XCTAssertEqual(
            ExternalBrowserCatalog.resolve(
                .systemDefaultBrowser,
                defaultApplicationURL: { safari },
                applicationURL: { _ in nil },
                selfBundleURL: myterm,
                displayName: { $0.lastPathComponent }
            ),
            .application(safari)
        )

        guard case .unavailable = ExternalBrowserCatalog.resolve(
            .systemDefaultBrowser,
            defaultApplicationURL: { myterm },
            applicationURL: { _ in nil },
            selfBundleURL: myterm,
            displayName: { $0.lastPathComponent }
        ) else {
            return XCTFail("MyTerm as the default browser must not be used as the destination")
        }

        guard case .unavailable = ExternalBrowserCatalog.resolve(
            .application(bundleIdentifier: "com.example.removed"),
            defaultApplicationURL: { safari },
            applicationURL: { _ in nil },
            selfBundleURL: myterm,
            displayName: { $0.lastPathComponent }
        ) else {
            return XCTFail("A browser that is no longer installed must not be used as the destination")
        }

        guard case .unavailable = ExternalBrowserCatalog.resolve(
            .application(bundleIdentifier: "com.gordonbeeming.myterm"),
            defaultApplicationURL: { safari },
            applicationURL: { _ in myterm },
            selfBundleURL: myterm,
            displayName: { $0.lastPathComponent }
        ) else {
            return XCTFail("Choosing MyTerm by identifier must not be used as the destination")
        }
    }

    func testWebLinksOpenInTheChosenBrowserInsteadOfATab() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened: [(URL, URL)] = []
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            externalWebOpener: { url, applicationURL in
                opened.append((url, applicationURL))
                return true
            }
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))
        let tabCount = model.selectedWorkspace.tabs.count

        model.open([url])
        XCTAssertEqual(opened.count, 0)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, tabCount + 1, "MyTerm is the default destination")

        model.updateGlobalSettings {
            $0.webLinkDestination = .application(bundleIdentifier: "com.apple.Safari")
        }
        model.open([url])
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, url)
        XCTAssertEqual(opened.first?.1.lastPathComponent, "Safari.app")
        XCTAssertEqual(
            model.selectedWorkspace.tabs.count,
            tabCount + 1,
            "A link sent to another browser must not also open a tab"
        )
        XCTAssertNil(model.errorDescription)
    }

    func testALinkFallsBackToMyTermWhenTheChosenBrowserIsGone() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var openCallCount = 0
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            externalWebOpener: { _, _ in
                openCallCount += 1
                return true
            }
        )
        model.updateGlobalSettings {
            $0.webLinkDestination = .application(bundleIdentifier: "com.example.removed")
        }
        let tabCount = model.selectedWorkspace.tabs.count

        model.open([try XCTUnwrap(URL(string: "https://example.com"))])
        XCTAssertEqual(openCallCount, 0)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, tabCount + 1)
        XCTAssertNotNil(model.errorDescription)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-web-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
