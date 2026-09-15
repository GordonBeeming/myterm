import AppKit
import Foundation
import MyTermRemote

enum CompanionExternalBrowserAuthenticationError: String, Error, LocalizedError, Sendable {
    case alreadyRunning = "already_running"
    case noExternalBrowser = "no_external_browser"
    case couldNotOpen = "could_not_open"
    case timedOut = "timed_out"

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A browser sign-in is already open. Complete or cancel it before trying again."
        case .noExternalBrowser:
            "Choose Safari or another external default browser, then try signing in again."
        case .couldNotOpen:
            "MyTerm could not open the relay sign-in page in your browser."
        case .timedOut:
            "The browser sign-in expired. Start a new sign-in attempt."
        }
    }
}

@MainActor
final class CompanionExternalBrowserAuthentication {
    typealias Opener = @MainActor @Sendable (URL) throws -> Void

    static let shared = CompanionExternalBrowserAuthentication()
    private static let allowedSchemes = Set(["myterm", "myterm-dev"])
    private static let defaultTimeout: Duration = .seconds(300)

    private struct Pending {
        let id: UUID
        let attempt: SignInAttempt
        let continuation: CheckedContinuation<URL, Error>
        var timeoutTask: Task<Void, Never>?
        var openerTask: Task<Void, Never>?
    }

    private let opener: Opener
    private let timeout: Duration
    private var pending: Pending?

    init(timeout: Duration = CompanionExternalBrowserAuthentication.defaultTimeout,
         opener: @escaping Opener = CompanionExternalBrowserAuthentication.openExternally) {
        self.timeout = timeout
        self.opener = opener
    }

    func authenticate(url: URL, attempt: SignInAttempt) async throws -> URL {
        guard pending == nil else {
            throw CompanionExternalBrowserAuthenticationError.alreadyRunning
        }
        guard url.scheme?.lowercased() == "https" else {
            throw CompanionExternalBrowserAuthenticationError.couldNotOpen
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = Pending(id: id, attempt: attempt,
                                  continuation: continuation, timeoutTask: nil,
                                  openerTask: nil)
                let timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: self?.timeout ?? .zero) }
                    catch { return }
                    self?.finish(id: id, result: .failure(
                        CompanionExternalBrowserAuthenticationError.timedOut
                    ))
                }
                pending?.timeoutTask = timeoutTask
                let openerTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled, self.pending?.id == id else { return }
                    do { try self.opener(url) }
                    catch is CancellationError {
                        self.finish(id: id, result: .failure(CancellationError()))
                    }
                    catch {
                        self.finish(id: id, result: .failure(
                            error as? CompanionExternalBrowserAuthenticationError
                                ?? CompanionExternalBrowserAuthenticationError.couldNotOpen
                        ))
                    }
                }
                pending?.openerTask = openerTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func consumeAuthenticationCallbacks(from urls: [URL]) -> [URL] {
        urls.filter { !consumeAuthenticationCallback($0) }
    }

    @discardableResult
    func consumeAuthenticationCallback(_ url: URL) -> Bool {
        guard Self.isAuthenticationCallback(url) else { return false }
        guard let pending else { return true }
        guard Self.matchesDestination(url, expected: pending.attempt.redirectURI),
              Self.hasMatchingState(url, expected: pending.attempt.state) else {
            return true
        }
        if pending.attempt.callbackValidationFailure(from: url) == nil {
            finish(id: pending.id, result: .success(url))
        } else {
            finish(id: pending.id, result: .failure(RemoteError.invalidCallback))
        }
        return true
    }

    func cancel() {
        guard let id = pending?.id else { return }
        cancel(id: id)
    }

    private func cancel(id: UUID) {
        finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: UUID, result: Result<URL, Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timeoutTask?.cancel()
        pending.openerTask?.cancel()
        pending.continuation.resume(with: result)
    }

    private static func isAuthenticationCallback(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return allowedSchemes.contains(parts.scheme?.lowercased() ?? "")
            && parts.host?.lowercased() == "companion-auth"
            && parts.path == "/callback"
            && parts.user == nil && parts.password == nil && parts.port == nil
    }

    private static func matchesDestination(_ url: URL, expected: URL) -> Bool {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expected, resolvingAgainstBaseURL: false) else {
            return false
        }
        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && actual.path == expected.path
            && actual.user == nil && actual.password == nil && actual.port == nil
    }

    private static func hasMatchingState(_ url: URL, expected: String) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        let states = items.filter { $0.name == "state" }
        return states.count == 1 && states[0].value == expected
    }

    private static func openExternally(_ url: URL) throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              applicationURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else {
            throw CompanionExternalBrowserAuthenticationError.noExternalBrowser
        }
        let configuration = NSWorkspace.OpenConfiguration()
        try Task.checkCancellation()
        NSWorkspace.shared.open(
            [url], withApplicationAt: applicationURL,
            configuration: configuration, completionHandler: nil
        )
    }
}
