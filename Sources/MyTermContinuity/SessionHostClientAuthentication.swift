import Darwin
import Foundation
import Security

/// Pins the controller identity once, before starting a shell. A private socket and
/// matching UID alone do not distinguish MyTerm from another app in the same account.
public final class SessionHostClientAuthentication {
    private let requirement: SecRequirement?
    private let testAuditToken: Data?
    private let requiresHardenedRuntime: Bool
    static let testAuditTokenVariable = "MYTERM_TEST_CONTROLLER_AUDIT_TOKEN"

    public init() throws {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess else {
            throw SessionHostError.untrustedController
        }
        var ownStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode else {
            throw SessionHostError.untrustedController
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let ownExecutable = info[kSecCodeInfoMainExecutable as String] as? URL else {
            throw SessionHostError.untrustedController
        }

        #if DEBUG
        // Only an unbundled Debug helper supports the explicit test harness. The
        // kernel token identifies one process incarnation, not any same-UID peer.
        if (identifier == "MyTermSessionHost" || identifier.hasPrefix("MyTermSessionHost-")),
           !ownExecutable.pathComponents.contains(where: { $0.hasSuffix(".app") }),
           let raw = ProcessInfo.processInfo.environment[Self.testAuditTokenVariable],
           let token = Data(base64Encoded: raw), token.count == MemoryLayout<audit_token_t>.size {
            testAuditToken = token
            requirement = nil
            requiresHardenedRuntime = false
            return
        }
        #endif

        let appIdentifier: String
        switch identifier {
        case "com.gordonbeeming.myterm.session-host": appIdentifier = "com.gordonbeeming.myterm"
        case "com.gordonbeeming.myterm.dev.session-host": appIdentifier = "com.gordonbeeming.myterm.dev"
        default: throw SessionHostError.untrustedController
        }
        testAuditToken = nil
        requiresHardenedRuntime = appIdentifier == "com.gordonbeeming.myterm"
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
           !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            requirement = try Self.signingRequirement(identifier: appIdentifier, team: team, production: requiresHardenedRuntime)
        } else {
            #if DEBUG
            // Explicit ad-hoc development builds have no team identity. Pin the
            // adjacent app's exact designated requirement at host startup so a
            // later replacement on disk cannot change the accepted controller.
            guard appIdentifier.hasSuffix(".dev") else {
                throw SessionHostError.untrustedController
            }
            let appURL = ownExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            var appCode: SecStaticCode?
            guard appURL.pathExtension == "app",
                  SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode) == errSecSuccess, let appCode,
                  SecStaticCodeCheckValidity(appCode, [], nil) == errSecSuccess else {
                throw SessionHostError.untrustedController
            }
            var appInformation: CFDictionary?
            guard SecCodeCopySigningInformation(appCode, [], &appInformation) == errSecSuccess,
                  let appInfo = appInformation as? [String: Any],
                  appInfo[kSecCodeInfoIdentifier as String] as? String == appIdentifier else {
                throw SessionHostError.untrustedController
            }
            var result: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(appCode, [], &result) == errSecSuccess,
                  let result else { throw SessionHostError.untrustedController }
            requirement = result
            #else
            throw SessionHostError.untrustedController
            #endif
        }
    }

    /// Only an explicitly authorised unbundled Debug helper may enable fixture scheduling faults.
    public var usesTestHarnessIdentity: Bool {
        #if DEBUG
        return testAuditToken != nil
        #else
        return false
        #endif
    }

    public func authenticate(_ descriptor: Int32) throws {
        try SessionHostSocket.authenticate(descriptor)
        let token = try Self.peerAuditToken(descriptor)
        if let testAuditToken {
            guard token == testAuditToken else { throw SessionHostError.untrustedController }
            return
        }
        var peer: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess, let peer,
              SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else {
            throw SessionHostError.untrustedController
        }
        if requiresHardenedRuntime { try Self.validateHardenedRuntime(peer) }
    }

    static func signingRequirement(identifier: String, team: String, production: Bool) throws -> SecRequirement {
        guard ["com.gordonbeeming.myterm", "com.gordonbeeming.myterm.dev",
               "com.gordonbeeming.myterm.session-host", "com.gordonbeeming.myterm.dev.session-host"].contains(identifier),
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw SessionHostError.untrustedController
        }
        var expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        if production { expression += " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" }
        var result: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &result) == errSecSuccess,
              let result else { throw SessionHostError.untrustedController }
        return result
    }

    static func validateHardenedRuntime(_ peer: SecCode) throws {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peer, [], &staticCode) == errSecSuccess, let staticCode else {
            throw SessionHostError.untrustedController
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw SessionHostError.untrustedController
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for name in ["com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
                     "com.apple.security.cs.disable-library-validation"] {
            guard (entitlements[name] as? NSNumber)?.boolValue != true else {
                throw SessionHostError.untrustedController
            }
        }
    }

    static func peerAuditToken(_ descriptor: Int32) throws -> Data {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            throw SessionHostError.disconnected
        }
        guard size == MemoryLayout.size(ofValue: token) else { throw SessionHostError.untrustedController }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// Test targets explicitly pass this to unbundled Debug helpers. Release and
    /// packaged development helpers never consult this environment variable.
    static func testEnvironment() throws -> [String: String] {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw SessionHostError.system("test controller identity", errno)
        }
        defer { close(pair[0]); close(pair[1]) }
        return [testAuditTokenVariable: try peerAuditToken(pair[0]).base64EncodedString()]
    }
}
