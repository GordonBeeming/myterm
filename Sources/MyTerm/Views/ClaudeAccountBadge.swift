import MyTermCore
import MyTermUI
import SwiftUI

/// Names the Claude account a workspace's Claude Code runs as, beside its agent icon.
struct ClaudeAccountBadge: View {
    let account: ClaudeAccount

    var body: some View {
        Text(account.shortName)
            .font(Theme.Font.ui(10.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(.quaternary))
            .frame(maxWidth: 120, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .help("Claude Code as \(account.detail)")
            .accessibilityHidden(true)
    }
}
