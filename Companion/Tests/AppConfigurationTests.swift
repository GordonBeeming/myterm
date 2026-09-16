import Foundation
import XCTest
@testable import MyTermCompanion

final class AppConfigurationTests: XCTestCase {
    func testBuiltAppIdentityMatchesRuntimeStorageAndURLScheme() throws {
        #if DEBUG
        let expectedID = "com.gordonbeeming.myterm.companion.dev"
        let expectedScheme = "myterm-companion-dev"
        #else
        let expectedID = "com.gordonbeeming.myterm.companion"
        let expectedScheme = "myterm-companion"
        #endif
        XCTAssertEqual(Bundle.main.bundleIdentifier, expectedID)
        XCTAssertEqual(AppConfiguration.bundleIdentifier, expectedID)
        XCTAssertEqual(AppConfiguration.urlScheme, expectedScheme)
        let group = try XCTUnwrap(AppConfiguration.sharedKeychainGroup)
        XCTAssertTrue(group.hasSuffix(expectedID + ".shared"))
        XCTAssertFalse(group.contains("$("))
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [expectedScheme])
    }
}
