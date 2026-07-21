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
