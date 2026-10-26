import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class BrowserContextDeliveryTests: XCTestCase {
    func testScreenshotIsWrittenPrivatelyBeforeItsPathIsInsertedWithoutReturn() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "context-delivery-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "context-delivery-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = ContextDeliveryEngine()
        let secrets = ContextDeliverySecrets()
        let model = try AppModel(applicationSupportDirectory: directory, terminalEngine: engine,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults),
            browserLauncherURL: nil,
            agentNotifications: AgentNotificationSettings(channel: .development, defaults: defaults),
            makeCompanionHost: { model, channel, namespace in
                CompanionHostModel(appModel: model, channel: channel, storageNamespace: namespace,
                                   secrets: secrets, defaults: defaults)
            })
        defer { model.terminateTerminalSessions() }
        let target = try XCTUnwrap(model.browserContextTargets(in: model.selectedWorkspace.id).first)
        let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try model.insertBrowserContext("QA feedback", screenshot: image, target: target, artifactRoot: directory)
        let text = try XCTUnwrap(engine.session?.insertedText)
        XCTAssertTrue(text.hasPrefix("QA feedback\n\nScreenshot file on this Mac (read this image): "))
        XCTAssertFalse(text.hasSuffix("\n"))
        let path = try XCTUnwrap(text.components(separatedBy: "Screenshot file on this Mac (read this image): ").last)
        let imageURL = URL(fileURLWithPath: path)
        XCTAssertEqual(try Data(contentsOf: imageURL), image)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: imageURL.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }
}

@MainActor
private final class ContextDeliveryEngine: TerminalEngine {
    var session: ContextDeliverySession?
    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        let value = ContextDeliverySession()
        session = value
        return value
    }
}

@MainActor
private final class ContextDeliverySession: TerminalProcessSession {
    var isRunning = false
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?
    var insertedText: String?
    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
    func insertLocalText(_ text: String) throws { insertedText = text }
}

private final class ContextDeliverySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
