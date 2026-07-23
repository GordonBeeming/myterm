import MyTermCore
import MyTermPlatform

struct BrowserAddressFocusRequest: Equatable, Sendable {
    let sessionID: BrowserSessionID
    let token: UInt64
}

struct BrowserFindRequest: Equatable, Sendable {
    let sessionID: BrowserSessionID
    let token: UInt64
}

@MainActor
extension AppModel {
    var hasSelectedBrowserTab: Bool {
        selectedBrowserController != nil
    }

    var decreaseZoomOrFontCommandTitle: String {
        hasSelectedBrowserTab ? "Zoom Out" : "Decrease Workspace Font Size"
    }

    var increaseZoomOrFontCommandTitle: String {
        hasSelectedBrowserTab ? "Zoom In" : "Increase Workspace Font Size"
    }

    func decreaseZoomOrFontSize() {
        hasSelectedBrowserTab ? zoomOutSelectedBrowser() : adjustSelectedWorkspaceFontSize(by: -1)
    }

    func increaseZoomOrFontSize() {
        hasSelectedBrowserTab ? zoomInSelectedBrowser() : adjustSelectedWorkspaceFontSize(by: 1)
    }

    var canSelectedBrowserGoBack: Bool { selectedBrowserController?.state.canGoBack == true }
    var canSelectedBrowserGoForward: Bool { selectedBrowserController?.state.canGoForward == true }
    var canStopSelectedBrowser: Bool { selectedBrowserController?.state.isLoading == true }

    func goBackInSelectedBrowser() { selectedBrowserController?.goBack() }
    func goForwardInSelectedBrowser() { selectedBrowserController?.goForward() }
    func reloadSelectedBrowser() { selectedBrowserController?.reload() }
    func reloadSelectedBrowserFromOrigin() { selectedBrowserController?.reloadFromOrigin() }

    func stopSelectedBrowser() {
        guard canStopSelectedBrowser else { return }
        selectedBrowserController?.stopLoading()
    }

    func requestSelectedBrowserAddressFocus() {
        guard let browserID = selectedTab?.browserSession?.id,
              browserControllers[browserID] != nil else { return }
        nextBrowserAddressFocusToken &+= 1
        browserAddressFocusRequest = BrowserAddressFocusRequest(
            sessionID: browserID,
            token: nextBrowserAddressFocusToken
        )
    }

    func acknowledgeBrowserAddressFocus(sessionID: BrowserSessionID, token: UInt64) {
        guard browserAddressFocusRequest == BrowserAddressFocusRequest(
            sessionID: sessionID,
            token: token
        ) else { return }
        browserAddressFocusRequest = nil
    }

    func requestSelectedBrowserFind() {
        guard let browserID = selectedTab?.browserSession?.id,
              browserControllers[browserID] != nil else { return }
        nextBrowserFindToken &+= 1
        browserFindRequest = BrowserFindRequest(sessionID: browserID, token: nextBrowserFindToken)
    }

    func acknowledgeBrowserFind(sessionID: BrowserSessionID, token: UInt64) {
        guard browserFindRequest == BrowserFindRequest(sessionID: sessionID, token: token) else { return }
        browserFindRequest = nil
    }

    func findInSelectedBrowser(_ query: String, backwards: Bool = false) {
        selectedBrowserController?.find(query, backwards: backwards)
    }

    func zoomInSelectedBrowser() { selectedBrowserController?.zoomIn() }
    func zoomOutSelectedBrowser() { selectedBrowserController?.zoomOut() }
    func resetSelectedBrowserZoom() { selectedBrowserController?.resetZoom() }

    private var selectedBrowserController: BrowserSessionController? {
        guard let browserID = selectedWorkspace.focusedTabGroup?.selectedTab.browserSession?.id else {
            return nil
        }
        return browserControllers[browserID]
    }
}
