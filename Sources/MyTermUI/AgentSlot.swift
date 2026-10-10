import MyTermCore
import SwiftUI

public struct AgentSlot<Fallback: View>: View {
    private let attention: AgentActivity?
    private let identity: AgentIdentity?
    private let showsIdleIdentity: Bool
    private let side: CGFloat
    private let fallback: Fallback

    public init(
        attention: AgentActivity?,
        identity: AgentIdentity?,
        showsIdleIdentity: Bool,
        side: CGFloat = 15,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.attention = attention
        self.identity = identity
        self.showsIdleIdentity = showsIdleIdentity
        self.side = side
        self.fallback = fallback()
    }

    public var body: some View {
        Group {
            if let attention, attention.showsCook {
                AgentChefBadge(state: attention, side: side)
            } else if showsIdleIdentity, let identity {
                AgentIdentityIcon(identity: identity)
                    .frame(width: side, height: side)
            } else {
                fallback
            }
        }
    }
}

extension AgentSlot where Fallback == EmptyView {
    public init(
        attention: AgentActivity?,
        identity: AgentIdentity?,
        showsIdleIdentity: Bool,
        side: CGFloat = 15
    ) {
        self.init(attention: attention, identity: identity, showsIdleIdentity: showsIdleIdentity, side: side) {
            EmptyView()
        }
    }
}
