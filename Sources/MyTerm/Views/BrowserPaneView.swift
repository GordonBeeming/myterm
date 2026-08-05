import AppKit
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
    @State private var isFindVisible = false
    @State private var findQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            ProgressView(value: controller.state.estimatedProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
                .opacity(controller.state.isLoading ? 1 : 0)
                .accessibilityHidden(!controller.state.isLoading)
                .accessibilityLabel("Page loading progress")
                .accessibilityValue(
                    "\(Int((controller.state.estimatedProgress * 100).rounded())) percent"
                )
            if let error = controller.state.errorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Browser error: \(error)")
            }
            BrowserSessionView(session: controller, isActive: isFocused)
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

            BrowserAddressTextField(
                text: Binding(get: { addressState.text }, set: { addressState.updateFromUser($0) }),
                beginEditing: { selectWithoutFocusingContent(); return addressState.beginEditing() },
                endEditing: { addressState.endEditing(navigationText: controller.state.url?.absoluteString) },
                submit: loadAddress,
                submitBackwards: loadAddress,
                focusToken: addressFocusToken,
                didFocus: acknowledgeAddressFocus,
                onEscape: focusBrowserContent
            )
            .frame(minHeight: 18)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))

            PaneActionsMenu(
                select: select,
                split: { model.splitFocusedTerminal(orientation: $0) },
                close: model.closeFocusedPaneOrTab,
                closeLabel: closeLabel,
                paneTitle: paneTitle,
                isActive: isFocused
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(width: 24, height: 24)
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
    private func focusBrowserContent() { controller.webView.window?.makeFirstResponder(controller.webView) }
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
                submit: { model.findInSelectedBrowser($0) },
                submitBackwards: { model.findInSelectedBrowser($0, backwards: true) },
                focusToken: findFocusToken,
                didFocus: acknowledgeFind,
                onEscape: dismissFind,
                presentation: .findInPage
            )
            .frame(width: 220, height: 22)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in page")
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

private struct BrowserAddressTextField: NSViewRepresentable {
    @Binding var text: String
    let beginEditing: () -> Bool
    let endEditing: () -> Void
    let submit: (String) -> Void
    let submitBackwards: (String) -> Void
    let focusToken: UInt64?
    let didFocus: (UInt64) -> Void
    let onEscape: () -> Void
    var presentation = BrowserTextFieldPresentation.browserAddress

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            beginEditing: beginEditing,
            endEditing: endEditing,
            submit: submit,
            submitBackwards: submitBackwards,
            didFocus: didFocus,
            onEscape: onEscape
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .default
        field.placeholderString = presentation.placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.toolTip = presentation.accessibilityLabel
        field.setAccessibilityLabel(presentation.accessibilityLabel)
        field.setAccessibilityHelp(presentation.accessibilityHelp)
        return field
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.beginEditing = beginEditing
        context.coordinator.endEditing = endEditing
        context.coordinator.submit = submit
        context.coordinator.submitBackwards = submitBackwards
        context.coordinator.didFocus = didFocus
        context.coordinator.onEscape = onEscape
        if textField.currentEditor() == nil, textField.stringValue != text { textField.stringValue = text }
        context.coordinator.focusIfRequested(textField, token: focusToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var beginEditing: () -> Bool
        var endEditing: () -> Void
        var submit: (String) -> Void
        var submitBackwards: (String) -> Void
        var didFocus: (UInt64) -> Void
        var onEscape: () -> Void
        private var lastFocusedToken: UInt64?

        init(
            text: Binding<String>,
            beginEditing: @escaping () -> Bool,
            endEditing: @escaping () -> Void,
            submit: @escaping (String) -> Void,
            submitBackwards: @escaping (String) -> Void,
            didFocus: @escaping (UInt64) -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.text = text
            self.beginEditing = beginEditing
            self.endEditing = endEditing
            self.submit = submit
            self.submitBackwards = submitBackwards
            self.didFocus = didFocus
            self.onEscape = onEscape
        }

        func focusIfRequested(_ field: NSTextField, token: UInt64?) {
            guard let token, token != lastFocusedToken else { return }
            lastFocusedToken = token
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
                self.didFocus(token)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard beginEditing() else { return }
            (notification.object as? NSTextField)?.currentEditor()?.selectAll(nil)
        }
        func controlTextDidEndEditing(_ notification: Notification) { endEditing() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { submitBackwards(textView.string) } else { submit(textView.string) }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape(); return true }
            return false
        }
    }
}
