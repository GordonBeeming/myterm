import MyTermCore
import SwiftUI

struct PaneGroupView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let group: TabGroup
    @State private var paneTabDragRegistrationID = PaneTabDragRegistrationID()

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            VStack(spacing: 0) {
                WorkspaceTabStrip(
                    model: model,
                    workspaceID: workspaceID,
                    tabGroup: group,
                    paneTabDragRegistrationID: paneTabDragRegistrationID
                )
                Divider()
                PaneContentView(
                    model: model,
                    workspaceID: workspaceID,
                    tabGroupID: group.id,
                    tab: group.selectedTab,
                    tabCount: group.tabs.count,
                    isFocused: isFocused
                )
            }
            .overlay {
                if let previewFrame = dropPreviewFrame(in: proxy.size) {
                    dropPreview
                        .frame(width: previewFrame.width, height: previewFrame.height)
                        .position(x: previewFrame.midX, y: previewFrame.midY)
                }
            }
            .background(isFocused ? Color.accentColor.opacity(0.045) : Color.clear)
            .background(
                Color.clear
                    .onAppear {
                        model.registerPaneTabDragPaneBody(
                            workspaceID: workspaceID,
                            tabGroupID: group.id,
                            registrationID: paneTabDragRegistrationID,
                            frame: frame
                        )
                    }
                    .onChange(of: frame) { _, updatedFrame in
                        model.registerPaneTabDragPaneBody(
                            workspaceID: workspaceID,
                            tabGroupID: group.id,
                            registrationID: paneTabDragRegistrationID,
                            frame: updatedFrame
                        )
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.16), lineWidth: isFocused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pane \(group.selectedTab.customTitle ?? group.selectedTab.automaticDisplayTitle)")
            .accessibilityValue(isFocused ? "Active pane" : "Inactive pane")
            .onDisappear {
                model.unregisterPaneTabDragPane(
                    workspaceID: workspaceID,
                    tabGroupID: group.id,
                    registrationID: paneTabDragRegistrationID
                )
            }
        }
    }

    private var isFocused: Bool {
        let workspace = model.selectedWorkspace
        return workspace.id == workspaceID && workspace.focusedTabGroupID == group.id
    }

    private func dropPreviewFrame(in size: CGSize) -> CGRect? {
        switch model.paneTabDragPreviewTarget {
        case .paneCenter(let tabGroupID) where tabGroupID == group.id:
            PaneTabDropPreviewFrame.centerFrame(in: size)
        case .paneBody(let tabGroupID, let edge) where tabGroupID == group.id:
            PaneTabDropPreviewFrame.frame(for: edge, in: size)
        default:
            nil
        }
    }

    private var dropPreview: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        Color.accentColor.opacity(0.8),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct PaneContentView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tab: MyTermCore.Tab
    let tabCount: Int
    let isFocused: Bool

    var body: some View {
        switch tab.content {
        case .terminal(let session):
            TerminalPaneView(
                model: model,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tab: tab,
                session: session,
                closeLabel: closeLabel,
                isFocused: isFocused
            )
        case .browser(let browser):
            BrowserTabView(
                model: model,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tab: tab,
                browser: browser,
                closeLabel: closeLabel,
                isFocused: isFocused
            )
        }
    }

    private var closeLabel: String { tabCount == 1 ? "Close Pane" : "Close Tab" }
}
