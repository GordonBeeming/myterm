import MyTermCore
import MyTermRemote
import SwiftUI

enum WorkspacePresentationStyle: String, CaseIterable {
    case adaptive, terminalList

    var title: String {
        switch self {
        case .adaptive: "Adaptive panes"
        case .terminalList: "Terminal list"
        }
    }
}

private struct WorkspaceVisibilityRequest: Hashable {
    let ownerID: UUID?
    let routes: [TerminalRoute]
}

struct AdaptiveWorkspaceView: View {
    let scene: SceneModel
    let workspace: RemoteWorkspaceItem
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("showTerminalKeys") private var showTerminalKeys = false
    private let paneSelections = PaneSelectionStore()
    @State private var visibilityOwnerID: UUID?
    @State private var selectedTabs: [TabGroupID: TabID] = [:]
    @State private var compactSelection: PaneSelection?
    @State private var focusedGroupID: TabGroupID?
    @State private var maximizedGroupID: TabGroupID?

    private var usesWideLayout: Bool { horizontalSizeClass == .regular && workspace.layout != nil }
    private var validMaximizedGroupID: TabGroupID? {
        guard let id = maximizedGroupID,
              workspace.groups.contains(where: { $0.id == id }),
              workspace.layout.map(groupIDs(in:))?.contains(id) == true else { return nil }
        return id
    }
    private var focusedGroup: RemoteTabGroupProjection? {
        workspace.groups.first { $0.id == focusedGroupID }
            ?? workspace.groups.first { $0.id == workspace.focusedGroupID }
            ?? workspace.groups.first
    }
    private var resolvedCompactSelection: (RemoteTabGroupProjection, RemoteTabProjection)? {
        paneSelections.resolve(in: workspace, preferring: compactSelection)
    }
    private var visibleRoutes: [TerminalRoute] {
        if usesWideLayout {
            let visibleGroups = Set(validMaximizedGroupID.map { [$0] } ?? workspace.layout.map(groupIDs(in:)) ?? [])
            return workspace.groups.filter { visibleGroups.contains($0.id) }.compactMap { group in
                selectedTab(in: group).flatMap { route(for: $0, group: group) }
            }
        }
        guard let (group, tab) = resolvedCompactSelection,
              let route = route(for: tab, group: group) else { return [] }
        return [route]
    }

    var body: some View {
        let visibility = WorkspaceVisibilityRequest(ownerID: visibilityOwnerID, routes: visibleRoutes)
        Group {
            if usesWideLayout, let layout = workspace.layout {
                if let id = validMaximizedGroupID {
                    groupPane(id)
                } else {
                    layoutView(layout)
                }
            } else if let (group, tab) = resolvedCompactSelection {
                // An inset rather than a stack, so the strip stays pinned under the navigation
                // bar and the terminal keeps every point below it.
                paneContent(tab, group: group, focused: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        paneSwitcher(selectedGroup: group, selectedTab: tab)
                    }
            } else {
                ContentUnavailableView("No terminals", systemImage: "terminal",
                                       description: Text("Create a terminal in this workspace."))
            }
        }
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !usesWideLayout {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(Array(workspace.groups.enumerated()), id: \.element.id) { index, group in
                            Section("Pane \(index + 1)") {
                                ForEach(group.tabs, id: \.id) { tab in
                                    Button(tab.title) { select(group: group, tab: tab) }
                                }
                            }
                        }
                        if let (group, tab) = resolvedCompactSelection {
                            Divider()
                            terminalCommands(tab, group: group)
                        }
                    } label: {
                        Label(resolvedCompactSelection?.1.title ?? "Terminals", systemImage: "chevron.down")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("workspace-terminal-picker")
                }
            }
            if usesWideLayout {
                ToolbarItem(placement: .primaryAction) {
                    Button(validMaximizedGroupID == nil ? "Maximise pane" : "Restore panes",
                           systemImage: validMaximizedGroupID == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                        maximizedGroupID = validMaximizedGroupID == nil ? focusedGroup?.id : nil
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .accessibilityIdentifier("toggle-maximise-pane")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                HideKeyboardButton()
                Button(showTerminalKeys ? "Hide terminal keys" : "Show terminal keys", systemImage: "keyboard") {
                    showTerminalKeys.toggle()
                }
                .accessibilityIdentifier("toggle-terminal-keys")
            }
        }
        .onAppear {
            visibilityOwnerID = UUID()
            if compactSelection == nil { compactSelection = paneSelections.selection(for: workspace.id) }
        }
        .onChange(of: workspace.groups.map(\.id)) { _, ids in
            if let maximizedGroupID, !ids.contains(maximizedGroupID) { self.maximizedGroupID = nil }
            if let groupID = compactSelection?.groupID, !ids.contains(groupID) {
                // The Mac closed the pane this device was pinned to. Forget the choice so the next
                // visit starts at the first pane instead of wherever the desktop is focused now.
                compactSelection = nil
                paneSelections.clear(for: workspace.id)
            }
        }
        .task(id: visibility) {
            guard let owner = visibility.ownerID, !Task.isCancelled else { return }
            await scene.configureVisibleWorkspaceTerminals(visibility.routes, ownerID: owner)
        }
        .onDisappear {
            visibilityOwnerID = nil
            guard let owner = visibility.ownerID else { return }
            Task { await scene.clearVisibleWorkspaceTerminals(ownerID: owner) }
        }
    }

