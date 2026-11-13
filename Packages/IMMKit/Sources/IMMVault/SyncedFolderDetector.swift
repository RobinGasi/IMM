import Darwin
import Foundation

public enum SyncedFolderDetector {
    /// The user's real home directory (not the sandbox container).
    public static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// True for iCloud (ubiquitous item or `Library/Mobile Documents`), File Provider folders
    /// (`Library/CloudStorage`) and a top-level `~/Dropbox`.
    public static func isSynced(_ directory: URL, homeDirectory: URL = SyncedFolderDetector.realHomeDirectory) -> Bool {
        if (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return true
        }
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return true
        }
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.hasPrefix(home) else { return false }
        let first = path.dropFirst(home.count).split(separator: "/", omittingEmptySubsequences: true).first
        return first == "Dropbox"
    }
}
