import MyTermCore

@MainActor
public protocol BrowserSessionFactory {
    func makeSession(profile: BrowserDataProfile) -> BrowserSessionController
}

public struct WebKitBrowserSessionFactory: BrowserSessionFactory, Sendable {
    /// Chords every session this factory builds will refuse to hand to web content. The app supplies its
    /// own command table here; the empty default keeps the plain-WebKit behaviour for callers that don't
    /// care (tests, previews).
    private let reservedChords: [KeyChord]

    public init(reservedChords: [KeyChord] = []) {
        self.reservedChords = reservedChords
    }

    public func makeSession(profile: BrowserDataProfile) -> BrowserSessionController {
        BrowserSessionController(profile: profile, reservedChords: reservedChords)
    }
}
