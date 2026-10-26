import MyTermCore
import SwiftUI

struct SessionNavigationView: View {
    let model: AppModel
    let inbox: Bool
    @State private var query = ""
    @State private var selection: TabID?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var navigationItems: [SessionNavigationItem] {
        SessionNavigationItem.items(in: model.companionWorkspaceProjection(), query: query, prioritizeAttention: inbox,
                                    recentTabIDs: model.recentSessionTabIDs)
            .filter { !inbox || $0.tab.kind == .terminal }
    }

    var body: some View {
        // One projection/search snapshot per render, shared by the list and action closures.
        let items = navigationItems
        VStack(spacing: 12) {
            HStack {
                Text(inbox ? "Session inbox" : "Jump to a tab").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search tabs, workspaces, folders or paths", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { open(items.first { $0.id == selection } ?? items.first) }
            if items.isEmpty {
                ContentUnavailableView(inbox ? "No terminal sessions" : "No matching tabs",
                                       systemImage: inbox ? "tray" : "magnifyingglass")
            } else {
                List(items, selection: $selection) { item in
                    Button { open(item) } label: {
                        HStack {
                            Image(systemName: item.tab.agentActivity == .awaitingInput ? "questionmark.circle" :
                                    item.tab.kind == .browser ? "globe" : "terminal")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.tab.title)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let activity = item.tab.agentActivity, activity.needsAttention {
                                Text(activity == .awaitingInput ? "Needs reply" : "Finished")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).tag(item.id)
                }
            }
            if inbox {
                Text(items.contains { $0.tab.agentActivity?.needsAttention == true } ? "Sessions needing attention appear first." : "All caught up. Your sessions remain available below.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Newest attention first. Reading a question keeps it here until the agent continues.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding().frame(width: 620, height: 450)
        .onAppear { searchFocused = true; selection = items.first?.id }
        .onChange(of: query) { _, _ in selection = items.first?.id }
        .onKeyPress(.return) { open(items.first { $0.id == selection } ?? items.first); return .handled }
    }

    private func open(_ item: SessionNavigationItem?) {
        guard let item else { return }
        model.revealTab(item.id, in: item.workspaceID)
        dismiss()
    }
}
