#if os(macOS)
import AppKit
import CoreServices
import Foundation
import OSLog

/// Pins a custom callback to an exact app copy, rather than just its bundle identifier.
public enum ApplicationCallbackRouting {
    @MainActor
    public static func prepare(applicationURL: URL, scheme: String) async throws {
        try validate(applicationURL: applicationURL, scheme: scheme)
        let status = LSRegisterURL(applicationURL as CFURL, true)
        guard status == noErr else { throw RoutingError.registrationFailed }
        try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: scheme)
        try Task.checkCancellation()
        do {
            try verify(applicationURL: applicationURL, scheme: scheme)
        } catch RoutingError.wrongApplication {
            // Launch Services can treat byte-identical copies as the same application and
            // keep selecting the older path. Remove competing registrations, never their files.
            guard let identifier = Bundle(url: applicationURL)?.bundleIdentifier else {
                throw RoutingError.invalidApplication
            }
            for copy in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
                where !isSameApplication(copy, applicationURL) && FileManager.default.fileExists(atPath: copy.path) {
                try Task.checkCancellation()
                do { try await unregister(copy) }
                catch {
                    Logger(subsystem: identifier, category: "callback-routing")
                        .notice("Could not remove a competing callback registration; checking the final route again.")
                }
            }
            try Task.checkCancellation()
            guard LSRegisterURL(applicationURL as CFURL, true) == noErr else { throw RoutingError.registrationFailed }
            try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: scheme)
            try Task.checkCancellation()
            try verify(applicationURL: applicationURL, scheme: scheme)
        }
    }

    private static func unregister(_ applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let finished = DispatchSemaphore(value: 0)
                    process.executableURL = URL(fileURLWithPath:
                        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
                    process.arguments = ["-u", applicationURL.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { _ in finished.signal() }
                    try process.run()
                    guard finished.wait(timeout: .now() + 5) == .success else {
                        if process.isRunning { process.terminate() }
                        throw RoutingError.registrationFailed
                    }
                    guard process.terminationStatus == 0 else { throw RoutingError.registrationFailed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
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
