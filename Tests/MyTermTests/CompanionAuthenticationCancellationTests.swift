import AuthenticationServices
import Foundation
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class CompanionAuthenticationCancellationTests: XCTestCase {
    private final class BrowserSession: CompanionBrowserSession {
        weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
        var prefersEphemeralWebBrowserSession = false
        var cancelled = false
        var canStart = true
        let completion: ASWebAuthenticationSession.CompletionHandler
        init(completion: @escaping ASWebAuthenticationSession.CompletionHandler) {
            self.completion = completion
        }
        func start() -> Bool { canStart }
        func cancel() { cancelled = true }
    }

    func testCancelUnblocksBrowserAndIgnoresLateCallbackAfterRetry() async throws {
        var browsers: [BrowserSession] = []
        let firstStarted = expectation(description: "first browser started")
        let secondStarted = expectation(description: "second browser started")
        let auth = CompanionAuthenticationSession { _, _, completion in
            let browser = BrowserSession(completion: completion)
            browsers.append(browser)
            if browsers.count == 1 { firstStarted.fulfill() }
            else { secondStarted.fulfill() }
            return browser
        }
        let endpoint = try RelayEndpoint(try XCTUnwrap(URL(string: "https://relay.example.test")))
        let callback = try XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback"))
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: callback)
        let url = try attempt.loginURL(deviceName: "Demo", deviceKind: "host")
        let first = Task { try await auth.authenticate(url: url, callbackScheme: "myterm-dev", attempt: attempt) }
        await fulfillment(of: [firstStarted], timeout: 1)
        auth.cancel()
        do { _ = try await first.value; XCTFail("Cancelled authentication completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(browsers[0].cancelled)

        let second = Task { try await auth.authenticate(url: url, callbackScheme: "myterm-dev", attempt: attempt) }
        await fulfillment(of: [secondStarted], timeout: 1)
        browsers[0].completion(URL(string: "myterm-dev://companion-auth/callback?code=stale"), nil)
        browsers[1].completion(callback, nil)
        let result = try await second.value
        XCTAssertEqual(result, callback)
        XCTAssertFalse(browsers[1].cancelled)
    }

    func testTaskCancellationAlsoUnblocksExternalBrowserFallback() async throws {
        let opened = expectation(description: "external fallback opened")
        let external = CompanionExternalBrowserAuthentication(timeout: .seconds(30)) { _ in
            opened.fulfill()
        }
        let auth = CompanionAuthenticationSession(externalAuthentication: external) { url, _, completion in
            let browser = BrowserSession(completion: completion)
            completion(url, nil)
            return browser
        }
        let endpoint = try RelayEndpoint(try XCTUnwrap(URL(string: "https://relay.example.test")))
        let callback = try XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback"))
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: callback)
        let url = try attempt.loginURL(deviceName: "Demo", deviceKind: "host")
        let task = Task { try await auth.authenticate(url: url, callbackScheme: "myterm-dev", attempt: attempt) }
        await fulfillment(of: [opened], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled fallback completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTaskCancellationClosesBrowserWithoutWaitingForItsCallback() async throws {
        let started = expectation(description: "browser started")
        var browser: BrowserSession?
        let auth = CompanionAuthenticationSession { _, _, completion in
            let value = BrowserSession(completion: completion)
            browser = value
            started.fulfill()
            return value
        }
        let endpoint = try RelayEndpoint(try XCTUnwrap(URL(string: "https://relay.example.test")))
        let callback = try XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback"))
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: callback)
        let url = try attempt.loginURL(deviceName: "Demo", deviceKind: "host")
        let task = Task { try await auth.authenticate(url: url, callbackScheme: "myterm-dev", attempt: attempt) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled authentication completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(browser?.cancelled == true)
    }
}
