#if os(macOS)
import AppKit
import CoreServices
import Foundation

/// Pins a custom callback to an exact app copy, rather than just its bundle identifier.
public enum ApplicationCallbackRouting {
    @MainActor
    public static func prepare(applicationURL: URL, scheme: String) async throws {
        try validate(applicationURL: applicationURL, scheme: scheme)
        let status = LSRegisterURL(applicationURL as CFURL, true)
        guard status == noErr else { throw RoutingError.registrationFailed }
        try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: scheme)
        try Task.checkCancellation()
        try verify(applicationURL: applicationURL, scheme: scheme)
    }

    @MainActor
    public static func verify(applicationURL: URL, scheme: String) throws {
        try validate(applicationURL: applicationURL, scheme: scheme)
        guard let callback = URL(string: "\(scheme)://companion-auth/callback"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: callback),
              isSameApplication(handler, applicationURL) else {
            throw RoutingError.wrongApplication
        }
    }

    private static func isSameApplication(_ first: URL, _ second: URL) -> Bool {
        let first = first.resolvingSymlinksInPath().standardizedFileURL
        let second = second.resolvingSymlinksInPath().standardizedFileURL
        if first == second { return true }
        // APFS can give the same app two differently cased path strings.
        guard let left = try? FileManager.default.attributesOfItem(atPath: first.path),
              let right = try? FileManager.default.attributesOfItem(atPath: second.path),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let leftFile = left[.systemFileNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let rightFile = right[.systemFileNumber] as? NSNumber else { return false }
        return leftDevice == rightDevice && leftFile == rightFile
    }

    private static func validate(applicationURL: URL, scheme: String) throws {
        guard applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app",
              scheme.hasPrefix("myterm"),
              let bundle = Bundle(url: applicationURL),
              let types = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else {
            throw RoutingError.invalidApplication
        }
    }

    private enum RoutingError: LocalizedError {
        case invalidApplication, registrationFailed, wrongApplication
        var errorDescription: String? {
            switch self {
            case .invalidApplication: "This app cannot receive the sign-in callback. Install MyTerm again and retry."
            case .registrationFailed: "macOS could not register this app for sign-in. Reinstall MyTerm and retry."
            case .wrongApplication: "macOS is routing sign-in to another app copy. Reinstall MyTerm and retry."
            }
        }
    }
}
#endif
