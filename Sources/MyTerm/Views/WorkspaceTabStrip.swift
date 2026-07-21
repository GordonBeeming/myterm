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
                            WorkspaceTabItem(
                                tab: tab,
                                isSelected: tab.id == model.selectedWorkspace.selectedTabID,
                                title: tabTitle(tab),
                                select: { model.selectTab(tab.id) },
                                rename: { model.beginRenamingTab(tab.id) },
                                close: { model.closeTab(tab.id) }
                            )
                            .id(tab.id)
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
                .focusable(false)
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

    private func tabTitle(_ tab: MyTermCore.Tab) -> String {
        if let customTitle = tab.customTitle {
            return customTitle
        }

        switch tab.content {
        case .terminal:
            return "Terminal"
        case .browser(let browser):
            return browser.url.host ?? "Browser"
        }
    }
}

private struct WorkspaceTabItem: View {
    let tab: MyTermCore.Tab
    let isSelected: Bool
    let title: String
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: tab.isBrowser ? "globe" : "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fontWeight(isSelected ? .medium : .regular)

                    Spacer(minLength: 18)
                }
                .padding(.horizontal, 8)
                .frame(width: 136, height: 26, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundStyle)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(borderStyle, lineWidth: isSelected ? 1 : 0.5)
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected tab" : "Tab")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(title)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(isSelected || isHovering ? 1 : 0)
            .allowsHitTesting(isSelected || isHovering)
            .accessibilityHidden(!(isSelected || isHovering))
            .accessibilityLabel("Close \(title) tab")
            .help("Close Tab")
            .padding(.trailing, 4)
        }
        .frame(width: 136, height: 26)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Tab…", action: rename)
            Divider()
            Button("Close Tab", action: close)
        }
    }

    private var backgroundStyle: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    private var borderStyle: Color {
        isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2)
    }
}
