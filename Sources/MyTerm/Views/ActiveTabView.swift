import AppKit
import MyTermCore
import MyTermPlatform
import SwiftUI

struct BrowserAddressFieldState {
    private(set) var text = ""
    private(set) var isEditing = false

    mutating func beginEditing() -> Bool {
        guard !isEditing else { return false }
        isEditing = true
        return true
    }

    mutating func updateFromUser(_ text: String) {
        self.text = text
    }

    mutating func synchronizeNavigationText(_ text: String) {
        guard !isEditing else { return }
        self.text = text
    }

    mutating func endEditing(navigationText: String?) {
        isEditing = false
        if let navigationText {
            text = navigationText
        }
    }

    mutating func prepareSubmission(fieldText: String) -> String {
        text = fieldText
        isEditing = false
        return fieldText
    }
}

struct ActiveTabView: View {
    let model: AppModel

    var body: some View {
        if let tab = model.selectedTab {
            TerminalSplitTreeView(
                model: model,
                workspaceID: model.store.selectedWorkspaceID,
                tabID: tab.id,
                tree: tab.splitTree
            )
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
        case .browser(let browser):
            if let controller = model.browserController(for: browser.id) {
                BrowserTabView(
                    model: model,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    browserID: browser.id,
                    paneID: browser.paneID,
                    controller: controller
                )
                .id(browser.id)
            } else {
                ContentUnavailableView("Browser unavailable", systemImage: "exclamationmark.triangle")
            }
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
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(6)
            .accessibilityLabel("Terminal pane actions")
            .help("Terminal Pane Actions")
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
    let paneID: PaneID
    @ObservedObject var controller: BrowserSessionController
    @State private var addressState = BrowserAddressFieldState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                    controller.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!controller.state.canGoBack)
                .accessibilityLabel("Back")
                .help("Back")
                Button {
                    model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                    controller.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!controller.state.canGoForward)
                .accessibilityLabel("Forward")
                .help("Forward")

                HStack(spacing: 2) {
                    BrowserAddressTextField(
                        text: Binding(
                            get: { addressState.text },
                            set: { addressState.updateFromUser($0) }
                        ),
                        beginEditing: {
                            model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                            return addressState.beginEditing()
                        },
                        endEditing: {
                            addressState.endEditing(
                                navigationText: controller.state.url?.absoluteString
                            )
                        },
                        submit: { fieldText in
                            let submittedAddress = addressState.prepareSubmission(fieldText: fieldText)
                            model.loadBrowserAddress(
                                submittedAddress,
                                workspaceID: workspaceID,
                                tabID: tabID,
                                browserID: browserID
                            )
                        }
                    )
                    .frame(minHeight: 18)

                    Button {
                        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                        if controller.state.isLoading {
                            controller.stopLoading()
                        } else {
                            controller.reload()
                        }
                    } label: {
                        Image(systemName: controller.state.isLoading ? "stop.fill" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(width: 20, height: 18)
                    .accessibilityLabel(controller.state.isLoading ? "Stop loading" : "Reload")
                    .help(controller.state.isLoading ? "Stop Loading" : "Reload")
                }
                .padding(.leading, 6)
                .padding(.trailing, 3)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            addressState.isEditing ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: addressState.isEditing ? 2 : 1
                        )
                }

                Menu {
                    Button("Split Right") {
                        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                        model.splitFocusedTerminal(orientation: .horizontal)
                    }
                    Button("Split Below") {
                        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                        model.splitFocusedTerminal(orientation: .vertical)
                    }
                    Button("Close Pane") {
                        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                        model.closeFocusedPaneOrTab()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Browser pane actions")
                .help("Browser Pane Actions")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
                .simultaneousGesture(
                    TapGesture().onEnded {
                        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                    }
                )
        }
        .onAppear {
            addressState.synchronizeNavigationText(controller.state.url?.absoluteString ?? "")
        }
        .onChange(of: controller.state.url) { _, url in
            guard let url else { return }
            addressState.synchronizeNavigationText(url.absoluteString)
            model.persistBrowserURL(
                url,
                workspaceID: workspaceID,
                tabID: tabID,
                browserID: browserID
            )
        }
    }

}

private struct BrowserAddressTextField: NSViewRepresentable {
    @Binding var text: String
    let beginEditing: () -> Bool
    let endEditing: () -> Void
    let submit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            beginEditing: beginEditing,
            endEditing: endEditing,
            submit: submit
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.placeholderString = "Address"
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.toolTip = "Browser Address"
        textField.setAccessibilityLabel("Browser address")
        textField.setAccessibilityHelp("Enter a web or file address")
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.beginEditing = beginEditing
        context.coordinator.endEditing = endEditing
        context.coordinator.submit = submit
        if textField.currentEditor() == nil, textField.stringValue != text {
            textField.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var beginEditing: () -> Bool
        var endEditing: () -> Void
        var submit: (String) -> Void

        init(
            text: Binding<String>,
            beginEditing: @escaping () -> Bool,
            endEditing: @escaping () -> Void,
            submit: @escaping (String) -> Void
        ) {
            self.text = text
            self.beginEditing = beginEditing
            self.endEditing = endEditing
            self.submit = submit
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard beginEditing() else { return }
            (notification.object as? NSTextField)?.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            endEditing()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let fieldText = (control as? NSTextField)?.stringValue ?? textView.string
            text.wrappedValue = fieldText
            _ = control.window?.makeFirstResponder(nil)
            submit(fieldText)
            return true
        }
    }
}
