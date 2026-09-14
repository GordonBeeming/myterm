import XCTest

@testable import MyTermRemoteProtocol

/// The catalog is what the host and the device agree on about models: the arguments `/model`
/// takes, and what to call the identifier the transcript carries.
final class AgentModelCatalogTests: XCTestCase {
    // MARK: - Naming the model in use

    func testTheAgentsFullNamesBecomeShortLabels() {
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-opus-4-8"), "Opus 4.8")
    }

    func testADatedReleaseDropsItsDate() {
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testTheLargerWindowIsSaid() {
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-opus-5[1m]"), "Opus 5 (1M)")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "opus[1m]"), "Opus (1M)")
    }

    func testAnAliasIsNamedByItsFamilyAlone() {
        // The alias means "the current release of this family", and which that is cannot be read
        // off the transcript, so the label makes no claim about the version.
        XCTAssertEqual(AgentModelCatalog.label(forModel: "opus"), "Opus")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "fable"), "Fable")
    }

    func testTheSyntheticMarkerIsNotAModel() {
        XCTAssertNil(AgentModelCatalog.label(forModel: "<synthetic>"))
        XCTAssertNil(AgentModelCatalog.label(forModel: ""))
    }

    func testAnUnknownShapeIsShownAsItCame() {
        // A custom or third-party model name. A raw name beats a wrong label.
        XCTAssertEqual(AgentModelCatalog.label(forModel: "my-fine-tune"), "my-fine-tune")
        XCTAssertEqual(AgentModelCatalog.label(forModel: "claude-opus-next"), "claude-opus-next")
    }

    // MARK: - What can be switched to

    func testEveryChoiceIsACommandTheAgentDocuments() {
        // The arguments `/model` accepts, per the Claude Code model reference: a family alias,
        // optionally with `[1m]` appended for the larger window.
        let documented: Set<String> = ["fable", "opus", "sonnet", "haiku", "fable[1m]", "opus[1m]", "sonnet[1m]"]
        XCTAssertEqual(Set(AgentModelCatalog.choices.map(\.argument)), documented)
        for choice in AgentModelCatalog.choices {
            XCTAssertEqual(choice.command, "/model \(choice.argument)")
            XCTAssertEqual(choice.hasExtendedContext, choice.argument.hasSuffix("[1m]"))
        }
    }

    func testChoicesAreDistinctAndLabelled() {
        XCTAssertEqual(Set(AgentModelCatalog.choices.map(\.id)).count, AgentModelCatalog.choices.count)
        XCTAssertEqual(Set(AgentModelCatalog.choices.map(\.label)).count, AgentModelCatalog.choices.count)
    }

    func testTheModelInUseIsTheLastTurnThatNamedOne() {
        let conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            RemoteAgentEntry(id: "a1", role: .assistant, blocks: [.text("hi")], model: "claude-fable-5-1"),
            RemoteAgentEntry(id: "a2", role: .assistant, blocks: [.text("limit")]),
            RemoteAgentEntry(id: "u1", role: .user, blocks: [.text("continue")]),
        ])
        XCTAssertEqual(conversation.currentModel, "claude-fable-5-1")
        XCTAssertNil(RemoteAgentConversation(tabID: "tab", agent: "claude").currentModel)
    }

    func testTheModelInUseIsMatchedToItsChoice() {
        XCTAssertEqual(AgentModelCatalog.choice(matchingModel: "claude-opus-5")?.argument, "opus")
        XCTAssertEqual(AgentModelCatalog.choice(matchingModel: "claude-opus-5[1m]")?.argument, "opus[1m]")
        XCTAssertEqual(AgentModelCatalog.choice(matchingModel: "claude-haiku-4-5-20251001")?.argument, "haiku")
        XCTAssertNil(AgentModelCatalog.choice(matchingModel: "claude-opus-4-8"), "an older release is not the current choice")
        XCTAssertNil(AgentModelCatalog.choice(matchingModel: "opus"), "an alias names no version")
        XCTAssertNil(AgentModelCatalog.choice(matchingModel: "<synthetic>"))
    }
}
