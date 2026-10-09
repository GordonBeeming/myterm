import AppKit
import MyTermUI
import MyTermCore
import MyTermPlatform
import SwiftUI

struct BrowserTabView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tab: MyTermCore.Tab
    let browser: BrowserSession
    let closeLabel: String
    let isFocused: Bool

    var body: some View {
        if let controller = model.browserController(for: browser.id) {
            ObservedBrowserTabContent(
                model: model,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tab: tab,
                browser: browser,
                closeLabel: closeLabel,
                controller: controller,
                isFocused: isFocused
            )
        } else {
            ContentUnavailableView("Browser unavailable", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct ObservedBrowserTabContent: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tab: MyTermCore.Tab
    let browser: BrowserSession
    let closeLabel: String
    @ObservedObject var controller: BrowserSessionController
    let isFocused: Bool
    @State private var addressState = BrowserAddressFieldState()
    @State private var suggestionIndex = 0
    @State private var isFindVisible = false
    @State private var findQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar.zIndex(1)
            if let error = controller.state.errorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Browser error: \(error)")
            }
            BrowserSessionView(
                session: controller,
                isActive: isFocused,
                onFocused: {
                    model.browserDidBecomeFirstResponder(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        tabID: tab.id,
                        sessionID: browser.id
                    )
                }
            )
                .simultaneousGesture(TapGesture().onEnded { select() })
                .accessibilityLabel("Browser pane \(paneTitle), \(isFocused ? "active" : "inactive")")
                .overlay(alignment: .topTrailing) {
                    if isFindVisible { browserFindBar.padding(8) }
                }
        }
        .onAppear { addressState.synchronizeNavigationText(controller.state.url?.absoluteString ?? "") }
        .onChange(of: controller.state.url) { _, url in
            guard let url else { return }
            addressState.synchronizeNavigationText(url.absoluteString)
            model.persistBrowserURL(url, workspaceID: workspaceID, tabID: tab.id, browserID: browser.id)
        }
        .onAppear(perform: handleBrowserRequests)
        .onChange(of: model.browserAddressFocusRequest) { _, _ in handleBrowserRequests() }
        .onChange(of: model.browserFindRequest) { _, _ in handleBrowserRequests() }
    }

    private var browserToolbar: some View {
        HStack(spacing: 4) {
            browserButton("chevron.left", label: "Back", disabled: !controller.state.canGoBack) { controller.goBack() }
            browserButton("chevron.right", label: "Forward", disabled: !controller.state.canGoForward) { controller.goForward() }
            browserButton(
                controller.state.isLoading ? "stop.fill" : "arrow.clockwise",
                label: controller.state.isLoading ? "Stop loading" : "Reload",
                disabled: false
            ) {
                controller.state.isLoading ? controller.stopLoading() : controller.reload()
            }

            addressCapsule
            browserButton("magnifyingglass", label: "Find in page", disabled: false) {
                if isFindVisible { dismissFind() } else {
                    isFindVisible = true
                    selectWithoutFocusingContent()
                    model.requestSelectedBrowserFind()
                }
            }
            .background(isFindVisible ? Theme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 8))

            PaneActionsMenu(
                select: select,
                split: { model.splitFocusedTerminal(orientation: $0) },
                close: model.closeFocusedPaneOrTab,
                closeLabel: closeLabel,
                paneTitle: paneTitle,
                isActive: isFocused
            )
        }
        .padding(8)
        .background(Theme.paneHeader)
    }

    private var workspace: Workspace? { model.workspaces.first { $0.id == workspaceID } }

    private var suggestions: [BrowserAddressSuggestions.Suggestion] {
        BrowserAddressSuggestions.suggestions(text: addressState.text, openTabs: workspace?.allTabs.compactMap { tab in
            guard case .browser(let browser) = tab.content else { return nil }
            let url = model.browserController(for: browser.id)?.state.url ?? browser.url
            return .init(title: tab.customTitle ?? tab.automaticDisplayTitle, url: url, tabID: tab.id)
        } ?? [], currentTabID: tab.id)
    }

    private var addressCapsule: some View {
        HStack(spacing: 8) {
            switch BrowserAddressSecurity.classify(controller.state.url) {
            case .secure:
                Image(systemName: "lock").foregroundStyle(Theme.textSecondary).accessibilityLabel("Secure connection")
            case .local:
                Text("local").font(Theme.Font.ui(11)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).frame(height: 18).background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
            case .insecure:
                Image(systemName: "lock.open").foregroundStyle(Theme.textSecondary)
                    .help("Not secure")
                    .accessibilityLabel("Not secure connection")
            case .none:
                EmptyView()
            }
            BrowserAddressTextField(
                text: Binding(get: { addressState.text }, set: { addressState.updateFromUser($0); suggestionIndex = 0 }),
                beginEditing: { selectWithoutFocusingContent(); suggestionIndex = 0; return addressState.beginEditing() },
                endEditing: { addressState.endEditing(navigationText: controller.state.url?.absoluteString) },
                submit: performSelectedSuggestion,
                submitBackwards: performSelectedSuggestion,
                focusToken: addressFocusToken,
                didFocus: acknowledgeAddressFocus,
                onEscape: focusBrowserContent,
                moveSelection: moveSuggestion,
                displayURL: controller.state.url
            )
            .frame(maxWidth: .infinity)
            if addressState.isEditing {
                Text("⏎ to go").font(Theme.Font.mono(11)).foregroundStyle(Theme.textTertiary)
            } else {
                browserDataChip
            }
        }
        .font(Theme.Font.ui(13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(addressState.isEditing ? Theme.accent : Theme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(addressState.isEditing ? 0.18 : 0), lineWidth: 3)
                .padding(-1.5)
        }
        .overlay(alignment: .bottomLeading) {
            if controller.state.isLoading {
                GeometryReader { geometry in
                    Theme.accent.frame(width: geometry.size.width * min(1, max(0, controller.state.estimatedProgress)), height: 2)
                }
                .frame(height: 2).padding(.horizontal, 10)
                .accessibilityLabel("Page loading progress")
                .accessibilityValue("\(Int((controller.state.estimatedProgress * 100).rounded())) percent")
            }
        }
        .overlay(alignment: .topLeading) {
            if addressState.isEditing, !suggestions.isEmpty {
                suggestionDropdown.offset(y: 40)
            }
        }
    }

    @ViewBuilder private var browserDataChip: some View {
        if let profile = browser.profile, profile.scope != .appWide {
            let folder = model.folders.first { $0.id == workspace?.folderID }
            let name = profile.scope == .folder ? (folder?.title ?? "No folder")
                : profile.scope == .projectDirectory ? (profile.projectDirectory?.lastPathComponent ?? "Project")
                : (workspace?.title ?? "Workspace")
            HStack(spacing: 5) {
                if profile.scope == .workspace, let emoji = workspace?.emoji { Text(emoji) } else {
                    Image(systemName: profile.scope == .workspace ? "square.stack" : "folder.fill")
                        .foregroundStyle(profile.scope == .folder ? (folder?.color.swiftUIColor ?? Theme.textSecondary) : Theme.textSecondary)
                }
                Text(name).lineLimit(1)
            }
            .font(Theme.Font.ui(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
            .help("Browser data: \(name)")
            .accessibilityLabel("Browser data: \(name)")
        }
    }

    private var suggestionDropdown: some View {
        VStack(spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button { performSuggestion(suggestion) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.action.isNavigation ? "arrow.right" : "globe")
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).font(Theme.Font.ui(13)).foregroundStyle(Theme.textPrimary)
                            Text(suggestion.detail).font(Theme.Font.mono(11)).foregroundStyle(Theme.textSecondary)
                        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(suggestion.action.isNavigation ? "Enter" : "Switch to tab")
                            .font(Theme.Font.ui(11)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(index == suggestionIndex ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).focusable(false)
                .accessibilityValue(index == suggestionIndex ? "Selected suggestion" : "")
            }
            Theme.hairline.frame(height: 1).padding(.top, 4)
            Text("↑↓ choose · ⏎ open · esc back to the page")
                .font(Theme.Font.ui(11)).foregroundStyle(Theme.textTertiary).padding(8)
        }
        .padding(6).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        .accessibilityElement(children: .contain).accessibilityLabel("Address suggestions")
    }

    private func moveSuggestion(_ offset: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = min(suggestions.count - 1, max(0, suggestionIndex + offset))
    }

    private func performSelectedSuggestion(_ text: String) {
        // The native editor can submit before SwiftUI has refreshed the suggestion rows.
        if text != addressState.text { addressState.updateFromUser(text); suggestionIndex = 0 }
        guard suggestions.indices.contains(suggestionIndex) else { loadAddress(text); return }
        performSuggestion(suggestions[suggestionIndex])
    }

    private func performSuggestion(_ suggestion: BrowserAddressSuggestions.Suggestion) {
        switch suggestion.action {
        case .navigate(let text): loadAddress(text)
        case .switchTab(let id):
            guard let group = workspace?.layout.orderedGroups.first(where: { $0.tabs.contains { $0.id == id } }) else { return }
            addressState.endEditing(navigationText: controller.state.url?.absoluteString)
            model.selectTab(id, in: group.id)
        }
    }

    private func browserButton(
        _ image: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            selectWithoutFocusingContent()
            action()
        } label: {
            Image(systemName: image)
                .frame(width: 32, height: 32)
                .foregroundStyle(disabled ? Theme.textDisabled : Theme.textSecondary)
        }
        .buttonStyle(BrowserQuietButtonStyle())
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }

    private func loadAddress(_ text: String) {
        model.loadBrowserAddress(
            addressState.prepareSubmission(fieldText: text),
            workspaceID: workspaceID,
            tabID: tab.id,
            browserID: browser.id
        )
        focusBrowserContent()
    }

    private func select() { model.selectTab(tab.id, in: tabGroupID) }
    private func selectWithoutFocusingContent() { model.selectTab(tab.id, in: tabGroupID, focusContent: false) }
    private func focusBrowserContent() {
        addressState.endEditing(navigationText: controller.state.url?.absoluteString)
        controller.webView.window?.makeFirstResponder(controller.webView)
    }
    private var paneTitle: String { tab.customTitle ?? tab.automaticDisplayTitle }
    private var addressFocusToken: UInt64? {
        guard model.browserAddressFocusRequest?.sessionID == browser.id else { return nil }
        return model.browserAddressFocusRequest?.token
    }
    private var findFocusToken: UInt64? {
        guard model.browserFindRequest?.sessionID == browser.id else { return nil }
        return model.browserFindRequest?.token
    }

    private var browserFindBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            BrowserAddressTextField(
                text: $findQuery,
                beginEditing: { selectWithoutFocusingContent(); return true },
                endEditing: {},
                submit: { findInPane($0) },
                submitBackwards: { findInPane($0, backwards: true) },
                focusToken: findFocusToken,
                didFocus: acknowledgeFind,
                onEscape: dismissFind,
                presentation: .findInPage
            )
            .frame(width: 180, height: 28)
            browserButton("chevron.up", label: "Previous match", disabled: findQuery.isEmpty) {
                findInPane(findQuery, backwards: true)
            }
            browserButton("chevron.down", label: "Next match", disabled: findQuery.isEmpty) {
                findInPane(findQuery)
            }
            Button(action: dismissFind) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .accessibilityLabel("Close find")
        }
        .padding(6)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in page")
    }

    private func findInPane(_ query: String, backwards: Bool = false) {
        selectWithoutFocusingContent()
        controller.find(query, backwards: backwards)
    }

    private func handleBrowserRequests() {
        if findFocusToken != nil { isFindVisible = true }
    }
    private func acknowledgeAddressFocus(_ token: UInt64) {
        model.acknowledgeBrowserAddressFocus(sessionID: browser.id, token: token)
    }
    private func acknowledgeFind(_ token: UInt64) {
        model.acknowledgeBrowserFind(sessionID: browser.id, token: token)
    }
    private func dismissFind() {
        isFindVisible = false
        focusBrowserContent()
    }
}

