import Foundation
import XCTest
@testable import MyTermCore

final class AgentIndicatorSettingsTests: XCTestCase {
    func testMissingAndInvalidValuesUseDefaults() throws {
        for json in ["{}", """
            {"workingIndicatorIcon":"future","workingIndicatorColor":"unknown",
             "finishedIndicatorIcon":"future","finishedIndicatorColor":"unknown",
             "questionIndicatorIcon":42,"questionIndicatorColor":null}
            """] {
            let settings = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(settings.workingIndicatorIcon, .stirringCook)
            XCTAssertEqual(settings.workingIndicatorColor, .gray)
            XCTAssertEqual(settings.finishedIndicatorIcon, .tickDraw)
            XCTAssertEqual(settings.finishedIndicatorColor, .blue)
            XCTAssertEqual(settings.questionIndicatorIcon, .pulsingBubble)
            XCTAssertEqual(settings.questionIndicatorColor, .purple)
        }
        XCTAssertEqual(try JSONDecoder().decode(WorkingIndicatorIcon.self, from: Data("\"future\"".utf8)), .stirringCook)
        XCTAssertEqual(try JSONDecoder().decode(FinishedIndicatorIcon.self, from: Data("\"future\"".utf8)), .tickDraw)
        XCTAssertEqual(try JSONDecoder().decode(QuestionIndicatorIcon.self, from: Data("\"future\"".utf8)), .pulsingBubble)
    }

    func testEveryChoiceSurvivesRoundTripAndNormalization() throws {
        for (finished, question, color) in zip(FinishedIndicatorIcon.allCases, zip(QuestionIndicatorIcon.allCases, WorkspaceColor.allCases))
            .map({ ($0.0, $0.1.0, $0.1.1) }) {
            let settings = TerminalPreferences(
                finishedIndicatorIcon: finished, finishedIndicatorColor: color,
                questionIndicatorIcon: question, questionIndicatorColor: color
            )
            let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.normalized(), settings)
        }
    }

    func testOverridesCannotCarryIndicatorsAndPreserveGlobalValues() throws {
        let settings = TerminalPreferences(
            workingIndicatorIcon: .hourglass, workingIndicatorColor: .yellow,
            finishedIndicatorIcon: .servedDish, finishedIndicatorColor: .green,
            questionIndicatorIcon: .raisedHand, questionIndicatorColor: .orange
        )
        let data = Data("""
            {"workingIndicatorIcon":"spinner","workingIndicatorColor":"red",
             "finishedIndicatorIcon":"star","finishedIndicatorColor":"red",
             "questionIndicatorIcon":"wobble","questionIndicatorColor":"pink"}
            """.utf8)
        let overrides = try JSONDecoder().decode(TerminalPreferencesOverrides.self, from: data)
        XCTAssertEqual(overrides.applying(to: settings), settings)
        let encoded = try JSONEncoder().encode(overrides)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["workingIndicatorIcon", "workingIndicatorColor", "finishedIndicatorIcon", "finishedIndicatorColor", "questionIndicatorIcon", "questionIndicatorColor"] {
            XCTAssertNil(object[key])
        }
    }

    func testGlobalPersistenceAcrossFolderAndWorkspaceScopes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove test directory: \(error)") }
        }
        let url = directory.appendingPathComponent("state.json")
        let store = try WorkspaceStore(persistenceURL: url)
        let folder = try store.createFolder(title: "Juniper", color: .teal)
        let workspace = try store.createWorkspace(title: "Workbench", folderID: folder)
        try store.updateFolderSettings(folder) { $0.cursorBlink = false }
        try store.updateWorkspaceSettings(workspace) { $0.fontSize = 18 }
        try store.updateGlobalSettings {
            $0.workingIndicatorIcon = .orbit
            $0.workingIndicatorColor = .orange
            $0.finishedIndicatorIcon = .inbox
            $0.finishedIndicatorColor = .pink
            $0.questionIndicatorIcon = .thoughtCloud
            $0.questionIndicatorColor = .teal
        }
        try store.flush()
        let restored = try WorkspaceStore(persistenceURL: url)
        let resolved = try restored.resolvedSettings(for: workspace)
        XCTAssertEqual(resolved.workingIndicatorIcon, .orbit)
        XCTAssertEqual(resolved.workingIndicatorColor, .orange)
        XCTAssertEqual(resolved.finishedIndicatorIcon, .inbox)
        XCTAssertEqual(resolved.finishedIndicatorColor, .pink)
        XCTAssertEqual(resolved.questionIndicatorIcon, .thoughtCloud)
        XCTAssertEqual(resolved.questionIndicatorColor, .teal)
    }

    func testEveryWorkingChoiceSurvivesRoundTripAndNormalization() throws {
        XCTAssertEqual(WorkingIndicatorIcon.allCases.count, 10)
        for (icon, color) in zip(WorkingIndicatorIcon.allCases, WorkspaceColor.allCases) {
            let settings = TerminalPreferences(workingIndicatorIcon: icon, workingIndicatorColor: color)
            let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.normalized(), settings)
        }
    }

    func testMalformedWorkingValuesUseDefaultsWithoutLosingOtherPreferences() throws {
        for value in ["42", "null", "{}", "[]", "true"] {
            let data = Data("{\"workingIndicatorIcon\":\(value),\"workingIndicatorColor\":\(value),\"fontSize\":18}".utf8)
            let settings = try JSONDecoder().decode(TerminalPreferences.self, from: data)
            XCTAssertEqual(settings.workingIndicatorIcon, .stirringCook)
            XCTAssertEqual(settings.workingIndicatorColor, .gray)
            XCTAssertEqual(settings.fontSize, 18)
        }
    }

}
