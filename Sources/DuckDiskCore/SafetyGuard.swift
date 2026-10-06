import Foundation
import Darwin

/// Decides whether a path may be moved to the Trash. Every removal in the app goes through `check`.
public enum SafetyGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
        public var reason: String? {
            if case .denied(let r) = self { return r }
            return nil
        }
    }

    /// Paths that are never touched, nor anything inside them.
    static let protectedTrees = [
        "/System", "/bin", "/sbin", "/usr", "/dev", "/cores", "/private/etc", "/private/var/db",
        "/private/var/vm", "/private/var/root", "/private/var/protected", "/Library/Apple",
        "/Library/Keychains", "/Library/Security", "/Library/Preferences/SystemConfiguration",
        "/Library/Application Support/com.apple.TCC", "/System/Volumes",
    ]

    /// Home-relative trees that hold irreplaceable or system-managed data.
    static let protectedHomeTrees = [
        ".Trash", "Library/Keychains", "Library/Mobile Documents", "Library/Mail", "Library/Messages",
        "Library/Photos", "Library/Accounts", "Library/Calendars", "Library/Reminders",
        "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/FileProvider", "Library/CloudStorage", "Library/Cookies",
        "Library/IdentityServices", "Library/Sharing", "Library/Group Containers/group.com.apple.notes",
        "Library/Containers/com.apple.mail", "Library/Containers/com.apple.Notes",
        "Library/Containers/com.apple.iChat", "Library/Containers/com.apple.Safari/Data/Library/Safari",
    ]

    /// Folders that may be cleared from inside but never removed themselves.
    static let protectedFolders = [
        "/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp",
        "/opt", "/Library/Caches", "/Library/Logs",
    ]

    static let protectedHomeFolders = [
        "", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Applications", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
        "Library/Containers", "Library/Group Containers", "Library/Developer", ".config", ".cache",
    ]

    /// Cache folders that belong to sign-in, sync and system daemons; clearing them causes re-syncs or sign-outs.
    public static let protectedCacheNames: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.akd", "com.apple.iCloudHelper", "com.apple.nsurlsessiond",
        "com.apple.containermanagerd", "FamilyCircle", "com.apple.ap.adprivacyd", "com.apple.homed",
        "com.apple.amsengagementd", "com.apple.Safari.SafeBrowsing", "com.apple.passd", "com.apple.findmy",
        "com.apple.icloud.searchpartyd", "com.apple.parsecd", "GeoServices", "com.apple.appstoreagent",
        "com.apple.commerce", "com.apple.mediaanalysisd", "com.apple.photoanalysisd",
    ]

    /// Media libraries are managed by their apps (Photos, Music, iMovie, Final Cut) and are never trashed,
    /// whole or in part.
    static let mediaLibraryExtensions = [".photoslibrary", ".photolibrary", ".aplibrary", ".musiclibrary",
                                         ".tvlibrary", ".imovielibrary", ".fcpbundle"]

    public static func check(_ rawPath: String, home rawHome: String = NSHomeDirectory()) -> Verdict {
        guard rawPath.hasPrefix("/"), rawPath.count > 1, !rawPath.contains("//"), !rawPath.contains("/./"),
              !rawPath.contains("/../"), !rawPath.hasSuffix("/."), !rawPath.hasSuffix("/.."), !rawPath.hasSuffix("/")
        else {
            return .denied("Not a plain absolute path.")
        }
        // Resolve symlinks in the parent (the item itself is moved, never its target), then compare
        // case-insensitively because APFS volumes are case-insensitive by default.
        let parentReal = PathFormat.realPath(PathFormat.parent(of: rawPath))
        let resolved = (parentReal == "/" ? "" : parentReal) + "/" + PathFormat.lastComponent(rawPath)
        let path = resolved.lowercased()
        let home = PathFormat.realPath(rawHome).lowercased()

        for tree in protectedTrees where PathFormat.isInside(path, tree.lowercased()) {
            return .denied("Part of macOS. Duck Disk never touches it.")
        }
        for tree in protectedHomeTrees where PathFormat.isInside(path, home + "/" + tree.lowercased()) {
            return .denied("Holds data macOS or iCloud manages.")
        }
        if protectedFolders.contains(where: { $0.lowercased() == path }) {
            return .denied("A system folder. Clear what is inside instead.")
        }
        for folder in protectedHomeFolders where path == (folder.isEmpty ? home : home + "/" + folder.lowercased()) {
            return .denied("A standard folder. Clear what is inside instead.")
        }
        if isMediaLibrary(path) {
            return .denied("Part of a Photos, Music or video library. Manage it in that app.")
        }
        let appBundle = Bundle.main.bundlePath.lowercased()
        if appBundle.hasSuffix(".app"), PathFormat.isInside(path, appBundle) {
            return .denied("This is Duck Disk itself.")
        }
        let caches = home + "/library/caches/"
        if path.hasPrefix(caches) {
            let first = path.dropFirst(caches.count).split(separator: "/").first.map(String.init)
            if let first, protectedCacheNames.contains(where: { $0.lowercased() == first }) {
                return .denied("Used by iCloud or a system service.")
            }
        }
        return permissionVerdict(resolved)
    }

    /// True when any path component is a media library bundle (the bundle itself or anything inside it).
    static func isMediaLibrary(_ lowercasedPath: String) -> Bool {
        lowercasedPath.split(separator: "/").contains { component in
            mediaLibraryExtensions.contains { component.hasSuffix($0) }
        }
    }

    /// The parent must be writable, and in sticky folders (like /Library/Caches) the item must be ours.
    static func permissionVerdict(_ path: String) -> Verdict {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .denied("No longer exists.") }
        let parent = PathFormat.parent(of: path)
        guard access(parent, W_OK) == 0 else { return .denied("Needs administrator rights.") }
        var pst = stat()
        if stat(parent, &pst) == 0, pst.st_mode & S_ISVTX != 0, st.st_uid != getuid() {
            return .denied("Owned by another user or the system.")
        }
        return .allowed
    }
}
