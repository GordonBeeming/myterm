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
    @State private var visibilityOwnerID: UUID?
    @State private var selectedTabs: [TabGroupID: TabID] = [:]
    @State private var compactTabID: TabID?
    @State private var focusedGroupID: TabGroupID?

    private var usesWideLayout: Bool { horizontalSizeClass == .regular && workspace.layout != nil }
    private var focusedGroup: RemoteTabGroupProjection? {
        workspace.groups.first { $0.id == focusedGroupID }
            ?? workspace.groups.first { $0.id == workspace.focusedGroupID }
            ?? workspace.groups.first
    }
    private var compactSelection: (RemoteTabGroupProjection, RemoteTabProjection)? {
        if let compactTabID {
            for group in workspace.groups {
                if let tab = group.tabs.first(where: { $0.id == compactTabID }) { return (group, tab) }
            }
        }
        guard let group = focusedGroup, let tab = selectedTab(in: group) else { return nil }
        return (group, tab)
    }
    private var visibleRoutes: [TerminalRoute] {
        if usesWideLayout {
            let visibleGroups = Set(workspace.layout.map(groupIDs(in:)) ?? [])
            return workspace.groups.filter { visibleGroups.contains($0.id) }.compactMap { group in
                selectedTab(in: group).flatMap { route(for: $0, group: group) }
            }
        }
        guard let (group, tab) = compactSelection, let route = route(for: tab, group: group) else { return [] }
        return [route]
    }

    var body: some View {
        let visibility = WorkspaceVisibilityRequest(ownerID: visibilityOwnerID, routes: visibleRoutes)
        Group {
            if usesWideLayout, let layout = workspace.layout {
                layoutView(layout)
            } else if let (group, tab) = compactSelection {
                paneContent(tab, group: group, focused: true)
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
                                    Button(tab.title) { compactTabID = tab.id }
                                }
                            }
                        }
                        if let (group, tab) = compactSelection {
                            Divider()
                            terminalCommands(tab, group: group)
                        }
                    } label: {
                        Label(compactSelection?.1.title ?? "Terminals", systemImage: "chevron.down")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("workspace-terminal-picker")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(showTerminalKeys ? "Hide terminal keys" : "Show terminal keys", systemImage: "keyboard") {
                    showTerminalKeys.toggle()
                }
                .accessibilityIdentifier("toggle-terminal-keys")
            }
        }
        .onAppear { visibilityOwnerID = UUID() }
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
                                  requestsKeyboardFocus: focused)
                .id(route.id)
        } else if let connectionID = scene.selectedConnectionID {
            BrowserMetadataView(scene: scene, route: BrowserRoute(
                connectionID: connectionID, workspaceID: workspace.id.rawValue,
                groupID: group.id.rawValue, tabID: tab.id.rawValue,
                title: tab.title, url: tab.browserURL
            ))
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
