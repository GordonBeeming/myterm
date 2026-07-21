import MyTermCore
import SwiftUI

struct WorkspaceTabStrip: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { scrollProxy in
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(model.selectedWorkspace.tabs) { tab in
                            HStack(spacing: 5) {
                                Button {
                                    model.selectTab(tab.id)
                                } label: {
                                    Text(tabLabel(tab))
                                        .lineLimit(1)
                                        .frame(minWidth: 112, idealWidth: 136, maxWidth: 160, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Select \(tabLabel(tab)) tab")

                                if tab.id == model.selectedWorkspace.selectedTabID {
                                    Button {
                                        model.closeTab(tab.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Close \(tabLabel(tab)) tab")
                                }
                            }
                            .id(tab.id)
                            .contextMenu {
                                Button("Close Tab") { model.closeTab(tab.id) }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .onAppear {
                    scrollToSelectedTab(using: scrollProxy)
                }
                .onChange(of: model.selectedWorkspace.selectedTabID) { _, _ in
                    scrollToSelectedTab(using: scrollProxy)
                }

                Divider()
                    .frame(height: 20)

                Menu {
                    Button("New Terminal Tab") { model.createTerminalTab() }
                    Button("New Browser Tab") { model.createBrowserTab() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Add tab")
                .help("Add Tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func scrollToSelectedTab(using scrollProxy: ScrollViewProxy) {
        guard let selectedTabID = model.selectedWorkspace.selectedTabID else { return }
        scrollProxy.scrollTo(selectedTabID, anchor: .center)
    }

    private func tabLabel(_ tab: MyTermCore.Tab) -> String {
        switch tab.content {
        case .terminal: "Terminal"
        case .browser(let browser): browser.url.host ?? "Browser"
        }
    }
}
