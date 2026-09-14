import Foundation

/// The current user's home directory.
///
/// `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS, and MyTermCore is shared with
/// the companion app, so the API cannot be called directly from shared code. macOS keeps calling it
/// so behavior on the Mac is unchanged.
public enum UserHomeDirectory {
    public static var current: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory())
        #endif
    }
}
