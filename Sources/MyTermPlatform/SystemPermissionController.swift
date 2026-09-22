import MyTermCore
import Observation

/// Reads and requests macOS privacy permissions on MyTerm's behalf.
///
/// `currentStatus` must never cause a prompt: it runs every time Settings opens or the app
/// becomes active. Anything that can only be learned by touching the resource reports `.unknown`
/// there and does the touching in `request`.
@MainActor
public protocol SystemPermissionProviding: AnyObject {
    func currentStatus(of permission: SystemPermission) async -> SystemPermissionStatus
    func request(_ permission: SystemPermission) async -> SystemPermissionStatus
    func openSystemSettings(for permission: SystemPermission)
}

@MainActor
@Observable
public final class SystemPermissionController {
    public private(set) var statuses: [SystemPermission: SystemPermissionStatus] = [:]
    public private(set) var pending: Set<SystemPermission> = []

    /// Outcomes of probe-style requests. macOS gives no way to read these back without touching
    /// the resource again, so they're kept for the life of the process to stop a refresh from
    /// resetting a row to "Not checked".
    private var probeResults: [SystemPermission: SystemPermissionStatus] = [:]
    /// Bumped whenever a request stores a status, so a refresh that read the old value before
    /// suspending can tell its answer is stale and drop it.
    private var generations: [SystemPermission: Int] = [:]
    private let provider: any SystemPermissionProviding

    public init(provider: any SystemPermissionProviding) {
        self.provider = provider
    }

    #if os(macOS)
    public convenience init() {
        self.init(provider: LiveSystemPermissionProvider())
    }
    #endif

    public func status(of permission: SystemPermission) -> SystemPermissionStatus {
        if permission.grantStyle == .informational { return .informational }
        return statuses[permission] ?? .unknown
    }

    public func refresh() async {
        for permission in SystemPermission.allCases where permission.grantStyle != .informational {
            let generation = generations[permission, default: 0]
            let current = await provider.currentStatus(of: permission)
            guard generations[permission, default: 0] == generation else { continue }
            if current == .unknown, let probed = probeResults[permission] {
                statuses[permission] = probed
            } else {
                statuses[permission] = current
            }
        }
    }

    public func request(_ permission: SystemPermission) async {
        guard permission.requestButtonTitle(for: status(of: permission)) != nil,
              !pending.contains(permission)
        else { return }

        pending.insert(permission)
        defer { pending.remove(permission) }

        generations[permission, default: 0] += 1
        let result = await provider.request(permission)
        // A refresh that started while the request was out read the status before the answer.
        generations[permission, default: 0] += 1
        if permission.grantStyle == .probe {
            probeResults[permission] = result
        }
        statuses[permission] = result
    }

    public func openSystemSettings(for permission: SystemPermission) {
        provider.openSystemSettings(for: permission)
    }
}