    private func select(group: RemoteTabGroupProjection, tab: RemoteTabProjection?) {
        let selection = PaneSelection(groupID: group.id, tabID: tab?.id)
        compactSelection = selection
        paneSelections.select(selection, for: workspace.id)
    }

    /// The compact switcher: a row of panes, and a row of the selected pane's terminals when it
    /// holds more than one. Everything switches on a plain tap; nothing hides behind a long press.
    @ViewBuilder
    private func paneSwitcher(selectedGroup: RemoteTabGroupProjection,
                              selectedTab: RemoteTabProjection) -> some View {
        VStack(spacing: 0) {
            if workspace.groups.count > 1 {
                switcherStrip(identifier: "workspace-pane-switcher",
                              selectedID: selectedGroup.id.rawValue) {
                    ForEach(Array(workspace.groups.enumerated()), id: \.element.id) { index, group in
                        let isSelected = group.id == selectedGroup.id
                        paneChip(title: "Pane \(index + 1)",
                                 detail: (isSelected ? selectedTab : self.selectedTab(in: group))?.title,
                                 isSelected: isSelected,
                                 identifier: "workspace-pane-chip-\(index)") {
                            select(group: group, tab: nil)
                        }
                        .id(group.id.rawValue)
                    }
                }
            }
            if selectedGroup.tabs.count > 1 {
                switcherStrip(identifier: "workspace-terminal-switcher",
                              selectedID: selectedTab.id.rawValue) {
                    ForEach(Array(selectedGroup.tabs.enumerated()), id: \.element.id) { index, tab in
                        paneChip(title: tab.title, detail: nil,
                                 isSelected: tab.id == selectedTab.id,
                                 identifier: "workspace-terminal-chip-\(index)") {
                            select(group: selectedGroup, tab: tab)
                        }
                        .id(tab.id.rawValue)
                    }
                }
            }
        }
    }

    private func switcherStrip<Content: View>(identifier: String, selectedID: UUID,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) { content() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            // Without this the top strip inherits the navigation bar's edge effect, whose overlay
            // covers the chips and swallows their taps.
            .scrollEdgeEffectHidden(true, for: .top)
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
        .accessibilityIdentifier(identifier)
    }

