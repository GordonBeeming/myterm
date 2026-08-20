import MyTermCore
import SwiftUI

/// The cook, coloured for what the agent is doing.
///
/// Blue asks to be clicked and purple says a question is waiting. A working agent keeps a neutral
/// colour and stirs instead: it is not asking for anything yet. A session with nothing left to say
/// has no cook at all, so there is no state here for it.
struct AgentChefBadge: View {
    let state: AgentActivity
    var side: CGFloat = 15

    var body: some View {
        AgentChefIcon(color: color, isStirring: state == .working)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
            .help(state.attentionDescription)
    }

    private var color: Color {
        switch state {
        case .finished:
            .blue
        case .awaitingInput:
            .purple
        case .working:
            .secondary
        }
    }
}
