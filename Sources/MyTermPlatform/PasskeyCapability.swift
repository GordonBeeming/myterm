import AuthenticationServices
import Observation
import Security

public enum PasskeyCapability {
    private static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    public static var isEnabled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool
        else {
            return false
        }
        return value
    }
}

public enum PasskeyAccessState: Equatable, Sendable {
    case unavailable
    case notDetermined
    case denied
    case authorized
}

@MainActor
@Observable
public final class PasskeyAccessController {
    public private(set) var state: PasskeyAccessState

    private let manager: ASAuthorizationWebBrowserPublicKeyCredentialManager?

    public init(entitlementEnabled: Bool = PasskeyCapability.isEnabled) {
        guard entitlementEnabled else {
            manager = nil
            state = .unavailable
            return
        }

        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        self.manager = manager
        state = Self.state(from: manager.authorizationStateForPlatformCredentials)
    }

    public func requestAccess() {
        guard let manager, state == .notDetermined else { return }

        manager.requestAuthorizationForPublicKeyCredentials { [weak self] authorizationState in
            Task { @MainActor [weak self] in
                self?.state = Self.state(from: authorizationState)
            }
        }
    }

    private static func state(
        from authorizationState: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> PasskeyAccessState {
        switch authorizationState {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}
