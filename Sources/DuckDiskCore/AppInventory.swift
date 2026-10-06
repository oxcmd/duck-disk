import AppKit
import CoreServices
import Darwin

public struct AppFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    /// Where it lives, e.g. "Application Support", "Caches", "Preferences".
    public let kind: String
}

public struct BackgroundItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case launchAgent = "Launch agent", launchDaemon = "Launch daemon",
                                         process = "Running process" }
    public var id: String { "\(kind.rawValue)|\(path ?? "")|\(pid ?? 0)" }
    public let name: String
    public let kind: Kind
    /// Plist path for launch items; executable path for processes.
    public let path: String?
    public let pid: Int32?
}

public struct AppInfo: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String?
    public let bundleSize: Int64
    public let lastUsed: Date?
    public let leftovers: [AppFile]
    /// Caches the app rebuilds by itself; clearing them keeps settings, documents and sign-ins.
    public let caches: [AppFile]
    /// Cookies and website storage (HTTPStorages, WebKit). Clearing them usually signs the user out.
    public let webData: [AppFile]
    public let background: [BackgroundItem]
    public let isApple: Bool

    public var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    public var footprint: Int64 { bundleSize + leftoverSize }
    public var isRunning: Bool { background.contains { $0.kind == .process } }
    public var cacheSize: Int64 { caches.reduce(0) { $0 + $1.size } }
    public var webDataSize: Int64 { webData.reduce(0) { $0 + $1.size } }
}

/// Builds the Applications room: every app, its data across ~/Library, and what runs in the background.
public enum AppInventory {
    /// Library folders searched for per-app data; matched by bundle id (prefix) or app name.
    static let dataFolders: [(folder: String, kind: String, byName: Bool)] = [
        ("Library/Application Support", "Application Support", true),
        ("Library/Caches", "Caches", true),
        ("Library/Containers", "Container", false),
        ("Library/Group Containers", "Group container", false),
        ("Library/Preferences", "Preferences", false),
        ("Library/Saved Application State", "Saved state", false),
        ("Library/HTTPStorages", "Web storage", false),
        ("Library/WebKit", "Web data", false),
        ("Library/Logs", "Logs", true),
        ("Library/Application Scripts", "Scripts", false),
        ("Library/Cookies", "Cookies", false),
    ]

    public static func load(home: String = NSHomeDirectory(),
                            progress: (@Sendable (Int, Int) -> Void)? = nil) -> [AppInfo] {
        let registry = InstalledAppRegistry.load(home: home)
        let apps = registry.entries.filter { !$0.url.path.hasPrefix("/System/") }
        let owned = assignData(apps: apps, home: home)
        let launchItems = loadLaunchItems(home: home)
        let launchOwners = launchItems.map { owner(ofLaunchItem: $0, apps: apps) }
        let processes = runningProcessPaths()

        var results = [AppInfo?](repeating: nil, count: apps.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let items = launchItems.indices.filter { launchOwners[$0] == i }.map { launchItems[$0] }
            let info = makeInfo(apps[i], home: home, data: owned[i] ?? [], launchItems: items, processes: processes)
            lock.lock()
            results[i] = info
            done += 1
            let d = done
            lock.unlock()
            progress?(d, apps.count)
        }
        return results.compactMap { $0 }.sorted { $0.footprint > $1.footprint }
    }

