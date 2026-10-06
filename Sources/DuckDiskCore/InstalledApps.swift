import AppKit

/// Bundle identifiers and names of apps present on this Mac, used to tell live app data from leftovers.
public struct InstalledAppRegistry: Sendable {
    public struct Entry: Sendable {
        public let url: URL
        public let bundleID: String
        public let name: String
        public let bundleName: String?
        public let executable: String?
        public let version: String?
    }

    public let entries: [Entry]
    private let ids: Set<String>
    private let vendors: Set<String>
    private let namesByID: [String: String]
    /// Extra identifiers known to be in use (running apps, test fixtures).
    private let extraIDs: Set<String>
    private let useLaunchServices: Bool

    public init(entries: [Entry], extraIDs: Set<String> = [], useLaunchServices: Bool = true) {
        self.entries = entries
        let all = entries.map { $0.bundleID.lowercased() } + extraIDs.map { $0.lowercased() }
        ids = Set(all)
        vendors = Set(all.compactMap(Self.vendor))
        var names: [String: String] = [:]
        for e in entries { names[e.bundleID.lowercased()] = e.name }
        namesByID = names
        self.extraIDs = Set(extraIDs.map { $0.lowercased() })
        self.useLaunchServices = useLaunchServices
    }

    public static let searchRoots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                     "/System/Applications/Utilities", "/System/Library/CoreServices"]

    /// Reads app bundles from the standard folders (one level of subfolders deep) plus running apps.
    public static func load(home: String = NSHomeDirectory()) -> InstalledAppRegistry {
        var urls: [URL] = []
        let fm = FileManager.default
        for root in searchRoots + [home + "/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names {
                let path = root + "/" + n
                if n.hasSuffix(".app") {
                    urls.append(URL(fileURLWithPath: path))
                } else if !n.hasPrefix("."), let inner = try? fm.contentsOfDirectory(atPath: path) {
                    urls += inner.filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: path + "/" + $0) }
                }
            }
        }
        var seen = Set<String>()
        let entries = urls.compactMap { url -> Entry? in
            guard let e = entry(for: url), seen.insert(e.url.path).inserted else { return nil }
            return e
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return InstalledAppRegistry(entries: entries, extraIDs: running)
    }

    public static func entry(for url: URL) -> Entry? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let display = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        let fileName = url.deletingPathExtension().lastPathComponent
        return Entry(url: url, bundleID: id, name: display ?? fileName, bundleName: bundleName,
                     executable: info["CFBundleExecutable"] as? String,
                     version: info["CFBundleShortVersionString"] as? String)
    }

    /// "com.vendor.app" → "com.vendor".
    static func vendor(_ id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts[0] + "." + parts[1]
    }

    /// Reverse-DNS names such as "com.vendor.app" (three or more parts, no spaces).
    public static func looksLikeBundleID(_ name: String) -> Bool {
        guard !name.contains(" "), !name.hasPrefix("."), name.split(separator: ".").count >= 3 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// True when an app with this identifier — or from the same vendor — is installed or registered.
    public func isInUse(bundleID raw: String) -> Bool {
        let id = raw.lowercased()
        if id.hasPrefix("com.apple.") || ids.contains(id) { return true }
        if ids.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return true }
        if let v = Self.vendor(id), vendors.contains(v) { return true }
        if useLaunchServices, NSWorkspace.shared.urlForApplication(withBundleIdentifier: raw) != nil { return true }
        return false
    }

    public func appName(forBundleID id: String) -> String? { namesByID[id.lowercased()] }
}
