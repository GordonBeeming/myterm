import XCTest
@testable import MyTermCore

final class AgentActivityMarkerTests: XCTestCase {
    func testReportsTheAgentAndWhatItIsDoing() {
        XCTAssertEqual(
            AgentActivityMarker.report(fromPayload: "agent=claude;event=finished"),
            AgentActivityReport(agent: "claude", activity: .finished)
        )
        XCTAssertEqual(
            AgentActivityMarker.report(fromPayload: "event=awaiting_input;agent=codex"),
            AgentActivityReport(agent: "codex", activity: .awaitingInput)
        )
    }

    func testConversationDirectoryAndLauncherAreCapturedWithoutUsingTheTitle() throws {
        let path = "/tmp/a project/with;separators"
        let encoded = Data(path.utf8).base64EncodedString()
        let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
            "agent=codex;event=working;session=abc;cwd64=\(encoded);launcher=codex-statusline"))
        XCTAssertEqual(report.workingDirectory?.path, path)
        XCTAssertEqual(report.codexLauncher, .statusline)
        XCTAssertEqual(report.sessionID, "abc")
        for metadata in ["cwd64=not-base64", "launcher=unknown", "cwd64=\(Data("relative".utf8).base64EncodedString())"] {
            XCTAssertNil(AgentActivityMarker.report(fromPayload: "agent=codex;event=working;session=abc;\(metadata)")?.sessionID)
        }
    }

    func testAcceptsTheEventNamesOtherTerminalsUse() {
        let equivalents: [String: AgentActivity] = [
            "busy": .working,
            "working": .working,
            "idle": .finished,
            "stop": .finished,
            "finished": .finished,
            "waiting": .awaitingInput,
            "notification": .awaitingInput,
            "awaiting_input": .awaitingInput,
        ]
        for (name, activity) in equivalents {
            XCTAssertEqual(
                AgentActivityMarker.report(fromPayload: "agent=claude;event=\(name)")?.activity,
                activity,
                "Expected \(name) to report \(activity)"
            )
        }
    }

    func testIgnoresCaseSpacingAndUnknownFields() {
        XCTAssertEqual(
            AgentActivityMarker.report(fromPayload: " AGENT = Claude ; pid=8123 ; Event = FINISHED "),
            AgentActivityReport(agent: "claude", activity: .finished)
        )
    }

    func testIgnoresPayloadsThatAreNotAReport() {
        let rejected = [
            "",
            "agent=claude",
            "event=finished",
            "agent=claude;event=daydreaming",
            "agent=;event=finished",
            "just some terminal output",
            "agent=claude;event=finished;" + String(repeating: "x", count: AgentActivityMarker.maximumPayloadBytes + 1),
            // The byte limit also applies to multibyte text.
            "agent=claude;event=finished;" + String(repeating: "\u{1F642}", count: AgentActivityMarker.maximumPayloadBytes / 4 + 1),
        ]
        for payload in rejected {
            XCTAssertNil(
                AgentActivityMarker.report(fromPayload: payload),
                "Expected \(payload.prefix(40)) to be ignored"
            )
        }
    }
}
