@testable import MyTerm
import AppKit
import SwiftUI
import Foundation
import MyTermCore
import XCTest

final class BrowserAddressSuggestionsTests: XCTestCase {
    private func openTab(_ title: String, _ url: String, id: TabID = TabID()) throws -> BrowserAddressSuggestions.OpenTab {
        .init(title: title, url: try XCTUnwrap(URL(string: url)), tabID: id)
    }

    func testNavigationComesFirstAndMatchesTitleOrURLIgnoringCase() throws {
        let titleMatch = try openTab("Example documentation", "https://docs.test")
        let urlMatch = try openTab("Other page", "https://example.test/path")
        let unrelated = try openTab("Other", "https://other.test")
        let results = BrowserAddressSuggestions.suggestions(text: "  EXAMPLE  ", openTabs: [titleMatch, unrelated, urlMatch], currentTabID: TabID())
        XCTAssertEqual(results.map(\.action), [.navigate("EXAMPLE"), .switchTab(titleMatch.tabID), .switchTab(urlMatch.tabID)])
    }

    func testEmptyInputShowsOpenTabsExcludingCurrentAndDeduplicatingIDs() throws {
        let current = try openTab("Current", "https://current.test")
        let other = try openTab("Other", "https://other.test")
        let sameURL = try openTab("Another tab at same URL", "https://other.test")
        let results = BrowserAddressSuggestions.suggestions(text: " \n", openTabs: [current, other, other, sameURL], currentTabID: current.tabID)
        XCTAssertEqual(results.map(\.action), [.switchTab(other.tabID), .switchTab(sameURL.tabID)])
    }

    func testLimitIncludesNavigationRow() throws {
        let tabs = try (0..<8).map { try openTab("Example \($0)", "https://example.test/\($0)") }
        let results = BrowserAddressSuggestions.suggestions(text: "example", openTabs: tabs, currentTabID: TabID())
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.first?.action, .navigate("example"))
        XCTAssertEqual(results.last?.action, .switchTab(tabs[3].tabID))
        XCTAssertEqual(BrowserAddressSuggestions.suggestions(text: "", openTabs: tabs, currentTabID: TabID()).count, 5)
    }

    func testTabWidthsShrinkToViewportAndRemainWithinChipBounds() {
        XCTAssertEqual(WorkspaceTabStripMetrics.resolvedTabWidth(availableWidth: 1000, count: 2), 220)
        XCTAssertEqual(WorkspaceTabStripMetrics.resolvedTabWidth(availableWidth: 200, count: 4), 110)
        XCTAssertEqual(WorkspaceTabStripMetrics.resolvedTabWidth(availableWidth: 448, count: 2), 196)
    }

    func testNoOpenTabsStillOffersTypedAddress() {
        XCTAssertEqual(BrowserAddressSuggestions.suggestions(text: "local.test", openTabs: [], currentTabID: TabID()).map(\.action), [.navigate("local.test")])
        XCTAssertTrue(BrowserAddressSuggestions.suggestions(text: "", openTabs: [], currentTabID: TabID()).isEmpty)
    }
}

@MainActor
final class BrowserAddressSuggestionKeyboardTests: XCTestCase {
    func testArrowsMoveSuggestionsAndReturnSubmitsEditorText() {
        var directions: [Int] = []
        var submitted: String?
        let coordinator = BrowserAddressTextField.Coordinator(
            text: .constant(""), beginEditing: { true }, endEditing: {},
            submit: { submitted = $0 }, submitBackwards: { submitted = $0 },
            didFocus: { _ in }, onEscape: {}
        )
        coordinator.moveSelection = { directions.append($0) }
        let editor = NSTextView()
        editor.string = "typed.test"
        let field = NSTextField()
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(directions, [1, -1])
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, "typed.test")
    }

    func testEscapeCallsPageFocusAndFindArrowsRemainNative() {
        var escaped = false
        let coordinator = BrowserAddressTextField.Coordinator(
            text: .constant(""), beginEditing: { true }, endEditing: {},
            submit: { _ in }, submitBackwards: { _ in },
            didFocus: { _ in }, onEscape: { escaped = true }
        )
        let field = NSTextField()
        let editor = NSTextView()
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(escaped)
    }
}
