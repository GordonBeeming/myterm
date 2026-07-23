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
