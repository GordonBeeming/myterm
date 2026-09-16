import AppKit
import AuthenticationServices
import Foundation
import OSLog
import MyTermRemote

@MainActor
protocol CompanionBrowserSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: CompanionBrowserSession {}

@MainActor
final class CompanionAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias SessionFactory = @MainActor (URL, String, @escaping ASWebAuthenticationSession.CompletionHandler) -> any CompanionBrowserSession
    private var session: (any CompanionBrowserSession)?
    private var pending: (id: UUID, continuation: CheckedContinuation<URL, Error>)?
    private let makeSession: SessionFactory
    private let externalAuthentication: CompanionExternalBrowserAuthentication

    init(externalAuthentication: CompanionExternalBrowserAuthentication = .shared,
         makeSession: @escaping SessionFactory = CompanionAuthenticationSession.makeSystemSession) {
        self.makeSession = makeSession
        self.externalAuthentication = externalAuthentication
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String,
                      attempt: SignInAttempt) async throws -> URL {
        guard session == nil else { throw CompanionAuthenticationError.alreadyRunning }
        let id = UUID()
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = (id, continuation)
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.pending?.id == id else { return }
                        if let error {
                            let diagnostic = error as NSError
                            Logger(subsystem: "com.gordonbeeming.myterm", category: "companion-auth").error("Browser completion error domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code) callbackPresent=\(callback != nil)")
                            self.finish(id: id, result: .failure(error))
                        } else if let callback {
                            self.finish(id: id, result: .success(callback))
                        } else {
                            self.finish(id: id, result: .failure(CompanionAuthenticationError.missingCallback))
                        }
                    }
                }
                let session = makeSession(url, callbackScheme, completion)
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    finish(id: id, result: .failure(CompanionAuthenticationError.couldNotStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        try Task.checkCancellation()
        guard Self.requiresExternalFallback(callback: callback, initialURL: url) else {
            return callback
        }
        Logger(subsystem: "com.gordonbeeming.myterm", category: "companion-auth")
            .notice("AuthenticationServices returned the initial request; using bounded external-browser fallback.")
        return try await externalAuthentication.authenticate(url: url, attempt: attempt)
    }

    func cancel() {
        if let id = pending?.id { cancel(id: id) }
        externalAuthentication.cancel()
    }

    private func cancel(id: UUID) {
        guard pending?.id == id else { return }
        let active = session
        finish(id: id, result: .failure(CancellationError()))
        active?.cancel()
    }

    private func finish(id: UUID, result: Result<URL, Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        session = nil
        pending.continuation.resume(with: result)
    }

    private static func makeSystemSession(url: URL, scheme: String,
                                          completion: @escaping ASWebAuthenticationSession.CompletionHandler) -> any CompanionBrowserSession {
        if #available(macOS 14.4, *) {
            return ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: completion)
        }
        return ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
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
