import Darwin
import Foundation
import Security

/// Verifies the kernel-identified server before the controller consumes a checkpoint or sends
/// terminal input. Socket ownership and matching UID alone cannot identify a MyTerm helper.
public final class SessionHostServerAuthentication {
    private let requirement: SecRequirement
    private let requiresHardenedRuntime: Bool
    private let permitsTestLauncher: Bool

    public init(environment: [String: String] = [:], helperURL: URL? = nil) throws {
        var ownCode: SecCode?
        var ownStatic: SecStaticCode?
        var rawInfo: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(ownCode, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL else {
            throw SessionHostError.untrustedHost
        }
        let production = identifier == "com.gordonbeeming.myterm"
        if production || identifier == "com.gordonbeeming.myterm.dev" {
            permitsTestLauncher = false
            requiresHardenedRuntime = production
            if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
                requirement = try SessionHostClientAuthentication.signingRequirement(
                    identifier: identifier + ".session-host", team: team, production: production)
            } else {
                #if DEBUG
                guard !production else { throw SessionHostError.untrustedHost }
                requirement = try Self.designatedRequirement(
                    of: executable.deletingLastPathComponent().appendingPathComponent("MyTermSessionHost"),
                    expectedIdentifier: identifier + ".session-host")
                #else
                throw SessionHostError.untrustedHost
                #endif
            }
            return
        }
        #if DEBUG
        // The caller must explicitly identify this exact process incarnation. This branch is
        // unavailable to packaged apps, even when an inherited environment contains the key.
        // Xcode's local xctest runner may itself be ad-hoc signed inside Xcode.app.
        // Admit only that exact runner while a test product is actually loaded; the explicit
        // token still binds this process incarnation, and the real helper remains DR-pinned.
        let testBundles = Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }
        let isXCTest = identifier == "com.apple.xctest" && executable.lastPathComponent == "xctest"
            && !testBundles.isEmpty
        guard (!executable.pathComponents.contains(where: { $0.hasSuffix(".app") }) || isXCTest),
              let raw = environment[SessionHostClientAuthentication.testAuditTokenVariable],
              let expectedToken = Data(base64Encoded: raw),
              expectedToken == (try Self.currentAuditToken()) else { throw SessionHostError.untrustedHost }
        requiresHardenedRuntime = false
        permitsTestLauncher = true
        // Test launch wrappers are scripts, not the helper's code-signing identity. Prefer a
        // signed helperURL, otherwise discover the actual built helper next to the test product.
        if let helperURL, let pinned = try? Self.designatedRequirement(of: helperURL, expectedIdentifier: nil) {
            requirement = pinned
            return
        }
        for bundle in testBundles + [Bundle.main] {
            var directory = bundle.bundleURL
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent("MyTermSessionHost")
                if let pinned = try? Self.designatedRequirement(of: candidate, expectedIdentifier: nil) {
                    requirement = pinned
                    return
                }
                directory.deleteLastPathComponent()
            }
        }
        throw SessionHostError.untrustedHost
        #else
        throw SessionHostError.untrustedHost
        #endif
    }

    /// Validate the executable before inheriting terminal environment into a launched process.
    /// Test wrappers may delegate to a real helper, whose live identity is still authenticated.
    public func validateExecutable(_ url: URL) throws {
        #if DEBUG
        if permitsTestLauncher {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if try handle.read(upToCount: 2) == Data([0x23, 0x21]) { return }
        }
        #endif
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw SessionHostError.untrustedHost
        }
    }

    public func authenticate(_ descriptor: Int32) throws {
        do {
            try SessionHostSocket.authenticate(descriptor)
            let token = try SessionHostClientAuthentication.peerAuditToken(descriptor)
            var peer: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary,
                    [], &peer) == errSecSuccess, let peer,
                  SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else { throw SessionHostError.untrustedHost }
            if requiresHardenedRuntime { try SessionHostClientAuthentication.validateHardenedRuntime(peer) }
        } catch SessionHostError.disconnected {
            // No peer credentials were obtained: the connection vanished, rather than proving
            // a mismatched identity. Callers may retry, but must authenticate the fresh socket.
            throw SessionHostError.disconnected
        } catch { throw SessionHostError.untrustedHost }
    }

    private static func designatedRequirement(of url: URL, expectedIdentifier: String?) throws -> SecRequirement {
        var code: SecStaticCode?
        var rawInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, [], &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else { throw SessionHostError.untrustedHost }
        if let expectedIdentifier {
            guard identifier == expectedIdentifier else { throw SessionHostError.untrustedHost }
        } else {
            guard identifier == "MyTermSessionHost" || identifier.hasPrefix("MyTermSessionHost-") else {
                throw SessionHostError.untrustedHost
            }
        }
        var result: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &result) == errSecSuccess, let result else {
            throw SessionHostError.untrustedHost
        }
        return result
    }

    private static func currentAuditToken() throws -> Data {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SessionHostError.untrustedHost }
        defer { close(pair[0]); close(pair[1]) }
        return try SessionHostClientAuthentication.peerAuditToken(pair[0])
    }
}
