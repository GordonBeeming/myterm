import MyTermCore
import MyTermPlatform
import SwiftUI

struct ActiveTabView: View {
    let model: AppModel

    var body: some View {
        if let tab = model.selectedTab {
            switch tab.content {
            case .terminal(let tree):
                TerminalSplitTreeView(
                    model: model,
                    workspaceID: model.store.selectedWorkspaceID,
                    tabID: tab.id,
                    tree: tree
                )
            case .browser(let browser):
                if let controller = model.browserController(for: browser.id) {
                    BrowserTabView(
                        model: model,
                        workspaceID: model.store.selectedWorkspaceID,
                        tabID: tab.id,
                        browserID: browser.id,
                        controller: controller
                    )
                } else {
                    ContentUnavailableView("Browser unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        } else {
            ContentUnavailableView("No tab selected", systemImage: "rectangle.on.rectangle")
        }
    }
}

private struct TerminalSplitTreeView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabID: TabID
    let tree: SplitNode

    var body: some View {
        switch tree {
        case .terminal(let session):
            TerminalPaneView(model: model, workspaceID: workspaceID, tabID: tabID, session: session)
                .id(session.id)
        case .horizontal(let children):
            StableTerminalSplitGroup(
                model: model,
                workspaceID: workspaceID,
                tabID: tabID,
                children: children,
                orientation: .horizontal
            )
        case .vertical(let children):
            StableTerminalSplitGroup(
                model: model,
                workspaceID: workspaceID,
                tabID: tabID,
                children: children,
                orientation: .vertical
            )
        }
    }
}

private struct StableTerminalSplitGroup: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabID: TabID
    let children: [SplitNode]
    let orientation: SplitOrientation

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let height = max(0, proxy.size.height)
            let primaryLength = orientation == .horizontal ? width : height
            let lengths = TerminalSplitGeometry.childLengths(
                totalLength: primaryLength,
                childCount: children.count
            )

            if orientation == .horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.stableID) { index, child in
                        splitChild(child, width: lengths[index], height: height)
                        if index < children.count - 1 {
                            divider(width: TerminalSplitGeometry.dividerThickness, height: height)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.stableID) { index, child in
                        splitChild(child, width: width, height: lengths[index])
                        if index < children.count - 1 {
                            divider(width: width, height: TerminalSplitGeometry.dividerThickness)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
        }
    }

    private func splitChild(_ child: SplitNode, width: CGFloat, height: CGFloat) -> some View {
        TerminalSplitTreeView(
            model: model,
            workspaceID: workspaceID,
            tabID: tabID,
            tree: child
        )
        .frame(width: width, height: height)
        .clipped()
    }

    private func divider(width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

enum TerminalSplitGeometry {
    static let dividerThickness: CGFloat = 1

    static func childLengths(totalLength: CGFloat, childCount: Int) -> [CGFloat] {
        guard childCount > 0 else { return [] }
        let dividerLength = dividerThickness * CGFloat(max(0, childCount - 1))
        let childLength = max(0, totalLength - dividerLength) / CGFloat(childCount)
        return Array(repeating: childLength, count: childCount)
    }

}

private struct TerminalPaneView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabID: TabID
    let session: TerminalSession

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let process = model.terminalSession(for: session.id) {
                TerminalSessionView(session: process, isActive: isFocused)
                    .opacity(isFocused ? 1 : 0.7)
                    .animation(.easeOut(duration: 0.12), value: isFocused)
                    .onTapGesture {
                        model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
                    }
                    .accessibilityLabel("Terminal pane")
            } else {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal")
            }

            Menu {
                Button("Split Right") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.splitFocusedTerminal(orientation: .horizontal) }
                Button("Split Below") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.splitFocusedTerminal(orientation: .vertical) }
                Button("Close Pane") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.closeFocusedPaneOrTab() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .padding(6)
            .accessibilityLabel("Terminal pane actions")
        }
    }

    private var isFocused: Bool {
        model.selectedTab?.focusedTerminalSessionID == session.id
    }
}

private struct BrowserTabView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabID: TabID
    let browserID: BrowserSessionID
    @ObservedObject var controller: BrowserSessionController
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: controller.goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!controller.state.canGoBack)
                Button(action: controller.goForward) {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!controller.state.canGoForward)
                Button(action: controller.reload) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                TextField("Address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.loadBrowserAddress(address, workspaceID: workspaceID, tabID: tabID, browserID: browserID)
                    }
                    .accessibilityLabel("Browser address")
            }
            .padding(8)
            if let error = controller.state.errorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Browser error: \(error)")
            }
            BrowserSessionView(session: controller)
        }
        .onAppear { address = controller.state.url?.absoluteString ?? "" }
        .onChange(of: controller.state.url) { _, url in
            guard let url else { return }
            address = url.absoluteString
            model.persistBrowserURL(url, workspaceID: workspaceID, tabID: tabID)
        }
    }

}
