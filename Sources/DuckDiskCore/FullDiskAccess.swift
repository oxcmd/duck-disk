import Foundation
import Darwin

public enum FullDiskAccess {
    /// The TCC database is only readable by processes with Full Disk Access.
    public static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    public static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
