import Foundation
import MyTermCore
import XCTest
@testable import MyTerm

@MainActor
final class TerminalSnippetStoreTests: XCTestCase {
    func testEditingSavedSnippetUpdatesIdentityAndPersistsScopeAndKind() throws {
        let name = "TerminalSnippetStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DesktopTerminalSnippetStore(defaults: defaults)
        var snippet = TerminalSnippet(title: "Review", text: "inspect this", workspaceID: UUID())
        XCTAssertTrue(store.save(snippet))
        snippet.text = "inspect this carefully"
        snippet.kind = .command
        XCTAssertTrue(store.save(snippet))
        let restored = DesktopTerminalSnippetStore(defaults: defaults)
        XCTAssertEqual(restored.snippets, [snippet])
        restored.remove(snippet.id)
        XCTAssertTrue(DesktopTerminalSnippetStore(defaults: defaults).snippets.isEmpty)
    }

    func testInvalidSnippetDoesNotReplaceExistingEntry() throws {
        let name = "TerminalSnippetStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DesktopTerminalSnippetStore(defaults: defaults)
        let original = TerminalSnippet(title: "Review", text: "inspect")
        XCTAssertTrue(store.save(original))
        var invalid = original
        invalid.text = String(repeating: "x", count: DesktopTerminalSnippetStore.maximumUTF8Bytes + 1)
        XCTAssertFalse(store.save(invalid))
        XCTAssertEqual(store.snippets, [original])
    }
    func testRemovingWorkspaceFreesFullCatalogQuotaAndPersistsOtherScopes() throws {
        let name = "TerminalSnippetStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DesktopTerminalSnippetStore(defaults: defaults)
        let closed = UUID(), surviving = UUID()
        let global = TerminalSnippet(title: "Global", text: "global")
        let other = TerminalSnippet(title: "Other", text: "other", workspaceID: surviving)
        XCTAssertTrue(store.save(global))
        XCTAssertTrue(store.save(other))
        for index in 0..<98 {
            XCTAssertTrue(store.save(TerminalSnippet(title: "Scoped \(index)", text: "run", workspaceID: closed)))
        }
        XCTAssertFalse(store.save(TerminalSnippet(title: "Over quota", text: "extra")))
        store.removeWorkspace(closed)
        XCTAssertEqual(store.snippets, [global, other])
        XCTAssertEqual(DesktopTerminalSnippetStore(defaults: defaults).snippets, [global, other])
        for index in 0..<98 {
            XCTAssertTrue(store.save(TerminalSnippet(title: "Replacement \(index)", text: "run")))
        }
        XCTAssertEqual(store.snippets.count, 100)
        XCTAssertFalse(store.save(TerminalSnippet(title: "Still bounded", text: "extra")))
    }

}
