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

    func testGrantedProbeCanBeRecheckedAfterRevocation() async {
        let provider = FakePermissionProvider()
        provider.currentStatuses[.downloadsFolder] = .unknown
        provider.requestResults[.downloadsFolder] = .granted
        let controller = SystemPermissionController(provider: provider)
        await controller.request(.downloadsFolder)

        provider.requestResults[.downloadsFolder] = .denied
        await controller.refresh()
        await controller.request(.downloadsFolder)

        XCTAssertEqual(provider.requested, [.downloadsFolder, .downloadsFolder])
        XCTAssertEqual(controller.status(of: .downloadsFolder), .denied)
    }

    func testRefreshThatReadBeforeARequestDoesNotOverwriteItsAnswer() async {
        let provider = FakePermissionProvider()
        provider.requestResults[.microphone] = .granted
        let controller = SystemPermissionController(provider: provider)
        await controller.refresh()

        provider.holdStatusRead(of: .microphone)
        let staleRefresh = Task { await controller.refresh() }
        while !provider.isHoldingStatusRead { await Task.yield() }

        await controller.request(.microphone)
        provider.releaseStatusRead(returning: .notDetermined)
        await staleRefresh.value

        XCTAssertEqual(controller.status(of: .microphone), .granted)
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

final class LocalNetworkProbeEventTests: XCTestCase {
    func testReadyAfterPolicyDeniedMeansTheUserAllowedIt() {
        XCTAssertEqual(LocalNetworkProbeEvent.outcome(of: .ready, sawPolicyDenied: true), .granted)
        XCTAssertEqual(LocalNetworkProbeEvent.outcome(of: .resultsChanged, sawPolicyDenied: true), .granted)
    }

    func testPolicyDeniedAloneKeepsWaitingForTheUser() {
        XCTAssertNil(LocalNetworkProbeEvent.outcome(of: .policyDenied, sawPolicyDenied: true))
    }

    func testProbeThatEndsAfterPolicyDeniedReportsDenied() {
        XCTAssertEqual(LocalNetworkProbeEvent.outcome(of: .timedOut, sawPolicyDenied: true), .denied)
        XCTAssertEqual(LocalNetworkProbeEvent.outcome(of: .failed, sawPolicyDenied: true), .denied)
    }

    func testProbeThatEndsWithoutAnAnswerIsUnknown() {
        XCTAssertEqual(LocalNetworkProbeEvent.outcome(of: .timedOut, sawPolicyDenied: false), .unknown)
    }
}

@MainActor
private final class FakePermissionProvider: SystemPermissionProviding {
    var currentStatuses: [SystemPermission: SystemPermissionStatus] = [:]
    var requestResults: [SystemPermission: SystemPermissionStatus] = [:]
    private(set) var checked: [SystemPermission] = []
    private(set) var requested: [SystemPermission] = []

    private var heldPermission: SystemPermission?
    private var heldRead: CheckedContinuation<SystemPermissionStatus, Never>?

    var isHoldingStatusRead: Bool { heldRead != nil }

    /// The next status read for `permission` suspends until `releaseStatusRead` is called.
    func holdStatusRead(of permission: SystemPermission) {
        heldPermission = permission
    }

    func releaseStatusRead(returning status: SystemPermissionStatus) {
        heldRead?.resume(returning: status)
        heldRead = nil
    }

    func currentStatus(of permission: SystemPermission) async -> SystemPermissionStatus {
        checked.append(permission)
        if permission == heldPermission {
            heldPermission = nil
            return await withCheckedContinuation { heldRead = $0 }
        }
        return currentStatuses[permission] ?? .notDetermined
    }

    func request(_ permission: SystemPermission) async -> SystemPermissionStatus {
        requested.append(permission)
        return requestResults[permission] ?? .notDetermined
    }

    func openSystemSettings(for permission: SystemPermission) {}
}
