import Foundation

public struct ClassifierContext: Sendable {
    public var home: String
    /// Real path of the per-user temporary folder.
    public var tempDir: String
    public var oldDownloadDays: Int = 90
    public var staleProjectDays: Int = 30
    public var tempAgeDays: Int = 3
    /// Loose model files (.gguf, .safetensors…) outside known model folders count from this size.
    public var aiStrayMinSize: Int64 = 100_000_000
    public var now: Date = Date()
    public var registry: InstalledAppRegistry

    public init(home: String = NSHomeDirectory(),
                tempDir: String = PathFormat.realPath(NSTemporaryDirectory()),
                registry: InstalledAppRegistry) {
        self.home = home
        self.tempDir = tempDir.hasSuffix("/") ? String(tempDir.dropLast()) : tempDir
        self.registry = registry
    }
}

/// Turns a scan tree into clearable items per category plus the grey "kept" breakdown.
/// Rules work on folder locations, so they apply whether the scan covered the disk or just the home folder.
public enum Classifier {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    static let leftoverFolders = ["Library/Application Support", "Library/Containers", "Library/Preferences",
                                  "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
                                  "Library/Application Scripts"]
    static let developerFolders = ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
                                   "Library/Developer/Xcode/iOS DeviceSupport",
                                   "Library/Developer/Xcode/watchOS DeviceSupport",
                                   "Library/Developer/Xcode/tvOS DeviceSupport",
                                   "Library/Developer/Xcode/visionOS DeviceSupport",
                                   "Library/Developer/Xcode/macOS DeviceSupport",
                                   "Library/Developer/CoreSimulator/Caches", ".cache"]
    static let developerCaches = [".npm/_cacache", ".yarn/berry/cache", ".gradle/caches", ".cargo/registry",
                                  "go/pkg/mod", ".m2/repository", ".pub-cache", ".bun/install/cache",
                                  "Library/pnpm/store", ".pnpm-store", ".cocoapods/repos", ".nuget/packages",
                                  ".android/cache", ".expo"]
    /// Folders under ~/.cache that hold AI models; they are listed under AI models, not Developer files.
    static let aiCacheFolders: Set<String> = ["huggingface", "lm-studio", "whisper", "torch"]
    /// Model folders: home-relative path, depth of the items below it, and the app that owns them.
    static let aiModelFolders: [(path: String, depth: Int, app: String)] = [
        (".lmstudio/models", 2, "LM Studio"), (".cache/lm-studio/models", 2, "LM Studio"),
        ("Library/Application Support/nomic.ai/GPT4All", 1, "GPT4All"),
        ("jan/models", 1, "Jan"), ("Library/Application Support/Jan/data/models", 2, "Jan"),
        ("Library/Containers/com.liuliu.draw-things/Data/Documents/Models", 1, "Draw Things"),
        (".diffusionbee/downloads", 1, "DiffusionBee"),
        ("Library/Application Support/MacWhisper/models", 1, "MacWhisper"),
        (".cache/whisper", 1, "Whisper"), (".cache/torch/hub/checkpoints", 1, "PyTorch"),
    ]
    /// Model stores whose files are shared between models, so the whole folder is one item.
    static let aiModelStores: [(path: String, app: String)] = [
        (".ollama/models", "Ollama"), ("Library/Application Support/Msty/models", "Msty"),
    ]
    static let aiModelExtensions: Set<String> = ["gguf", "ggml", "safetensors", "ckpt"]
    /// GPT4All keeps databases next to its models; only these count there.
    static let gpt4allModelExtensions: Set<String> = ["gguf", "bin"]

    /// Build-output folders and the project file that must sit next to them.
    static let projectBuildFolders: [String: String] = ["node_modules": "package.json", ".build": "Package.swift",
                                                        "target": "Cargo.toml", "Pods": "Podfile"]

    public static func classify(_ tree: ScanTree, context ctx: ClassifierContext) -> Classification {
        var found: [CleanupItem] = []
        let lib = ctx.home + "/Library"

        // Caches
        for ref in children(tree, lib + "/Caches")
        where !SafetyGuard.protectedCacheNames.contains(ref.name) {
            found.append(item(ref, .caches, detail: appDetail(ref.name, ctx)))
        }
        if let containers = tree.node(atPath: lib + "/Containers") {
            for c in containers.subdirs where !c.isRemoved && !c.name.hasPrefix("com.apple.") {
                for ref in children(tree, c.path + "/Data/Library/Caches") {
                    found.append(item(ref, .caches, detail: appDetail(c.name, ctx)))
                }
            }
        }
        for ref in children(tree, "/Library/Caches") where SafetyGuard.check(ref.path, home: ctx.home).isAllowed {
            found.append(item(ref, .caches, detail: "Shared cache"))
        }

        // Logs and temporary files
        for base in [lib + "/Logs", "/Library/Logs"] {
            for ref in children(tree, base) {
                if ref.name == "DiagnosticReports" && ref.isDirectory {
                    for r in children(tree, ref.path) where allowed(r, ctx) {
                        found.append(item(r, .logs, detail: "Crash report"))
                    }
                } else if allowed(ref, ctx) {
                    found.append(item(ref, .logs, detail: base.hasPrefix("/Library") ? "System log" : "App log"))
                }
            }
        }
        for ref in children(tree, lib + "/Application Support/CrashReporter") {
            found.append(item(ref, .logs, detail: "Crash report"))
        }
        let tempCutoff = ctx.now.addingTimeInterval(-Double(ctx.tempAgeDays) * 86_400)
        for ref in children(tree, ctx.tempDir) where newestModification(ref) < tempCutoff {
            found.append(item(ref, .logs, detail: "Temporary file"))
        }

        // App leftovers
        for folder in leftoverFolders {
            for ref in children(tree, ctx.home + "/" + folder) {
                let id = bundleID(fromEntry: ref.name)
                guard InstalledAppRegistry.looksLikeBundleID(id), !ctx.registry.isInUse(bundleID: id) else { continue }
                found.append(item(ref, .leftovers, detail: "From \(id)"))
            }
        }

        // Developer files
        for folder in developerFolders {
            for ref in children(tree, ctx.home + "/" + folder)
            where !(folder == ".cache" && aiCacheFolders.contains(ref.name)) {
                found.append(item(ref, .developer, detail: developerDetail(folder)))
            }
        }
        for folder in developerCaches {
            if let node = tree.node(atPath: ctx.home + "/" + folder), node.size > 0 {
                found.append(item(ItemRef(dir: node), .developer, detail: "Package cache"))
            }
        }
        found += staleBuildFolders(tree, ctx)

        // AI models
        found += aiModels(tree, ctx)

        // Old downloads
        found += oldDownloads(tree, ctx)

        var result = Classification()
        for i in removingOverlaps(found.filter { $0.size > 0 }) {
            result.items[i.category, default: []].append(i)
        }
        for c in CleanupCategory.allCases {
            result.items[c] = (result.items[c] ?? []).sorted { $0.size > $1.size }
        }
        result.kept = keptBreakdown(tree, items: result.allItems, ctx)
        return result
    }

    // MARK: - Helpers

    static func children(_ tree: ScanTree, _ path: String) -> [ItemRef] {
        guard let node = tree.node(atPath: path) else { return [] }
        var refs: [ItemRef] = []
        for d in node.subdirs where !d.isRemoved { refs.append(ItemRef(dir: d)) }
        for f in node.files where !f.removed && f.name != ".DS_Store" && f.name != ".localized" {
            refs.append(ItemRef(dir: node, fileName: f.name))
        }
        return refs
    }

    static func item(_ ref: ItemRef, _ category: CleanupCategory, detail: String) -> CleanupItem {
        CleanupItem(path: ref.path, ref: ref, category: category, size: ref.size, name: ref.name,
                    detail: detail, modified: ref.modified)
    }

    static func allowed(_ ref: ItemRef, _ ctx: ClassifierContext) -> Bool {
        SafetyGuard.check(ref.path, home: ctx.home).isAllowed
    }

    static func appDetail(_ name: String, _ ctx: ClassifierContext) -> String {
        let id = bundleID(fromEntry: name)
        return ctx.registry.appName(forBundleID: id) ?? ""
    }

    /// Strips the suffixes macOS adds to per-app files ("com.x.y.plist", "com.x.y.savedState").
    static func bundleID(fromEntry name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies", ".lockfile"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func developerDetail(_ folder: String) -> String {
        if folder.hasSuffix("DerivedData") { return "Xcode build data" }
        if folder.hasSuffix("Archives") { return "Xcode archive" }
        if folder.hasSuffix("DeviceSupport") { return "Device support files" }
        if folder.hasSuffix("Caches") { return "Simulator cache" }
        return "Tool cache"
    }

    /// node_modules, .build, target and Pods folders in projects untouched for a while.
    static func staleBuildFolders(_ tree: ScanTree, _ ctx: ClassifierContext) -> [CleanupItem] {
        guard let home = tree.node(atPath: ctx.home) ?? (PathFormat.isInside(tree.rootPath, ctx.home) ? tree.root : nil)
        else { return [] }
        let cutoff = ctx.now.addingTimeInterval(-Double(ctx.staleProjectDays) * 86_400).timeIntervalSince1970
        var out: [CleanupItem] = []
        var stack: [DirNode] = [home]
        while let dir = stack.popLast() {
            for sub in dir.subdirs where !sub.isRemoved {
                if dir === home && (sub.name == "Library" || sub.name.hasPrefix(".")) { continue }
                if sub.isPackage { continue }
                if let marker = projectBuildFolders[sub.name], dir.fileIndex(named: marker) != nil {
                    let newest = dir.files.map(\.modified).max() ?? dir.modified
                    if newest < cutoff && sub.size >= 1_000_000 {
                        let project = dir.name
                        out.append(item(ItemRef(dir: sub), .developer,
                                        detail: "\(project) · untouched for \(days(since: newest, ctx)) days"))
                    }
                    continue
                }
                stack.append(sub)
            }
        }
        return out
    }

    static func aiModels(_ tree: ScanTree, _ ctx: ClassifierContext) -> [CleanupItem] {
        var out: [CleanupItem] = []
        for store in aiModelStores {
            guard let node = tree.node(atPath: ctx.home + "/" + store.path), node.size > 0 else { continue }
            let names = ollamaModelNames(node)
            let detail = names.isEmpty ? store.app : "\(store.app) · \(names.joined(separator: ", "))"
            out.append(CleanupItem(path: node.path, ref: ItemRef(dir: node), category: .aiModels, size: node.size,
                                   name: "\(store.app) models", detail: detail, modified: node.modifiedDate))
        }
        for folder in aiModelFolders {
            var level = children(tree, ctx.home + "/" + folder.path)
            for _ in 1..<folder.depth {
                level = level.filter(\.isDirectory).flatMap { children(tree, $0.path) }
            }
            for ref in level {
                if folder.app == "GPT4All" && !ref.isDirectory
                    && !gpt4allModelExtensions.contains(FileKinds.lowercasedExtension(ref.name)) { continue }
                out.append(item(ref, .aiModels, detail: folder.app))
            }
        }
        for ref in children(tree, ctx.home + "/.cache/huggingface/hub")
        where ref.isDirectory && (ref.name.hasPrefix("models--") || ref.name.hasPrefix("datasets--")) {
            let parts = ref.name.components(separatedBy: "--").dropFirst()
            let kind = ref.name.hasPrefix("datasets--") ? "Hugging Face dataset" : "Hugging Face"
            out.append(CleanupItem(path: ref.path, ref: ref, category: .aiModels, size: ref.size,
                                   name: parts.joined(separator: "/"), detail: kind, modified: ref.modified))
        }
        // Loose model files anywhere in the home folder.
        if let home = tree.node(atPath: ctx.home) ?? (PathFormat.isInside(tree.rootPath, ctx.home) ? tree.root : nil) {
            var stack = [home]
            while let dir = stack.popLast() {
                for f in tree.files(of: dir) where !f.removed && f.size >= ctx.aiStrayMinSize
                    && aiModelExtensions.contains(FileKinds.lowercasedExtension(f.name)) {
                    let ref = ItemRef(dir: dir, fileName: f.name)
                    out.append(item(ref, .aiModels, detail: "Model file"))
                }
                // Never inside app bundles or other packages (removing a file there breaks the app),
                // nor in the Trash.
                stack.append(contentsOf: dir.subdirs.filter {
                    !$0.isRemoved && !$0.isPackage && !(dir === home && $0.name == ".Trash")
                })
            }
        }
        return out
    }

    /// Model names from an Ollama store: manifests/<registry>/<namespace>/<model>/<tag>.
    static func ollamaModelNames(_ store: DirNode) -> [String] {
        guard let manifests = store.subdir(named: "manifests") else { return [] }
        var names: [String] = []
        for registry in manifests.subdirs {
            for namespace in registry.subdirs {
                for model in namespace.subdirs {
                    let tags = model.files.map(\.name)
                    names += tags.isEmpty ? [model.name] : tags.map { "\(model.name):\($0)" }
                }
            }
        }
        return names.sorted()
    }

    static func days(since seconds: Double, _ ctx: ClassifierContext) -> Int {
        max(0, Int(ctx.now.timeIntervalSince1970 - seconds) / 86_400)
    }

    static func oldDownloads(_ tree: ScanTree, _ ctx: ClassifierContext) -> [CleanupItem] {
        let cutoff = ctx.now.addingTimeInterval(-Double(ctx.oldDownloadDays) * 86_400)
        var out: [CleanupItem] = []
        for ref in children(tree, ctx.home + "/Downloads") {
            let ext = FileKinds.lowercasedExtension(ref.name)
            if installerExtensions.contains(ext) {
                out.append(item(ref, .downloads, detail: "Installer"))
                continue
            }
            let lastUsed = lastUsedDate(ref)
            if lastUsed < cutoff {
                let d = days(since: lastUsed.timeIntervalSince1970, ctx)
                out.append(item(ref, .downloads, detail: d >= 365 ? "Not opened for over a year"
                                                                  : "Not opened for \(d / 30) months"))
            }
        }
        return out
    }

    /// Latest modification of an item; for a folder, of anything inside it.
    static func newestModification(_ ref: ItemRef) -> Date {
        guard ref.isDirectory else { return ref.modified }
        var stack = [ref.dir]
        var newest = ref.dir.modified
        while let d = stack.popLast() {
            newest = max(newest, d.modified)
            for f in d.files where f.modified > newest { newest = f.modified }
            stack.append(contentsOf: d.subdirs)
        }
        return Date(timeIntervalSince1970: newest)
    }

    /// Most recent of modified, added-to-folder and last-opened dates; folders also count their newest file.
    static func lastUsedDate(_ ref: ItemRef) -> Date {
        var latest = newestModification(ref)
        let url = URL(fileURLWithPath: ref.path)
        if let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentAccessDateKey]) {
            for d in [v.addedToDirectoryDate, v.contentAccessDate].compactMap({ $0 }) where d > latest { latest = d }
        }
        return latest
    }

    /// Drops items nested inside another item. For identical paths the first category in priority order wins.
    public static func removingOverlaps(_ items: [CleanupItem]) -> [CleanupItem] {
        let priority = Dictionary(uniqueKeysWithValues: CleanupCategory.allCases.enumerated().map { ($1, $0) })
        let ordered = items.sorted {
            ($0.path.count, priority[$0.category] ?? 0) < ($1.path.count, priority[$1.category] ?? 0)
        }
        var claimed = Set<String>()
        var out: [CleanupItem] = []
        for i in ordered where !claimed.contains(i.path) {
            var ancestor = PathFormat.parent(of: i.path)
            var nested = false
            while ancestor.count > 1 {
                if claimed.contains(ancestor) { nested = true; break }
                ancestor = PathFormat.parent(of: ancestor)
            }
            guard !nested else { continue }
            claimed.insert(i.path)
            out.append(i)
        }
        return out
    }

    static let systemRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores"]

    public static func keptBreakdown(_ tree: ScanTree, items: [CleanupItem], _ ctx: ClassifierContext) -> [KeptCategory: Int64] {
        let appNodes = ["/Applications", ctx.home + "/Applications"].compactMap { tree.node(atPath: $0) }
        let systemNodes = tree.isVolumeScan ? systemRoots.compactMap { tree.node(atPath: $0) } : []
        let appsSize = appNodes.reduce(0) { $0 + $1.size }
        let appsMedia = appNodes.reduce(0) { $0 + $1.mediaSize }
        let systemSize = systemNodes.reduce(0) { $0 + $1.size }
        let systemMedia = systemNodes.reduce(0) { $0 + $1.mediaSize }

        var cleanable: Int64 = 0, cleanableMedia: Int64 = 0, cleanableInSystem: Int64 = 0
        for i in items {
            cleanable += i.size
            let inSystem = systemNodes.contains { PathFormat.isInside(i.path, $0.path) }
            if inSystem { cleanableInSystem += i.size } else { cleanableMedia += i.ref?.mediaSize ?? 0 }
        }
        let systemKept = max(0, systemSize - cleanableInSystem)
        let media = max(0, tree.root.mediaSize - appsMedia - systemMedia - cleanableMedia)
        let documents = max(0, tree.root.size - cleanable - appsSize - systemKept - media)
        return [.media: media, .apps: appsSize, .documents: documents,
                .system: systemKept + tree.unaccountedBytes]
    }
}
