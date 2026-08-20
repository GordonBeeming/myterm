import XCTest
@testable import MyTermCore

final class AgentAttentionStateTests: XCTestCase {
    func testReadingATabClearsAFinishButNotAQuestion() {
        XCTAssertNil(
            AgentActivity.finished.afterReading,
            "A finished turn that has been seen has nothing left to say"
        )
        XCTAssertEqual(
            AgentActivity.awaitingInput.afterReading,
            .awaitingInput,
            "Reading a question does not answer it"
        )
        XCTAssertEqual(
            AgentActivity.working.afterReading,
            .working,
            "Reading a tab does not stop the agent"
        )
    }

    func testOnlyAFinishOrAQuestionAsksForAnything() {
        XCTAssertTrue(AgentActivity.finished.needsAttention)
        XCTAssertTrue(AgentActivity.awaitingInput.needsAttention)
        XCTAssertFalse(AgentActivity.working.needsAttention)
    }

    func testAQuestionOutranksAFinishWhichOutranksWork() {
        XCTAssertEqual(AgentActivity.mostUrgent(of: [.working, .finished]), .finished)
        XCTAssertEqual(AgentActivity.mostUrgent(of: [.finished, .awaitingInput]), .awaitingInput)
        XCTAssertEqual(AgentActivity.mostUrgent(of: [.awaitingInput, .working, .finished]), .awaitingInput)
        XCTAssertNil(AgentActivity.mostUrgent(of: []))
    }
}
