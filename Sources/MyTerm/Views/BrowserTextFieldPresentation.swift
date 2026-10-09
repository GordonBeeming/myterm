import AppKit
import MyTermUI
import SwiftUI

struct BrowserTextFieldPresentation: Equatable {
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHelp: String

    static let browserAddress = BrowserTextFieldPresentation(
        placeholder: "Address",
        accessibilityLabel: "Browser address",
        accessibilityHelp: "Enter a web or file address"
    )

    static let findInPage = BrowserTextFieldPresentation(
        placeholder: "Find",
        accessibilityLabel: "Find in page",
        accessibilityHelp: "Find text on this page"
    )
}

struct BrowserAddressFieldState {
    private(set) var text = ""
    private(set) var isEditing = false

    mutating func beginEditing() -> Bool {
        guard !isEditing else { return false }
        isEditing = true
        return true
    }

    mutating func updateFromUser(_ text: String) { self.text = text }

    mutating func synchronizeNavigationText(_ text: String) {
        guard !isEditing else { return }
        self.text = text
    }

    mutating func endEditing(navigationText: String?) {
        isEditing = false
        if let navigationText { text = navigationText }
    }

    mutating func prepareSubmission(fieldText: String) -> String {
        text = fieldText
        isEditing = false
        return fieldText
    }
}

struct BrowserAddressTextField: NSViewRepresentable {
    @Binding var text: String
    let beginEditing: () -> Bool
    let endEditing: () -> Void
    let submit: (String) -> Void
    let submitBackwards: (String) -> Void
    let focusToken: UInt64?
    let didFocus: (UInt64) -> Void
    let onEscape: () -> Void
    var presentation = BrowserTextFieldPresentation.browserAddress
    var moveSelection: ((Int) -> Void)? = nil
    var displayURL: URL? = nil

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
        let field = FocusAwareBrowserTextField(string: text)
        field.didBecomeFirstResponder = { [weak coordinator = context.coordinator] field in
            coordinator?.startEditing(field)
        }
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: "Geist Mono", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.textColor = NSColor(Theme.textStrong)
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
        context.coordinator.moveSelection = moveSelection
        if textField.currentEditor() == nil {
            if let url = displayURL {
                let host = (url.host ?? (url.isFileURL ? "file://" : url.absoluteString)) + (url.port.map { ":\($0)" } ?? "")
                let suffix = url.path + (url.query.map { "?\($0)" } ?? "") + (url.fragment.map { "#\($0)" } ?? "")
                let value = NSMutableAttributedString(string: host, attributes: [.foregroundColor: NSColor(Theme.textStrong)])
                value.append(NSAttributedString(string: suffix, attributes: [.foregroundColor: NSColor(Theme.textSecondary)]))
                value.addAttribute(.font, value: NSFont(name: "Geist", size: 13) ?? .systemFont(ofSize: 13), range: NSRange(location: 0, length: value.length))
                textField.attributedStringValue = value
            } else if textField.stringValue != text { textField.stringValue = text }
        }
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
        var moveSelection: ((Int) -> Void)?
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

        func startEditing(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView, beginEditing() else { return }
            editor.string = text.wrappedValue
            editor.font = NSFont(name: "Geist Mono", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            editor.textColor = NSColor(Theme.textStrong)
            editor.selectAll(nil)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            startEditing(field)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) { endEditing() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { submitBackwards(textView.string) } else { submit(textView.string) }
                return true
            }
            if let moveSelection {
                if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
                if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape(); return true }
            return false
        }
    }
}


private final class FocusAwareBrowserTextField: NSTextField {
    var didBecomeFirstResponder: ((NSTextField) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { didBecomeFirstResponder?(self) }
        return becameFirstResponder
    }
}
