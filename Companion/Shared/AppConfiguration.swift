import Foundation
import MyTermRemote

enum AppConfiguration {
    #if DEBUG
    static let bundleIdentifier = "com.gordonbeeming.myterm.companion.dev"
    static let urlScheme = "myterm-companion-dev"
    #else
    static let bundleIdentifier = "com.gordonbeeming.myterm.companion"
    static let urlScheme = "myterm-companion"
    #endif
    static let sharedKeychainGroup = Bundle.main.object(
        forInfoDictionaryKey: "MyTermKeychainAccessGroup"
    ) as? String

    static var pushGateway: RelayEndpoint? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MyTermPushGatewayOrigin") as? String,
              let url = URL(string: raw) else { return nil }
        return try? RelayEndpoint(url)
    }
}

enum UITestConfiguration {
    static var isIsolated: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MyTermUITestIsolated")
        #else
        false
        #endif
    }

    static var showsTerminalFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MyTermUITestTerminalFixture")
        #else
        false
        #endif
    }

    static var showsTouchFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MyTermUITestTouchFixture")
        #else
        false
        #endif
    }

    static var showsWorkspaceFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MyTermUITestWorkspaceFixture")
        #else
        false
        #endif
    }

    static var forgetsPaneSelection: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MyTermUITestForgetPaneSelection")
        #else
        false
        #endif
    }
}

extension Notification.Name {
    static let myTermAPNSToken = Notification.Name("MyTermAPNSToken")
    static let myTermAPNSOwnershipChallenge = Notification.Name("MyTermAPNSOwnershipChallenge")
    static let myTermNotificationRoute = Notification.Name("MyTermNotificationRoute")
}
