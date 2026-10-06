import Foundation

/// Human-readable byte counts using decimal units, like Finder ("13.6 GB").
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value < 1_000 { return "\(Int(value)) bytes" }
        if value < 1_000_000 { return String(format: "%.0f KB", value / 1_000) }
        if value < 10_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value < 1_000_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        if value < 1_000_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        return String(format: "%.2f TB", value / 1_000_000_000_000)
    }

    /// Signed variant for growth/shrink figures ("+1.2 GB", "−300 MB").
    public static func signed(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 bytes" }
        return (bytes > 0 ? "+" : "−") + string(abs(bytes))
    }
}

public enum PathFormat {
    /// Replaces the home directory prefix with "~".
    public static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Parent directory of an absolute path.
    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    public static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        return name.isEmpty ? path : String(name)
    }

    /// Resolves symlinks with realpath(3), keeping "/private" prefixes intact
    /// (Foundation's resolvingSymlinksInPath strips them).
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` equals `ancestor` or lives below it.
    public static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

public enum DateFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    public static func relativeString(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    public static func shortString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
