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
            HSplitView {
                ForEach(children, id: \.self) { child in
                    TerminalSplitTreeView(model: model, workspaceID: workspaceID, tabID: tabID, tree: child)
                }
            }
        case .vertical(let children):
            VSplitView {
                ForEach(children, id: \.self) { child in
                    TerminalSplitTreeView(model: model, workspaceID: workspaceID, tabID: tabID, tree: child)
                }
            }
        }
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
                TerminalSessionView(session: process)
                    .onTapGesture {
                        model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
                    }
                    .accessibilityLabel("Terminal pane")
            } else {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal")
            }

            Menu {
                Button("Split Horizontally") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.splitFocusedTerminal(orientation: .horizontal) }
                Button("Split Vertically") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.splitFocusedTerminal(orientation: .vertical) }
                Button("Close Pane") { model.focusTerminal(workspaceID: workspaceID, tabID: tabID, sessionID: session.id); model.closeFocusedPaneOrTab() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .padding(6)
            .accessibilityLabel("Terminal pane actions")
        }
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
