import Foundation
import Security
import XCTest
@testable import MyTermRemote

private final class MockKeychainOperations: KeychainOperations, @unchecked Sendable {
    var allowed = true
    var transitions: [Bool] = []
    var calls: [String] = []
    var queryPolicies: [String?] = []
    var interactionDuringOperation: [Bool] = []
    var status: OSStatus = errSecInteractionNotAllowed
    var updateStatus: OSStatus?
    var failApplying = false
    var failRestoring = false

    private func record(_ name: String, query: CFDictionary) -> OSStatus {
        calls.append(name)
        let values = query as NSDictionary
        queryPolicies.append(values[kSecUseAuthenticationUI] as? String)
        interactionDuringOperation.append(allowed)
        return status
    }
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        record("read", query: query)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let result = record("update", query: query)
        return updateStatus ?? result
    }
    func add(_ attributes: CFDictionary) -> OSStatus { record("add", query: attributes) }
    func delete(_ query: CFDictionary) -> OSStatus { record("delete", query: query) }
    #if os(macOS)
    func interactionAllowed() throws -> Bool { allowed }
    func setInteractionAllowed(_ value: Bool) throws {
        transitions.append(value)
        if !value && failApplying { throw KeychainError(status: errSecNotAvailable) }
        if value && failRestoring { throw KeychainError(status: errSecNotAvailable) }
        allowed = value
    }
    #endif
}

final class KeychainInteractionPolicyTests: XCTestCase {
    func testDefaultInteractivePolicyPreservesQueriesAndDoesNotChangeGlobalInteraction() {
        let operations = MockKeychainOperations()
        let store = KeychainSecretStore(service: "mock", operations: operations)
        XCTAssertThrowsError(try store.read(account: "test"))
        XCTAssertTrue(operations.transitions.isEmpty)
        XCTAssertEqual(operations.interactionDuringOperation, [true])
        XCTAssertNil(operations.queryPolicies.first!)
    }

    #if os(macOS)
    func testNoninteractivePolicyCoversReadUpdateDeleteAndRestoresAfterErrors() {
        let operations = MockKeychainOperations()
        let store = KeychainSecretStore(service: "mock", authenticationUI: .fail, operations: operations)
        XCTAssertThrowsError(try store.read(account: "test"))
        XCTAssertThrowsError(try store.write(Data("fixture".utf8), account: "test"))
        XCTAssertThrowsError(try store.delete(account: "test"))
        XCTAssertEqual(operations.calls, ["read", "update", "delete"])
        XCTAssertEqual(operations.interactionDuringOperation, [false, false, false])
        XCTAssertEqual(operations.queryPolicies.compactMap { $0 }, Array(repeating: kSecUseAuthenticationUIFail as String, count: 3))
        XCTAssertEqual(operations.transitions, [false, true, false, true, false, true])
        XCTAssertTrue(operations.allowed)
    }

    func testInsertFallbackRemainsInsideNoninteractiveScopeAndPreservesPreviouslyFalsePolicy() throws {
        let operations = MockKeychainOperations()
        operations.allowed = false
        operations.updateStatus = errSecItemNotFound
        operations.status = errSecSuccess
        let store = KeychainSecretStore(service: "mock", authenticationUI: .fail, operations: operations)
        try store.write(Data("fixture".utf8), account: "test")
        XCTAssertEqual(operations.calls, ["update", "add"])
        XCTAssertEqual(operations.interactionDuringOperation, [false, false])
        XCTAssertEqual(operations.queryPolicies.compactMap { $0 }, Array(repeating: kSecUseAuthenticationUIFail as String, count: 2))
        XCTAssertEqual(operations.transitions, [false, false])
        XCTAssertFalse(operations.allowed)
    }

    func testFailedPolicyApplicationNeverTouchesCredentialsAndAttemptsRestoration() {
        let operations = MockKeychainOperations()
        operations.failApplying = true
        let store = KeychainSecretStore(service: "mock", authenticationUI: .fail, operations: operations)
        XCTAssertThrowsError(try store.read(account: "test"))
        XCTAssertTrue(operations.calls.isEmpty)
        XCTAssertEqual(operations.transitions, [false, true])
        XCTAssertTrue(operations.allowed)
    }

    func testRestorationFailureIsSurfacedRatherThanHiddenByOperationError() {
        let operations = MockKeychainOperations()
        operations.failRestoring = true
        let store = KeychainSecretStore(service: "mock", authenticationUI: .fail, operations: operations)
        XCTAssertThrowsError(try store.read(account: "test")) { error in
            XCTAssertTrue(error is KeychainInteractionPolicyError)
            XCTAssertTrue(error.localizedDescription.contains("restore"))
        }
        XCTAssertEqual(operations.transitions, [false, true])
    }
    #endif
}