    private func paneChip(title: String, detail: String?, isSelected: Bool, identifier: String,
                          onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedTab(in group: RemoteTabGroupProjection) -> RemoteTabProjection? {
        group.tabs.first { $0.id == selectedTabs[group.id] }
            ?? group.tabs.first { $0.id == group.selectedTabID }
            ?? group.tabs.first
    }

    private func route(for tab: RemoteTabProjection, group: RemoteTabGroupProjection) -> TerminalRoute? {
        guard tab.kind == .terminal, let sessionID = tab.terminalSessionID?.rawValue,
              let connectionID = scene.selectedConnectionID else { return nil }
        return TerminalRoute(connectionID: connectionID, workspaceID: workspace.id.rawValue,
                             groupID: group.id.rawValue, tabID: tab.id.rawValue,
                             sessionID: sessionID, title: tab.title)
    }

    @ViewBuilder
    private func paneContent(_ tab: RemoteTabProjection, group: RemoteTabGroupProjection,
                             focused: Bool) -> some View {
        if let route = route(for: tab, group: group) {
            CompanionTerminalPane(scene: scene, route: route,
                                  showTerminalKeys: showTerminalKeys && focused,
                                  requestsKeyboardFocus: focused,
                                  onToggleMaximise: usesWideLayout ? {
                                      focusedGroupID = group.id
                                      maximizedGroupID = maximizedGroupID == group.id ? nil : group.id
                                  } : nil)
                .id(route.id)
        } else if let connectionID = scene.selectedConnectionID {
            BrowserMetadataView(scene: scene, route: BrowserRoute(
                connectionID: connectionID, workspaceID: workspace.id.rawValue,
                groupID: group.id.rawValue, tabID: tab.id.rawValue,
                title: tab.title, url: tab.browserURL
            ), embedded: true)
        }
    }

    private func groupPane(_ groupID: TabGroupID) -> some View {
        Group {
            if let group = workspace.groups.first(where: { $0.id == groupID }),
               let tab = selectedTab(in: group) {
                VStack(spacing: 0) {
                    HStack {
                        Menu {
                            ForEach(group.tabs, id: \.id) { choice in
                                Button(choice.title) {
                                    focusedGroupID = group.id
                                    selectedTabs[group.id] = choice.id
                                }
                            }
                            Divider()
                            terminalCommands(tab, group: group)
                        } label: {
                            Label(tab.title, systemImage: tab.kind == .terminal ? "terminal" : "globe")
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(maximizedGroupID == groupID ? "Restore panes" : "Maximise pane",
                               systemImage: maximizedGroupID == groupID ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                            focusedGroupID = groupID
                            maximizedGroupID = maximizedGroupID == groupID ? nil : groupID
                        }
                        .labelStyle(.iconOnly)
                        if let route = route(for: tab, group: group) {
                            Button("Terminal actions", systemImage: "ellipsis") {
                                scene.sheet = .terminalActions(route)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(6)
                    .background(.bar)
                    paneContent(tab, group: group, focused: focusedGroup?.id == groupID)
                }
                .overlay(Rectangle().stroke(focusedGroup?.id == groupID ? Color.accentColor : .clear, lineWidth: 1))
                .simultaneousGesture(TapGesture().onEnded { focusedGroupID = groupID })
            } else {
                ContentUnavailableView("Pane unavailable", systemImage: "rectangle.slash")
            }
        }
    }

    @ViewBuilder
    private func terminalCommands(_ tab: RemoteTabProjection, group: RemoteTabGroupProjection) -> some View {
        if let route = route(for: tab, group: group) {
            Button("Terminal actions") { scene.sheet = .terminalActions(route) }
            Menu("Text size") {
                Button("Larger") { changeFont(route, by: 1) }
                Button("Smaller") { changeFont(route, by: -1) }
                Button("Reset") { scene.terminalStates[route.id]?.fontSize = 13 }
            }
        }
    }

    private func changeFont(_ route: TerminalRoute, by amount: CGFloat) {
        guard let state = scene.terminalStates[route.id] else { return }
        state.fontSize = min(28, max(8, state.fontSize + amount))
    }

    private func groupIDs(in node: RemotePaneLayout) -> [TabGroupID] {
        switch node {
        case .group(let id): [id]
        case .split(_, _, let children, _): children.flatMap { groupIDs(in: $0) }
        }
    }

    private func layoutView(_ node: RemotePaneLayout) -> AnyView {
        switch node {
        case .group(let id):
            return AnyView(groupPane(id))
        case .split(_, let orientation, let children, let weights):
            return AnyView(GeometryReader { geometry in
                let portions = normalizedWeights(weights, count: children.count)
                let horizontal = orientation == .horizontal
                let length = max(0, (horizontal ? geometry.size.width : geometry.size.height)
                                 - CGFloat(max(0, children.count - 1)))
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
                layout {
                    ForEach(children.indices, id: \.self) { index in
                        layoutView(children[index])
                            .frame(width: horizontal ? length * portions[index] : geometry.size.width,
                                   height: horizontal ? geometry.size.height : length * portions[index])
                            .clipped()
                    }
                }
            })
        }
    }

    private func normalizedWeights(_ weights: [Double], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard weights.count == count, weights.allSatisfy({ $0.isFinite && $0 > 0 }),
              weights.reduce(0, +).isFinite else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        let total = weights.reduce(0, +)
        return weights.map { CGFloat($0 / total) }
    }
}
