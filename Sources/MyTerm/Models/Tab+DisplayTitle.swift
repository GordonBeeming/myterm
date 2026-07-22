import MyTermCore

extension Tab {
    var automaticDisplayTitle: String {
        guard let browser = focusedBrowserSession else { return "Terminal" }
        return browser.url.host ?? "Browser"
    }
}