struct PaneActionsMenu: View {
    let select: () -> Void
    let split: (SplitOrientation) -> Void
    let close: () -> Void
    var closeLabel = "Close Pane"
    let paneTitle: String
    let isActive: Bool

    var body: some View {
        Menu {
            Button("Split Right") { select(); split(.horizontal) }
            Button("Split Below") { select(); split(.vertical) }
            Button(closeLabel) { select(); close() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .accessibilityLabel("Pane actions for \(paneTitle), \(isActive ? "active" : "inactive")")
        .help("Pane Actions")
    }
}

private extension BrowserAddressSuggestions.Action {
    var isNavigation: Bool {
        if case .navigate = self { return true }
        return false
    }
}

private struct BrowserQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false
        var body: some View {
            configuration.label
                .background(isHovering || configuration.isPressed ? Theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { isHovering = $0 }
        }
    }
}

enum BrowserAddressSecurity: Equatable {
    case secure
    case local
    case insecure
    case none

    static func classify(_ url: URL?) -> Self {
        guard let url else { return .none }
        switch url.scheme?.lowercased() {
        case "https": return .secure
        case "file": return .local
        case "http":
            let host = (url.host ?? "").lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
            if normalizedHost == "localhost" || normalizedHost.hasSuffix(".localhost")
                || normalizedHost == "127.0.0.1" || normalizedHost == "::1" {
                return .local
            }
            return .insecure
        default: return .none
        }
    }
}
