import AppKit
import AuthenticationServices
import Foundation
import OSLog
import MyTermRemote

@MainActor
final class CompanionAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let externalAuthentication: CompanionExternalBrowserAuthentication

    init(externalAuthentication: CompanionExternalBrowserAuthentication = .shared) {
        self.externalAuthentication = externalAuthentication
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String,
                      attempt: SignInAttempt) async throws -> URL {
        guard session == nil else { throw CompanionAuthenticationError.alreadyRunning }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
                Task { @MainActor in
                    self?.session = nil
                    if let error {
                        let diagnostic = error as NSError
                        Logger(subsystem: "com.gordonbeeming.myterm", category: "companion-auth").error("Browser completion error domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code) callbackPresent=\(callback != nil)")
                        continuation.resume(throwing: error)
                    } else if let callback {
                        continuation.resume(returning: callback)
                    } else {
                        continuation.resume(throwing: CompanionAuthenticationError.missingCallback)
                    }
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(
                    url: url, callback: .customScheme(callbackScheme), completionHandler: completion
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme, completionHandler: completion
                )
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: CompanionAuthenticationError.couldNotStart)
                return
            }
        }
        guard Self.requiresExternalFallback(callback: callback, initialURL: url) else {
            return callback
        }
        Logger(subsystem: "com.gordonbeeming.myterm", category: "companion-auth")
            .notice("AuthenticationServices returned the initial request; using bounded external-browser fallback.")
        return try await externalAuthentication.authenticate(url: url, attempt: attempt)
    }

    static func requiresExternalFallback(callback: URL, initialURL: URL) -> Bool {
        callback == initialURL && callback.scheme?.lowercased() == "https"
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

private enum CompanionAuthenticationError: LocalizedError {
    case alreadyRunning, missingCallback, couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A sign-in window is already open. Complete or cancel it before trying again."
        case .missingCallback: "The browser closed without completing sign-in. Start a new sign-in attempt."
        case .couldNotStart: "macOS could not open the sign-in session. Quit and reopen MyTerm, then try again."
        }
    }
}
