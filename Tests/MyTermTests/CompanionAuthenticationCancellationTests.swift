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
        let auth = CompanionAuthenticationSession(prepareCallback: { _ in }) { _, _, completion in
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
        let auth = CompanionAuthenticationSession(externalAuthentication: external, prepareCallback: { _ in }) { url, _, completion in
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
        let auth = CompanionAuthenticationSession(prepareCallback: { _ in }) { _, _, completion in
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

    func testCallbackRoutingIsPreparedBeforeTheBrowserStarts() async throws {
        var events: [String] = []
        let (attempt, login, callback) = try signInInputs()
        let auth = CompanionAuthenticationSession(prepareCallback: { scheme in
            events.append("register:\(scheme)")
        }) { _, _, completion in
            events.append("browser")
            completion(callback, nil)
            return BrowserSession(completion: completion)
        }
        let result = try await auth.authenticate(url: login, callbackScheme: "myterm-dev", attempt: attempt)
        XCTAssertEqual(result, callback)
        XCTAssertEqual(events, ["register:myterm-dev", "browser"])
    }

    func testRoutingFailureDoesNotOpenTheBrowser() async throws {
        var browserCreated = false
        let (attempt, login, _) = try signInInputs()
        let auth = CompanionAuthenticationSession(prepareCallback: { _ in
            throw URLError(.cannotFindHost)
        }) { _, _, completion in
            browserCreated = true
            return BrowserSession(completion: completion)
        }
        do {
            _ = try await auth.authenticate(url: login, callbackScheme: "myterm-dev", attempt: attempt)
            XCTFail("Routing failure must stop authentication")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotFindHost) }
        XCTAssertFalse(browserCreated)
    }

    func testCancelDuringRegistrationCannotOpenALateBrowserOrCancelARetry() async throws {
        let preparing = expectation(description: "preparing callback")
        var release: CheckedContinuation<Void, Never>?
        var preparations = 0
        var browsersCreated = 0
        let (attempt, login, callback) = try signInInputs()
        let auth = CompanionAuthenticationSession(prepareCallback: { _ in
            preparations += 1
            if preparations == 1 {
                await withCheckedContinuation { release = $0; preparing.fulfill() }
            }
        }) { _, _, completion in
            browsersCreated += 1
            completion(callback, nil)
            return BrowserSession(completion: completion)
        }
        let first = Task { try await auth.authenticate(url: login, callbackScheme: "myterm-dev", attempt: attempt) }
        await fulfillment(of: [preparing], timeout: 1)
        auth.cancel()
        let second = try await auth.authenticate(url: login, callbackScheme: "myterm-dev", attempt: attempt)
        release?.resume()
        do { _ = try await first.value; XCTFail("Cancelled registration started a browser") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(second, callback)
        XCTAssertEqual(browsersCreated, 1)
    }

    private func signInInputs() throws -> (SignInAttempt, URL, URL) {
        let endpoint = try RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.test")))
        let callback = try XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback"))
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: callback)
        return (attempt, try attempt.loginURL(deviceName: "Demo", deviceKind: "host"), callback)
    }
}
