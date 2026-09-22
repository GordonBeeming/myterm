import MyTermCore
@testable import MyTermPlatform
import XCTest

@MainActor
final class SystemPermissionControllerTests: XCTestCase {
    func testRefreshOnlyReadsStatusAndNeverRequests() async {
        let provider = FakePermissionProvider()
        let controller = SystemPermissionController(provider: provider)

        await controller.refresh()

        XCTAssertTrue(provider.requested.isEmpty)
        XCTAssertFalse(provider.checked.contains(.removableVolumes), "informational rows have nothing to read")
        XCTAssertEqual(controller.status(of: .microphone), .notDetermined)
        XCTAssertEqual(controller.status(of: .removableVolumes), .informational)
    }

    func testRequestStoresTheAnswerMacOSGave() async {
        let provider = FakePermissionProvider()
        provider.requestResults[.microphone] = .granted
        let controller = SystemPermissionController(provider: provider)
        await controller.refresh()

        await controller.request(.microphone)

        XCTAssertEqual(provider.requested, [.microphone])
        XCTAssertEqual(controller.status(of: .microphone), .granted)
        XCTAssertTrue(controller.pending.isEmpty)
    }

    func testProbeResultSurvivesARefreshThatCannotReadIt() async {
        let provider = FakePermissionProvider()
        provider.currentStatuses[.downloadsFolder] = .unknown
        provider.requestResults[.downloadsFolder] = .denied
        let controller = SystemPermissionController(provider: provider)

        await controller.request(.downloadsFolder)
        await controller.refresh()

        XCTAssertEqual(controller.status(of: .downloadsFolder), .denied)
    }

    func testRequestIsIgnoredOnceMacOSHasAnswered() async {
        let provider = FakePermissionProvider()
        provider.currentStatuses[.camera] = .denied
        let controller = SystemPermissionController(provider: provider)
        await controller.refresh()

        await controller.request(.camera)

        XCTAssertTrue(provider.requested.isEmpty, "macOS won't prompt twice, so asking again does nothing")
    }
}

@MainActor
private final class FakePermissionProvider: SystemPermissionProviding {
    var currentStatuses: [SystemPermission: SystemPermissionStatus] = [:]
    var requestResults: [SystemPermission: SystemPermissionStatus] = [:]
    private(set) var checked: [SystemPermission] = []
    private(set) var requested: [SystemPermission] = []

    func currentStatus(of permission: SystemPermission) async -> SystemPermissionStatus {
        checked.append(permission)
        return currentStatuses[permission] ?? .notDetermined
    }

    func request(_ permission: SystemPermission) async -> SystemPermissionStatus {
        requested.append(permission)
        return requestResults[permission] ?? .notDetermined
    }

    func openSystemSettings(for permission: SystemPermission) {}
}
