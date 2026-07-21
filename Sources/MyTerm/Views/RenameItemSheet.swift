import AppKit
import SwiftUI

struct RenameItemSheet: View {
    let title: String
    let fieldLabel: String
    @Binding var text: String
    var allowsEmpty = false
    var message: String?
    let cancel: () -> Void
    let commit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            AutoSelectingTextField(
                label: fieldLabel,
                text: $text,
                submit: commitAndDismiss,
                cancel: cancelAndDismiss
            )
            .frame(height: 22)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancelAndDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commitAndDismiss)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowsEmpty && trimmedText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelAndDismiss() {
        cancel()
        dismiss()
    }

    private func commitAndDismiss() {
        guard allowsEmpty || !trimmedText.isEmpty else { return }
        commit()
        dismiss()
    }
}

private struct AutoSelectingTextField: NSViewRepresentable {
    let label: String
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, submit: submit, cancel: cancel)
    }

    func makeNSView(context: Context) -> SelectingTextField {
        let textField = SelectingTextField(string: text)
        textField.delegate = context.coordinator
        textField.setAccessibilityLabel(label)
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        return textField
    }

    func updateNSView(_ textField: SelectingTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.submit = submit
        context.coordinator.cancel = cancel
        if textField.currentEditor() == nil, textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var submit: () -> Void
        var cancel: () -> Void

        init(text: Binding<String>, submit: @escaping () -> Void, cancel: @escaping () -> Void) {
            self.text = text
            self.submit = submit
            self.cancel = cancel
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
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class SelectingTextField: NSTextField {
    private var didSelectInitialText = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didSelectInitialText else { return }
        didSelectInitialText = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
            selectText(nil)
        }
    }
}
