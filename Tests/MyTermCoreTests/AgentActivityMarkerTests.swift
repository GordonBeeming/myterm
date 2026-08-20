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
            "agent=claude;event=finished;" + String(repeating: "x", count: 300),
            // Under the byte cap this is 228 characters but 828 bytes.
            "agent=claude;event=finished;" + String(repeating: "\u{1F642}", count: 200),
        ]
        for payload in rejected {
            XCTAssertNil(
                AgentActivityMarker.report(fromPayload: payload),
                "Expected \(payload.prefix(40)) to be ignored"
            )
        }
    }
}
