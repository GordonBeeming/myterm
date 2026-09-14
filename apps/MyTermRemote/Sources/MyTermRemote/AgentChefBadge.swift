import MyTermCore
import SwiftUI

/// The cook, coloured for what the agent is doing.
///
/// Ported from the Mac app's `AgentChefBadge`. The one difference is how the state is announced:
/// `.help(...)` only exists on macOS, so this exposes an accessibility label instead, which is what
/// VoiceOver reads on iOS and iPadOS.
///
/// Blue asks to be tapped and purple says a question is waiting. A working agent keeps a neutral
/// colour and stirs instead: it is not asking for anything yet.
struct AgentChefBadge: View {
    let state: AgentActivity
    var side: CGFloat = 15

    /// The cook grows with the text beside it. At a fixed size it stays the size of a full stop
    /// next to accessibility type, which is the one case where the person most needs to see it.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        AgentChefIcon(color: color, isStirring: state == .working)
            .frame(width: side * scale, height: side * scale)
            .accessibilityLabel(state.attentionDescription)
    }

    private var color: Color {
        switch state {
        case .finished:
            .blue
        case .awaitingInput:
            .purple
        // A cook is never shown for these, so the colour is only a fallback. See
        // `AgentActivity.showsCook`, which is what keeps them off a tab.
        case .working, .ready, .exited:
            .secondary
        }
    }
}
