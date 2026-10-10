import MyTermCore
import SwiftUI

/// What the agent is doing, drawn with the icon and colour chosen for that state in Settings.
///
/// Only working, finished and a question reach a tab: `AgentActivity.showsCook` keeps ready and
/// exited off it, so their plain cook here is a fallback rather than something users see.
public struct AgentChefBadge: View {
    let state: AgentActivity
    var side: CGFloat = 15
    @Environment(\.agentIndicatorAppearance) private var appearance

    public init(state: AgentActivity, side: CGFloat = 15) {
        self.state = state
        self.side = side
    }

    public var body: some View {
        Group {
            switch state {
            case .finished:
                AgentStateGlyph(finished: appearance.finishedIcon, color: appearance.finishedColor.indicatorColor, side: side)
            case .awaitingInput:
                AgentStateGlyph(question: appearance.questionIcon, color: appearance.questionColor.indicatorColor, side: side)
            case .working:
                AgentStateGlyph(working: appearance.workingIcon, color: appearance.workingColor.indicatorColor, side: side)
            case .ready, .exited:
                AgentChefIcon(color: .secondary, isStirring: false)
                    .frame(width: side, height: side)
            }
        }
        .accessibilityHidden(true)
        #if os(macOS)
        .help(state.attentionDescription)
        #endif
    }
}
