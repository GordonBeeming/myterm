import Foundation
import MyTermCore
import XCTest

final class SystemPermissionTests: XCTestCase {
    func testEveryPermissionDescribesItselfAndLinksToSystemSettings() {
        for permission in SystemPermission.allCases {
            XCTAssertFalse(permission.title.isEmpty, "\(permission) has no title")
            XCTAssertFalse(permission.detail.isEmpty, "\(permission) has no detail")
            XCTAssertTrue(permission.systemSettingsAnchor.hasPrefix("Privacy_"), "\(permission) anchor")
            XCTAssertNotNil(permission.systemSettingsURL, "\(permission) settings URL")
        }
    }

    func testEveryPermissionBelongsToExactlyOneGroup() {
        let grouped = SystemPermission.Group.allCases.flatMap(\.permissions)
        XCTAssertEqual(grouped.count, SystemPermission.allCases.count)
        XCTAssertEqual(Set(grouped), Set(SystemPermission.allCases))
    }

    // Without the usage string macOS can't prompt, and without the entitlement a hardened-runtime
    // build is denied without a prompt, so a permission missing either never works in a release.
    func testPackagingDeclaresEveryUsageStringAndEntitlement() throws {
        let infoPlist = try plist(at: "Packaging/Info.plist")
        let entitlements = try plist(at: "Packaging/MyTerm.entitlements")

        for permission in SystemPermission.allCases {
            for key in permission.requiredInfoPlistKeys {
                let value = infoPlist[key] as? String
                XCTAssertFalse(value?.isEmpty ?? true, "Info.plist is missing \(key) for \(permission)")
            }
            for key in permission.requiredEntitlements {
                XCTAssertEqual(entitlements[key] as? Bool, true, "Entitlements are missing \(key) for \(permission)")
            }
        }
    }

    func testPromptPermissionsOfferGrantOnlyBeforeMacOSHasAnswered() {
        let microphone = SystemPermission.microphone
        XCTAssertEqual(microphone.requestButtonTitle(for: .notDetermined), "Grant")
        XCTAssertEqual(microphone.requestButtonTitle(for: .notGranted), "Grant")
        XCTAssertNil(microphone.requestButtonTitle(for: .granted))
        XCTAssertNil(microphone.requestButtonTitle(for: .denied))
    }

    func testProbePermissionsCanBeCheckedAgainAfterADenial() {
        let downloads = SystemPermission.downloadsFolder
        XCTAssertEqual(downloads.requestButtonTitle(for: .unknown), "Grant")
        XCTAssertEqual(downloads.requestButtonTitle(for: .denied), "Check Again")
        XCTAssertNil(downloads.requestButtonTitle(for: .granted))
    }

    func testSettingsOnlyAndInformationalPermissionsNeverOfferARequest() {
        XCTAssertNil(SystemPermission.fullDiskAccess.requestButtonTitle(for: .notGranted))
        XCTAssertNil(SystemPermission.removableVolumes.requestButtonTitle(for: .informational))
    }

    private func plist(at relativePath: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any], "\(relativePath) is not a dictionary")
    }
}
