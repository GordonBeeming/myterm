import Foundation

public extension Tab {
    /// The title a tab shows when the user has not named it.
    ///
    /// This lives in MyTermCore because the Mac window and the wire projection must agree. A device
    /// showing a different title from the pane it mirrors is a bug the user cannot explain.
    var automaticDisplayTitle: String {
        // The agent conversation is what a pane running one is about, so its name outranks the
        // generic label. A title the user typed still wins over both.
        if let agentTitle = terminalSession?.agentTitle { return agentTitle }
        guard let browser = focusedBrowserSession else { return "Terminal" }
        return browser.url.host ?? "Browser"
    }

    /// What to show for this tab, preferring a name the user chose.
    var displayTitle: String {
        customTitle ?? automaticDisplayTitle
    }
}
