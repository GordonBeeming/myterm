import MyTermCore
import XCTest
@testable import MyTermCompanion

final class RemoteSettingsDraftTests: XCTestCase {
    func testChangingOnePreferenceDoesNotOverwriteUneditedRemoteSettings() {
        var original = TerminalPreferences()
        original.shell = .custom(path: "/bin/fish")
        original.terminalTheme = .solarizedDark
        var draft = RemoteTerminalSettingsDraft(original)
        draft.value.fontSize += 2
        var concurrent = original
        concurrent.shell = .custom(path: "/bin/bash")
        let applied = draft.patch.applying(to: concurrent)
        XCTAssertEqual(applied.fontSize, original.fontSize + 2)
        XCTAssertEqual(applied.shell, concurrent.shell)
        XCTAssertEqual(applied.terminalTheme, .solarizedDark)
        XCTAssertNil(draft.patch.shell)
    }

    func testInvalidNumericValuesAndRelativeShellPreventSaving() {
        var draft = RemoteTerminalSettingsDraft(TerminalPreferences())
        draft.value.fontSize = .infinity
        XCTAssertFalse(draft.isValid)
        draft.value.fontSize = 12
        draft.value.scrollbackLines = 0
        XCTAssertFalse(draft.isValid)
        draft.value.scrollbackLines = 5_000
        draft.value.shell = .custom(path: "zsh")
        XCTAssertFalse(draft.isValid)
        draft.value.shell = .custom(path: "/bin/zsh")
        XCTAssertTrue(draft.isValid)
    }
}
