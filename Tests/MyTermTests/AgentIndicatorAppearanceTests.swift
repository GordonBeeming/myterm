import Foundation
import Observation
@testable import MyTerm
import MyTermCore
import SwiftUI
import XCTest
@testable import MyTermUI

final class AgentIndicatorAppearanceTests: XCTestCase {
    @MainActor
    func testModelAppearanceInvalidatesObserversAndReflectsSettingsChangesImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove test directory: \(error)") }
        }
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
        XCTAssertEqual(model.agentIndicatorAppearance, AgentIndicatorAppearance())

        let invalidated = XCTestExpectation(description: "Appearance observer invalidated by global settings")
        withObservationTracking {
            _ = model.agentIndicatorAppearance
        } onChange: {
            invalidated.fulfill()
        }

        model.updateGlobalSettings {
            $0.workingIndicatorIcon = .orbit
            $0.workingIndicatorColor = .teal
            $0.finishedIndicatorIcon = .star
            $0.finishedIndicatorColor = .green
            $0.questionIndicatorIcon = .raisedHand
            $0.questionIndicatorColor = .orange
        }

        XCTAssertEqual(XCTWaiter.wait(for: [invalidated], timeout: 0), .completed)
        let appearance = model.agentIndicatorAppearance
        XCTAssertEqual(appearance.workingIcon, .orbit)
        XCTAssertEqual(appearance.workingColor, .teal)
        XCTAssertEqual(appearance.finishedIcon, .star)
        XCTAssertEqual(appearance.finishedColor, .green)
        XCTAssertEqual(appearance.questionIcon, .raisedHand)
        XCTAssertEqual(appearance.questionColor, .orange)
        try model.store.flush()
    }

    func testEnvironmentUsesDefaultAppearanceWithoutAppSetup() {
        let appearance = EnvironmentValues().agentIndicatorAppearance
        XCTAssertEqual(appearance.workingIcon, .stirringCook)
        XCTAssertEqual(appearance.workingColor, .gray)
        XCTAssertEqual(appearance.finishedIcon, .tickDraw)
        XCTAssertEqual(appearance.finishedColor, .blue)
        XCTAssertEqual(appearance.questionIcon, .pulsingBubble)
        XCTAssertEqual(appearance.questionColor, .purple)
    }

    func testAppearanceCopiesAllSixGlobalChoices() {
        let settings = TerminalPreferences(
            workingIndicatorIcon: .levelBars, workingIndicatorColor: .green,
            finishedIndicatorIcon: .flag, finishedIndicatorColor: .yellow,
            questionIndicatorIcon: .backAndForth, questionIndicatorColor: .indigo
        )
        let appearance = AgentIndicatorAppearance(preferences: settings)
        XCTAssertEqual(appearance.workingIcon, .levelBars)
        XCTAssertEqual(appearance.workingColor, .green)
        XCTAssertEqual(appearance.finishedIcon, .flag)
        XCTAssertEqual(appearance.finishedColor, .yellow)
        XCTAssertEqual(appearance.questionIcon, .backAndForth)
        XCTAssertEqual(appearance.questionColor, .indigo)
    }

    func testPulseMatchesCanvasPeakRestAndPeriod() {
        let frames: [(Double, Double)] = [(0, 1), (0.3, 1.14), (0.6, 1), (1, 1)]
        XCTAssertEqual(AgentGlyphMotion.value(0.48, duration: 1.6, frames: frames), 1.14, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.value(1.2, duration: 1.6, frames: frames), 1, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.value(2.08, duration: 1.6, frames: frames), 1.14, accuracy: 0.0001)
    }

    func testDoubleHopMatchesCanvasAmplitudesAndRest() {
        let frames: [(Double, Double)] = [(0, 0), (0.12, -3.2), (0.24, 0), (0.32, -1.2), (0.4, 0), (1, 0)]
        XCTAssertEqual(AgentGlyphMotion.value(0.24, duration: 2, frames: frames, easeOut: true), -3.2, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.value(0.64, duration: 2, frames: frames, easeOut: true), -1.2, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.value(1.5, duration: 2, frames: frames, easeOut: true), 0, accuracy: 0.0001)
    }

    func testEasingMatchesCSSBezierReferencePoints() {
        XCTAssertEqual(AgentGlyphMotion.easing(0), 0, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.easing(1), 1, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.easing(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.easing(0.5, easeOut: true), 0.684643, accuracy: 0.0001)
    }


    func testTickDashCompletesBeforeItsAnimationRests() {
        XCTAssertEqual(AgentGlyphMotion.tickTrim(elapsed: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.tickTrim(elapsed: 0.45), 0.7787, accuracy: 0.001)
        XCTAssertEqual(AgentGlyphMotion.tickTrim(elapsed: 0.8), 1, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.tickTrim(elapsed: 4), 1, accuracy: 0.0001)
    }

    func testWritingLinesFollowCanvasSequenceAndRestart() {
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write1", elapsed: 0.24), 8, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write2", elapsed: 0.24), 16, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write2", elapsed: 0.72), 8, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write3", elapsed: 1.2), 8, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write3", elapsed: 1.92), 0, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write3", elapsed: 2.28), 8, accuracy: 0.0001)
        XCTAssertEqual(AgentGlyphMotion.writingDashOffset("write1", elapsed: 2.4), 16, accuracy: 0.0001)
    }

}