    /// Gives every per-app folder or file in ~/Library to at most one app, so uninstalling one app can never
    /// take another app's data. Bundle-id matches win (longest id first); folder names only count when they are
    /// the app's own name and no other app shares it.
    static func assignData(apps: [InstalledAppRegistry.Entry], home: String) -> [Int: [(path: String, kind: String)]] {
        let ids = apps.map { $0.bundleID.lowercased() }
        var primary: [String: [Int]] = [:], secondary: [String: [Int]] = [:]
        for (i, app) in apps.enumerated() where !ids[i].hasPrefix("com.apple.") {
            let main = Set([app.name, app.url.deletingPathExtension().lastPathComponent].map { $0.lowercased() })
            for n in main where n.count >= 3 { primary[n, default: []].append(i) }
            for n in Set([app.bundleName, app.executable].compactMap { $0?.lowercased() }).subtracting(main)
            where n.count >= 3 {
                secondary[n, default: []].append(i)
            }
        }
        func nameOwner(_ name: String) -> Int? {
            if let p = primary[name] { return p.count == 1 ? p[0] : nil }
            if let s = secondary[name], s.count == 1 { return s[0] }
            return nil
        }

        var out: [Int: [(path: String, kind: String)]] = [:]
        for f in dataFolders {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: home + "/" + f.folder)) ?? []
            for entry in entries {
                let lower = entry.lowercased()
                let stripped = Classifier.bundleID(fromEntry: lower)
                let byID = ids.indices.filter { i in
                    !ids[i].hasPrefix("com.apple.")
                        && (stripped == ids[i] || stripped.hasPrefix(ids[i] + ".")
                            || (f.folder.hasSuffix("Group Containers") && stripped.hasSuffix("." + ids[i])))
                }.max { ids[$0].count < ids[$1].count }
                guard let owner = byID ?? (f.byName ? nameOwner(lower) : nil) else { continue }
                out[owner, default: []].append((home + "/" + f.folder + "/" + entry, f.kind))
            }
        }
        return out
    }

    /// The app a launch agent or daemon belongs to: label equal to or under its bundle id (longest wins),
    /// or a program inside its bundle.
    static func owner(ofLaunchItem item: LaunchItem, apps: [InstalledAppRegistry.Entry]) -> Int? {
        let label = item.label.lowercased()
        if let byLabel = apps.indices.filter({ i in
            let id = apps[i].bundleID.lowercased()
            return label == id || label.hasPrefix(id + ".")
        }).max(by: { apps[$0].bundleID.count < apps[$1].bundleID.count }) {
            return byLabel
        }
        guard let program = item.program else { return nil }
        return apps.indices.first { program.hasPrefix(apps[$0].url.path + "/") }
    }

    static func makeInfo(_ app: InstalledAppRegistry.Entry, home: String, data: [(path: String, kind: String)],
                         launchItems: [LaunchItem], processes: [(Int32, String)]) -> AppInfo {
        let isApple = app.bundleID.lowercased().hasPrefix("com.apple.")
        var leftovers = data.map { AppFile(path: $0.path, size: DirectorySize.of($0.path), kind: $0.kind) }
        let appPath = app.url.path
        var background: [BackgroundItem] = launchItems.map {
            BackgroundItem(name: $0.label, kind: $0.isDaemon ? .launchDaemon : .launchAgent, path: $0.plist, pid: nil)
        }
        background += processes.filter { $0.1.hasPrefix(appPath + "/") }.map {
            BackgroundItem(name: PathFormat.lastComponent($0.1), kind: .process, path: $0.1, pid: $0.0)
        }
        // Launch agent plists in the user's folder belong with the app's leftovers.
        for b in background where b.kind == .launchAgent {
            if let p = b.path, p.hasPrefix(home + "/") {
                leftovers.append(AppFile(path: p, size: DirectorySize.of(p), kind: "Launch agent"))
            }
        }
        return AppInfo(path: appPath, name: app.name, bundleID: app.bundleID, version: app.version,
                       bundleSize: DirectorySize.of(appPath), lastUsed: lastUsedDate(appPath),
                       leftovers: leftovers.sorted { $0.size > $1.size }, caches: cacheFiles(from: leftovers),
                       webData: webDataFiles(from: leftovers),
                       background: background, isApple: isApple)
    }

    static let webDataKinds: Set<String> = ["Web storage", "Web data"]

    /// The app's Caches folders, plus what is inside the Caches folder of each of its sandbox containers
    /// (the container folder itself belongs to macOS and stays).
    static func cacheFiles(from data: [AppFile]) -> [AppFile] {
        var out = data.filter { $0.kind == "Caches" }
        for container in data where container.kind == "Container" {
            let caches = container.path + "/Data/Library/Caches"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: caches)) ?? [] where name != ".DS_Store" {
                let path = caches + "/" + name
                out.append(AppFile(path: path, size: DirectorySize.of(path), kind: "Container cache"))
            }
        }
        return out.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    /// Cookies and website data stored for the app.
    static func webDataFiles(from data: [AppFile]) -> [AppFile] {
        data.filter { webDataKinds.contains($0.kind) && $0.size > 0 }.sorted { $0.size > $1.size }
    }

    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    struct LaunchItem {
        let label: String
        let program: String?
        let plist: String
        let isDaemon: Bool
    }

    static func loadLaunchItems(home: String) -> [LaunchItem] {
        let folders = [(home + "/Library/LaunchAgents", false), ("/Library/LaunchAgents", false),
                       ("/Library/LaunchDaemons", true)]
        var out: [LaunchItem] = []
        for (folder, daemon) in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? String(name.dropLast(6))
                let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
                    ?? dict["BundleProgram"] as? String
                out.append(LaunchItem(label: label, program: program, plist: path, isDaemon: daemon))
            }
        }
        return out
    }

    /// (pid, executable path) of every process we are allowed to inspect.
    public static func runningProcessPaths() -> [(Int32, String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var out: [(Int32, String)] = []
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            if len > 0 { out.append((pid, String(cString: buf))) }
        }
        return out
    }
}

/// Allocated size of a file or folder, using the bulk scanner for folders.
public enum DirectorySize {
    public static func of(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT != S_IFDIR { return Int64(st.st_blocks) * 512 }
        var opts = ScanOptions()
        opts.threadCount = 2
        return DiskScanner(rootPath: path, options: opts).scanSync()?.root.size ?? 0
    }
}
