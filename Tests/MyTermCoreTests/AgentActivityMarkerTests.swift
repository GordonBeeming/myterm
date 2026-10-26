import XCTest
@testable import MyTermCore

final class AgentActivityMarkerTests: XCTestCase {
    func testDecodedReportsValidateRecoveryIdentifiers() throws {
        for session in ["session; echo unsafe", "$(echo unsafe)", "line\nbreak", String(repeating: "x", count: 65)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "agent": "codex", "activity": "working", "sessionID": session,
                "toolRequestID": String(repeating: "A", count: 64)
            ])
            let report = try JSONDecoder().decode(AgentActivityReport.self, from: data)
            XCTAssertEqual(report.agent, "codex")
            XCTAssertEqual(report.activity, .working)
            XCTAssertNil(report.sessionID)
            XCTAssertNil(report.toolRequestID)
        }
    }

    func testDecodedReportsKeepValidMetadataAndOptionalFieldCompatibility() throws {
        let report = AgentActivityReport(agent: "codex", activity: .awaitingInput,
            sessionID: "session_123-abc.def", workingDirectory: URL(fileURLWithPath: "/tmp/a project"),
            codexLauncher: .statusline, toolRequestID: String(repeating: "a", count: 64))
        XCTAssertEqual(try JSONDecoder().decode(AgentActivityReport.self, from: JSONEncoder().encode(report)), report)
        let minimal = try JSONSerialization.data(withJSONObject: ["agent": "claude", "activity": "finished"])
        XCTAssertEqual(try JSONDecoder().decode(AgentActivityReport.self, from: minimal),
                       AgentActivityReport(agent: "claude", activity: .finished))
    }

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

    func testEmptyOptionalHookMetadataPreservesConversationIdentity() throws {
        for agent in ["claude", "codex"] {
            let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
                "agent=\(agent);event=ready;session=abc;cwd64=;launcher="))
            XCTAssertEqual(report.sessionID, "abc")
            XCTAssertNil(report.workingDirectory)
            XCTAssertNil(report.codexLauncher)
        }
        let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
            "agent=codex;event=working;session=abc;cwd64=;launcher=codex-statusline"))
        XCTAssertEqual(report.sessionID, "abc")
        XCTAssertEqual(report.codexLauncher, .statusline)
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
