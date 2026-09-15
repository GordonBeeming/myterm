import Foundation
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class CompanionExternalBrowserAuthenticationTests: XCTestCase {
    func testFallbackTriggerRequiresExactInitialHTTPSURL() throws {
        let initial = try XCTUnwrap(URL(string: "https://relay.example.test/auth/login?state=one"))
        XCTAssertTrue(CompanionAuthenticationSession.requiresExternalFallback(
            callback: initial, initialURL: initial
        ))
        XCTAssertFalse(CompanionAuthenticationSession.requiresExternalFallback(
            callback: try XCTUnwrap(URL(string: "https://relay.example.test/auth/login?state=two")),
            initialURL: initial
        ))
        XCTAssertFalse(CompanionAuthenticationSession.requiresExternalFallback(
            callback: try XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback")),
            initialURL: initial
        ))
    }

    func testExactCallbackCompletesAndUnrelatedURLRemainsForNormalRouting() async throws {
        var openedURL: URL?
        let coordinator = CompanionExternalBrowserAuthentication(timeout: .seconds(2)) {
            openedURL = $0
        }
        let attempt = try makeAttempt()
        let initial = try attempt.loginURL(deviceName: "Mac", deviceKind: "host")
        let result = Task { try await coordinator.authenticate(url: initial, attempt: attempt) }
        await waitUntil { openedURL != nil }
        let unrelated = try XCTUnwrap(URL(string: "https://example.test/docs"))
        XCTAssertEqual(coordinator.consumeAuthenticationCallbacks(from: [unrelated]), [unrelated])
        let callback = try callback(for: attempt, code: "proof")

        XCTAssertTrue(coordinator.consumeAuthenticationCallbacks(from: [callback]).isEmpty)
        let returned = try await result.value
        XCTAssertEqual(returned, callback)
        XCTAssertEqual(openedURL, initial)
    }

    func testWrongStateAndOrphanCallbacksAreSwallowedWithoutCompletingNewAttempt() async throws {
        let coordinator = CompanionExternalBrowserAuthentication(timeout: .seconds(2)) { _ in }
        let first = try makeAttempt()
        let firstInitial = try first.loginURL(deviceName: "Mac", deviceKind: "host")
        let firstTask = Task { try await coordinator.authenticate(url: firstInitial, attempt: first) }
        await Task.yield()
        firstTask.cancel()
        await XCTAssertThrowsErrorAsync(try await firstTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let second = try makeAttempt()
        let secondInitial = try second.loginURL(deviceName: "Mac", deviceKind: "host")
        let secondTask = Task { try await coordinator.authenticate(url: secondInitial, attempt: second) }
        await Task.yield()
        XCTAssertTrue(coordinator.consumeAuthenticationCallbacks(
            from: [try callback(for: first, code: "stale")]
        ).isEmpty)
        let valid = try callback(for: second, code: "fresh")
        XCTAssertTrue(coordinator.consumeAuthenticationCallbacks(from: [valid]).isEmpty)
        let returned = try await secondTask.value
        XCTAssertEqual(returned, valid)

        XCTAssertTrue(coordinator.consumeAuthenticationCallbacks(from: [valid]).isEmpty,
                      "Authentication callbacks stay out of generic URL routing after completion")
    }

    func testMatchingStateWithMalformedResponseFailsStrictValidation() async throws {
        let coordinator = CompanionExternalBrowserAuthentication(timeout: .seconds(2)) { _ in }
        let attempt = try makeAttempt()
        let initial = try attempt.loginURL(deviceName: "Mac", deviceKind: "host")
        let task = Task { try await coordinator.authenticate(url: initial, attempt: attempt) }
        await Task.yield()
        let malformed = try XCTUnwrap(URL(
            string: "myterm-dev://companion-auth/callback?state=\(attempt.state)&code=one&code=two"
        ))

        XCTAssertTrue(coordinator.consumeAuthenticationCallbacks(from: [malformed]).isEmpty)
        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? RemoteError, .invalidCallback)
        }
    }

    func testTimeoutIsBounded() async throws {
        let coordinator = CompanionExternalBrowserAuthentication(timeout: .milliseconds(10)) { _ in }
        let attempt = try makeAttempt()
        let initial = try attempt.loginURL(deviceName: "Mac", deviceKind: "host")

        await XCTAssertThrowsErrorAsync(
            try await coordinator.authenticate(url: initial, attempt: attempt)
        ) { error in
            XCTAssertEqual(error as? CompanionExternalBrowserAuthenticationError, .timedOut)
        }
    }

    func testURLDispatcherSwallowsOrphanAuthenticationCallbacksBeforeBrowserRouting() throws {
        let dispatcher = MyTermURLDispatcher()
        let handler = RecordingURLHandler()
        dispatcher.connect(handler: handler)
        let orphan = try XCTUnwrap(URL(
            string: "myterm-dev://companion-auth/callback?state=orphan&code=orphan"
        ))
        let web = try XCTUnwrap(URL(string: "https://example.test/docs"))

        dispatcher.dispatch([orphan, web])

        XCTAssertEqual(handler.received, [web])
    }

    private func makeAttempt() throws -> SignInAttempt {
        try SignInAttempt(
            relay: RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.test"))),
            redirectURI: XCTUnwrap(URL(string: "myterm-dev://companion-auth/callback"))
        )
    }

    private func callback(for attempt: SignInAttempt, code: String) throws -> URL {
        try XCTUnwrap(URL(
            string: "myterm-dev://companion-auth/callback?state=\(attempt.state)&code=\(code)"
        ))
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
    }
}

@MainActor
private final class RecordingURLHandler: MyTermURLHandling {
    private(set) var received: [URL] = []
    func open(_ urls: [URL]) { received.append(contentsOf: urls) }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        handler(error)
    }
}
