import MyTermCore

@MainActor
public protocol BrowserSessionFactory {
    func makeSession(profile: BrowserDataProfile) -> BrowserSessionController
}

public struct WebKitBrowserSessionFactory: BrowserSessionFactory, Sendable {
    public init() {}

    public func makeSession(profile: BrowserDataProfile) -> BrowserSessionController {
        BrowserSessionController(profile: profile)
    }
}
