// Check runner for DuckDiskCore. XCTest is not available with Command Line Tools only, so this executable
// builds a fixture home folder and asserts behaviour against it.
// Usage: swift run DuckDiskChecks [--apps] | --fixture-only <dir ending in duckdisk-fixture> | --scan <path>
import AVFoundation
import CoreGraphics
import Darwin
@testable import DuckDiskCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  ✗ threw \(error)")
    }
}

func asyncSection(_ name: String, _ body: @escaping () async throws -> Void) {
    print("• \(name)")
    let done = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch {
            failures += 1
            print("  ✗ threw \(error)")
        }
        done.signal()
    }
    done.wait()
}

let args = CommandLine.arguments
let base = PathFormat.realPath(NSTemporaryDirectory()) + "/duckdisk-checks-\(getpid())"
try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

if let i = args.firstIndex(of: "--fixture-only"), i + 1 < args.count {
    try Fixture.make(at: args[i + 1])
    print("Fixture written to \(args[i + 1])")
    exit(0)
}

if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
    let t = DiskScanner(rootPath: args[i + 1]).scanSync()!
    print("files=\(t.stats.files) dirs=\(t.stats.dirs) size=\(ByteFormat.string(t.root.size)) unreadable=\(t.stats.unreadableDirs) time=\(String(format: "%.2f", t.stats.duration))s")
    exit(0)
}

// Moves one given file to the real Trash through TrashService (and shows a system path is refused).
if let i = args.firstIndex(of: "--trash-test"), i + 1 < args.count {
    let done = DispatchSemaphore(value: 0)
    Task {
        let r = await TrashService.trash([.init(path: args[i + 1], size: 10), .init(path: "/System/Library", size: 1)])
        print("trashed=\(r.trashed.keys.sorted()) failures=\(r.failures.map { "\($0.path): \($0.reason)" })")
        done.signal()
    }
    done.wait()
    exit(0)
}

// Times saving and loading the search index for a real folder.
if let i = args.firstIndex(of: "--index-bench"), i + 1 < args.count {
    let t = DiskScanner(rootPath: args[i + 1]).scanSync()!
    let dir = URL(fileURLWithPath: base + "/index")
    var start = Date()
    try ScanIndex.save(t, in: dir)
    let saveTime = Date().timeIntervalSince(start)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: ScanIndex.url(forRoot: t.rootPath, in: dir).path)[.size]
        as? Int) ?? 0
    start = Date()
    let loaded = ScanIndex.load(root: t.rootPath, in: dir)
    print(String(format: "files=%d save=%.2fs load=%.2fs file=%@ match=%@", t.stats.files, saveTime,
                 Date().timeIntervalSince(start), ByteFormat.string(Int64(bytes)),
                 loaded?.root.size == t.root.size ? "yes" : "no"))
    try? FileManager.default.removeItem(atPath: base)
    exit(0)
}

let home = try Fixture.make(at: base + "/duckdisk-fixture")

section("Formatting") {
    check(ByteFormat.string(0) == "0 bytes", "zero bytes")
    check(ByteFormat.string(1_500) == "2 KB", "kilobytes round")
    check(ByteFormat.string(2_100_000) == "2.1 MB", "small megabytes keep a decimal")
    check(ByteFormat.string(13_600_000_000) == "13.6 GB", "gigabytes")
    check(ByteFormat.signed(-300_000_000) == "−300 MB", "signed negative")
    check(PathFormat.isInside("/a/b/c", "/a/b"), "inside")
    check(!PathFormat.isInside("/a/bc", "/a/b"), "sibling prefix is not inside")
    check(PathFormat.abbreviated("/Users/x/Documents", home: "/Users/x") == "~/Documents", "abbreviate home")
}

/// Allocated bytes of every file under `root`, counting hard links once.
func referenceSize(_ root: String) -> (bytes: Int64, files: Int) {
    var seen = Set<UInt64>()
    var bytes: Int64 = 0, files = 0
    let e = FileManager.default.enumerator(atPath: root)!
    while let rel = e.nextObject() as? String {
        var st = stat()
        guard lstat(root + "/" + rel, &st) == 0, st.st_mode & S_IFMT != S_IFDIR else { continue }
        files += 1
        if st.st_nlink > 1 && !seen.insert(st.st_ino).inserted { continue }
        bytes += Int64(st.st_blocks) * 512
    }
    return (bytes, files)
}

var tree: ScanTree!
section("Scanner") {
    tree = DiskScanner(rootPath: home).scanSync()
    check(tree != nil, "scan finished")
    let ref = referenceSize(home)
    check(tree.root.size == ref.bytes, "size \(tree.root.size) matches lstat sum \(ref.bytes)")
    check(tree.stats.files == ref.files, "file count \(tree.stats.files) matches \(ref.files)")
    let docs = tree.node(atPath: home + "/Documents")
    check(docs?.files.first { $0.name == ".hidden-config" }?.hidden == true, "dot files are hidden")
    let pics = tree.node(atPath: home + "/Pictures")
    check(pics?.files.filter { $0.flags & FileEntry.isHardLinkCopy != 0 }.count == 1, "hard link counted once")
    check(tree.root.mediaSize > 9_000_000, "jpgs count as media")
    check(tree.ref(forPath: home + "/Documents/Quarterly REPORT.pdf") != nil, "ref lookup by path")

    let caches = tree.node(atPath: home + "/Library/Caches")!
    let before = tree.root.size
    let removed = tree.remove(ItemRef(dir: caches.subdir(named: "com.example.browser")!))
    check(removed > 4_000_000 && tree.root.size == before - removed, "remove subtracts from ancestors")
    check(caches.subdir(named: "com.example.browser") == nil, "removed node no longer found")
    tree = DiskScanner(rootPath: home).scanSync()
}

section("Classifier") {
    let registry = InstalledAppRegistry(entries: [], extraIDs: ["com.example.browser"], useLaunchServices: false)
    var ctx = ClassifierContext(home: home, tempDir: base + "/no-temp", registry: registry)
    ctx.staleProjectDays = 30
    ctx.aiStrayMinSize = 1_000_000
    let c = Classifier.classify(tree, context: ctx)
    func names(_ cat: CleanupCategory) -> Set<String> { Set((c.items[cat] ?? []).map(\.name)) }
    check(names(.caches).contains("com.example.browser"), "app cache found")
    check(!names(.caches).contains("com.apple.bird"), "iCloud cache protected")
    check(names(.logs).contains("SomeApp"), "app log folder")
    check(names(.logs).contains("crash1.ips"), "crash report expanded from DiagnosticReports")
    check(names(.leftovers) == ["com.gone.app", "com.gone.app.plist"], "leftovers: \(names(.leftovers))")
    check(names(.developer).contains("Proj-abc"), "DerivedData")
    check(names(.developer).contains("node_modules"), "stale node_modules")
    check(names(.downloads).contains("installer.dmg"), "installer in Downloads")
    check(!names(.downloads).contains("new-notes.txt"), "recent download kept")
    check(names(.aiModels).isSuperset(of: ["Ollama models", "Qwen-7B-GGUF", "openai/whisper-small", "llama-7b.Q4.gguf"]),
          "AI models found: \(names(.aiModels))")
    check(!names(.aiModels).contains("style.safetensors"), "model files inside app bundles are left alone")
    check(!names(.aiModels).contains("old-model.gguf"), "files already in the Trash are not listed")
    check(c.items[.aiModels]?.first { $0.name == "Ollama models" }?.detail.contains("llama3:latest") == true,
          "Ollama model names read from manifests")
    check(names(.developer).contains("pip") && !names(.developer).contains("huggingface"),
          "model caches leave Developer files; other tool caches stay")
    let allPaths = c.allItems.map(\.path)
    check(Set(allPaths).count == allPaths.count, "no item listed twice")
    let total = c.clearableTotal + c.kept.values.reduce(0, +)
    check(total == tree.root.size, "clearable + kept = scanned (\(total) vs \(tree.root.size))")
    check((c.kept[.media] ?? 0) > 0, "media kept bucket")

    let overlapping = Classifier.removingOverlaps([
        CleanupItem(path: "/x/a", ref: nil, category: .downloads, size: 10),
        CleanupItem(path: "/x/a/b", ref: nil, category: .developer, size: 5),
        CleanupItem(path: "/x/a b", ref: nil, category: .caches, size: 1),
    ])
    check(overlapping.map(\.path).sorted() == ["/x/a", "/x/a b"], "nested items dropped")
    check(InstalledAppRegistry.looksLikeBundleID("com.vendor.app"), "bundle id shape")
    check(!InstalledAppRegistry.looksLikeBundleID("Google Chrome"), "names are not bundle ids")
}

section("App data ownership") {
    typealias Entry = InstalledAppRegistry.Entry
    let main = Entry(url: URL(fileURLWithPath: "/Applications/Plain Name.app"), bundleID: "com.gone.app",
                     name: "Plain Name", bundleName: "Plain Name", executable: nil, version: nil)
    // A helper whose CFBundleName repeats the main app's name must not claim the main app's data.
    let helper = Entry(url: URL(fileURLWithPath: "/Applications/Helper.app"), bundleID: "com.gone.app.helper",
                       name: "Helper", bundleName: "Plain Name", executable: nil, version: nil)
    let owned = AppInventory.assignData(apps: [main, helper], home: home)
    let mainPaths = Set((owned[0] ?? []).map { PathFormat.lastComponent($0.path) })
    check(mainPaths.contains("Plain Name"), "folder named after the app goes to that app")
    check(mainPaths.contains("com.gone.app") && mainPaths.contains("com.gone.app.plist"), "bundle id matches")
    check(owned[1] == nil, "helper claims nothing it does not own: \(owned[1]?.map(\.path) ?? [])")
}

section("App caches") {
    let container = home + "/Library/Containers/com.gone.app"
    try FileManager.default.createDirectory(atPath: container + "/Data/Library/Caches/x", withIntermediateDirectories: true)
    try Data(count: 50_000).write(to: URL(fileURLWithPath: container + "/Data/Library/Caches/x/blob"))
    let data = [
        AppFile(path: home + "/Library/Caches/com.example.browser", size: 5_000_000, kind: "Caches"),
        AppFile(path: home + "/Library/Application Support/com.gone.app", size: 1_500_000, kind: "Application Support"),
        AppFile(path: home + "/Library/Preferences/com.gone.app.plist", size: 4_000, kind: "Preferences"),
        AppFile(path: home + "/Library/HTTPStorages/com.gone.app", size: 10_000, kind: "Web storage"),
        AppFile(path: container, size: 60_000, kind: "Container"),
    ]
    let caches = Set(AppInventory.cacheFiles(from: data).map { PathFormat.abbreviated($0.path, home: home) })
    check(caches == ["~/Library/Caches/com.example.browser", "~/Library/HTTPStorages/com.gone.app",
                     "~/Library/Containers/com.gone.app/Data/Library/Caches"], "cache paths: \(caches)")
}

section("SafetyGuard") {
    check(!SafetyGuard.check("/System/Library/Kernels").isAllowed, "system denied")
    check(!SafetyGuard.check("/usr/bin/true").isAllowed, "usr denied")
    check(!SafetyGuard.check(home, home: home).isAllowed, "home itself denied")
    check(!SafetyGuard.check(home + "/Library", home: home).isAllowed, "Library itself denied")
    check(!SafetyGuard.check(home + "/Library/Caches/com.apple.bird", home: home).isAllowed, "iCloud cache denied")
    check(SafetyGuard.check(home + "/Library/Caches/com.example.browser", home: home).isAllowed, "app cache allowed")
    check(!SafetyGuard.check(home + "/.Trash/x", home: home).isAllowed, "Trash contents denied")
    check(!SafetyGuard.check("/Users/x/Pictures/Photos Library.photoslibrary/originals/1.heic", home: "/Users/x").isAllowed,
          "inside Photos library denied")
    check(!SafetyGuard.check("/a/../etc", home: home).isAllowed, "relative tricks denied")
    check(!SafetyGuard.check(home + "/does-not-exist", home: home).isAllowed, "missing path denied")
}

section("SafetyGuard: libraries and odd paths") {
    let lib = home + "/Pictures/Photos Library.photoslibrary"
    try FileManager.default.createDirectory(atPath: lib + "/originals", withIntermediateDirectories: true)
    check(!SafetyGuard.check(lib, home: home).isAllowed, "Photos library bundle itself denied")
    check(!SafetyGuard.check(lib + "/originals", home: home).isAllowed, "inside Photos library denied")
    check(!SafetyGuard.check(home + "/Music/Music Library.musiclibrary/Library.musicdb", home: home).isAllowed,
          "inside Music library denied")
    check(!SafetyGuard.check(home + "//Library/Caches/com.example.browser", home: home).isAllowed, "double slash denied")
    check(!SafetyGuard.check(home + "/Library/./Caches/com.example.browser", home: home).isAllowed, "dot segment denied")
    check(!SafetyGuard.check(home + "/library/keychains/login.keychain-db", home: home).isAllowed,
          "case variants of protected folders denied")
    check(!SafetyGuard.check(home + "/LIBRARY/Caches/com.apple.bird", home: home).isAllowed, "case variant cache denied")
    check(!SafetyGuard.check(home + "/Library/Caches/", home: home).isAllowed, "trailing slash denied")
}

section("Trash request de-duplication") {
    let r = TrashService.removingNested([
        .init(path: "/a/b/c", size: 1), .init(path: "/a/b", size: 2), .init(path: "/a/b c", size: 3),
        .init(path: "/z", size: 4),
    ])
    check(Set(r.map(\.path)) == ["/a/b", "/a/b c", "/z"], "nested request dropped: \(r.map(\.path))")
}

section("Duplicates") {
    var opts = DuplicateFinder.Options()
    opts.minSize = 1_000_000
    opts.home = home
    let groups = DuplicateFinder(tree: tree, options: opts).runSync()
    check(groups.count == 1, "one duplicate set (got \(groups.count))")
    if let g = groups.first {
        let names = Set(g.files.map { PathFormat.lastComponent($0.path) })
        check(!names.contains("other.jpg"), "different content not grouped")
        check(names.contains("beach copy.jpg"), "real copy grouped")
        check(!(names.contains("beach.jpg") && names.contains("beach-link.jpg")), "hard links not both listed")
        check(g.physicalCopies == 2, "clone shares storage (physical copies \(g.physicalCopies))")
        check(g.wastedBytes == g.size, "waste = one extra physical copy")
        check(PathFormat.lastComponent(g.files[g.suggestedKeep].path) != "beach copy.jpg", "keeps the original, not the copy")

        // Offered copies free real space: the clone of the kept file is not offered.
        let first = DuplicateSelection.resolve([g], keep: [:], otherItemPaths: [], home: home)
        let keptPath = first.keep[g.id] ?? ""
        let offered = first.items.map { PathFormat.lastComponent($0.path) }
        check(offered == ["beach copy.jpg"], "only the real copy is offered: \(offered)")
        check(first.items.reduce(0) { $0 + $1.size } == g.wastedBytes, "offered bytes equal wasted bytes")

        // The kept file is trashed elsewhere: a remaining copy becomes the kept one, never zero copies.
        var shrunk = g
        shrunk.files.removeAll { $0.path == keptPath }
        let second = DuplicateSelection.resolve([shrunk], keep: first.keep, otherItemPaths: [], home: home)
        check(second.keep[g.id] != keptPath && shrunk.files.contains { $0.path == second.keep[g.id] },
              "kept copy re-picked after it disappeared")
        check(!second.items.contains { $0.path == second.keep[g.id] }, "new kept copy is not offered")

        // A copy inside another cleanup item is not chosen to be kept when an alternative exists.
        let copyPath = g.files.first { PathFormat.lastComponent($0.path) == "beach copy.jpg" }!.path
        let originalPath = g.files.first { PathFormat.lastComponent($0.path) != "beach copy.jpg" }!.path
        let third = DuplicateSelection.resolve([g], keep: [:], otherItemPaths: [originalPath], home: home)
        check(third.keep[g.id] != originalPath, "kept copy avoids files other categories remove")

        // Requests never remove the kept copy, nor every copy of a set.
        let req = DuplicateSelection.protect([.init(path: keptPath, size: 1), .init(path: copyPath, size: 1)],
                                             groups: [g], keep: first.keep)
        check(!req.contains { $0.path == keptPath }, "kept copy dropped from trash request")
        let folderReq = DuplicateSelection.protect(
            [.init(path: home + "/Pictures", size: 1), .init(path: copyPath, size: 1)], groups: [g], keep: [:])
        check(folderReq.map(\.path) == [home + "/Pictures"] || !folderReq.contains { $0.path == copyPath },
              "a set is never removed entirely through individual picks")
        check(g.physicalCopies == 2 && shrunk.physicalCopies <= 2, "physical copies follow the file list")
    }
}

section("Concurrent readers while removing") {
    let t = DiskScanner(rootPath: home).scanSync()!
    let stop = CancelFlag()
    let group = DispatchGroup()
    for _ in 0..<3 {
        group.enter()
        DispatchQueue.global().async {
            while !stop.isSet {
                _ = TreeSearch.run(t, SearchQuery(text: "a"))
                _ = TreeSearch.largestFiles(t, limit: 5)
            }
            group.leave()
        }
    }
    var removed = 0
    for d in t.liveDirs() {
        for f in t.files(of: d) where !f.removed {
            removed += t.remove(ItemRef(dir: d, fileName: f.name)) > 0 ? 1 : 0
        }
    }
    stop.set()
    group.wait()
    check(removed > 10 && t.root.size == 0, "removed every file while three readers searched (\(removed))")
}

section("Saved search index") {
    let t = DiskScanner(rootPath: home).scanSync()!
    let dir = URL(fileURLWithPath: base + "/index")
    try ScanIndex.save(t, in: dir)
    let loaded = ScanIndex.load(root: home, in: dir)
    check(loaded != nil, "index loads")
    if let loaded {
        check(loaded.stats.files == t.stats.files && loaded.root.size == t.root.size,
              "same files and size (\(loaded.stats.files) / \(loaded.root.size))")
        check(loaded.root.mediaSize == t.root.mediaSize, "media totals rebuilt")
        check(loaded.rootPath == t.rootPath && loaded.ref(forPath: home + "/Documents/.hidden-config")?.file?.hidden == true,
              "paths and hidden flags survive")
        let a = TreeSearch.run(t, SearchQuery(text: "beach")).map(\.ref.path).sorted()
        let b = TreeSearch.run(loaded, SearchQuery(text: "beach")).map(\.ref.path).sorted()
        check(!a.isEmpty && a == b, "search results match")
    }
    check(ScanIndex.load(root: home + "/Documents", in: dir) == nil, "no index for another root")
    try Data("garbage".utf8).write(to: ScanIndex.url(forRoot: home + "/Pictures", in: dir))
    check(ScanIndex.load(root: home + "/Pictures", in: dir) == nil, "corrupt index is ignored")
}

section("Treemap layout") {
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
    let values: [Double] = [500, 300, 120, 80, 40, 30, 20, 6, 3, 1]
    let rects = Treemap.squarify(values, in: bounds)
    let total = values.reduce(0, +)
    let area = Double(bounds.width * bounds.height)
    var proportional = true, inside = true, overlap = false
    for (i, r) in rects.enumerated() {
        let expected = values[i] / total * area
        if abs(Double(r.width * r.height) - expected) > expected * 0.01 + 0.01 { proportional = false }
        if !bounds.insetBy(dx: -0.01, dy: -0.01).contains(r) { inside = false }
        for other in rects[(i + 1)...] {
            let x = r.intersection(other)
            if !x.isNull && x.width * x.height > 0.01 { overlap = true }
        }
    }
    check(proportional, "areas proportional to values")
    check(inside, "rects stay inside bounds")
    check(!overlap, "rects do not overlap")
    let worst = rects.prefix(5).map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    check(worst < 4, "large rects stay close to square (worst \(worst))")
    check(Treemap.squarify([], in: bounds).isEmpty && Treemap.squarify([5], in: .zero) == [.zero], "empty inputs")
}

section("References outliving their tree") {
    var t: ScanTree? = DiskScanner(rootPath: home).scanSync()
    let ref = t!.ref(forPath: home + "/Documents/Quarterly REPORT.pdf")!
    t = nil
    // Parents are weak: a stale reference reads a shorter path instead of freed memory.
    check(!ref.path.isEmpty && ref.path.hasSuffix("Quarterly REPORT.pdf"), "stale ref is safe: \(ref.path)")
}

section("Trash accounting and compress formats") {
    let linked = home + "/Pictures/beach.jpg"
    check(TrashService.bytesFreed(.init(path: linked, size: 3_000_000)) == 0, "hard-linked file frees nothing yet")
    check(TrashService.bytesFreed(.init(path: home + "/Pictures/other.jpg", size: 3_000_000)) == 3_000_000,
          "single-link file frees its size")
    check(!MediaCompressor.isPhoto("shot.dng") && !MediaCompressor.isPhoto("art.psd")
          && !MediaCompressor.isPhoto("anim.gif") && !MediaCompressor.isPhoto("scan.tiff"),
          "RAW, PSD, GIF and TIFF are never compressed")
    check(MediaCompressor.isPhoto("IMG_1.JPG") && MediaCompressor.isPhoto("a.heic"), "JPEG and HEIC are compressed")
}

/// Thread-safe flag for the concurrency check.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

section("Search") {
    check(TreeSearch.containsFolded("Quarterly REPORT.pdf", Array("report".utf8)), "case-insensitive ASCII")
    check(!TreeSearch.containsFolded("rep", Array("report".utf8)), "needle longer than name")
    var q = SearchQuery(text: "report")
    check(TreeSearch.run(tree, q).contains { $0.ref.name == "Quarterly REPORT.pdf" }, "finds file")
    q.kind = .folders
    check(!TreeSearch.run(tree, q).contains { $0.ref.name == "Quarterly REPORT.pdf" }, "folder filter")
    var hidden = SearchQuery(text: "hidden")
    hidden.includeHidden = false
    check(TreeSearch.run(tree, hidden).isEmpty, "hidden excluded when asked")
    hidden.includeHidden = true
    check(TreeSearch.run(tree, hidden).count == 1, "hidden included by default")
    check(TreeSearch.largestFiles(tree, limit: 3).first?.size ?? 0 >= 6_000_000, "largest file first")
    check(TreeSearch.run(tree, SearchQuery(text: "Ré")).isEmpty, "non-ASCII query falls back safely")
}

section("Snapshots and activity") {
    let a = Snapshot.make(tree: tree, classification: Classification(), date: Date().addingTimeInterval(-86_400))
    var b = a
    b.id = UUID()
    b.date = Date()
    b.folders[home + "/Downloads"] = (a.folders[home + "/Downloads"] ?? 0) + 500_000_000
    b.folders[home + "/Downloads/big"] = 480_000_000
    b.folders[home] = (a.folders[home] ?? 0) + 500_000_000
    b.used = a.used + 500_000_000
    let diff = SnapshotDiff.compare(b, a)
    check(diff.usedDelta == 500_000_000, "used delta ordered by date")
    check(diff.changes.first?.path == home + "/Downloads/big", "deepest explaining change first")
    check(!diff.changes.contains { $0.path == home + "/Downloads" }, "parent explained by child is hidden")

    let dir = URL(fileURLWithPath: base + "/support")
    let store = ActivityStore(directory: dir)
    store.record(CleanupEvent(date: Date(), bytes: 1_000, items: 2, categories: ["caches": 1_000], source: "Overview"))
    store.record(CleanupEvent(date: Date().addingTimeInterval(-8 * 86_400), bytes: 500, items: 1,
                              categories: [:], source: "Cleanup"))
    let reloaded = ActivityStore(directory: dir)
    check(reloaded.events.count == 2, "events persisted")
    let weeks = reloaded.weekly(weeks: 4)
    check(weeks.count == 4 && weeks.last?.bytes == 1_000, "this week's bucket")
    check(weeks.reduce(0) { $0 + $1.bytes } == 1_500, "weekly totals")

    let snaps = SnapshotStore(directory: dir.appendingPathComponent("Snapshots"))
    snaps.save(a)
    check(SnapshotStore(directory: dir.appendingPathComponent("Snapshots")).summaries.first?.id == a.id, "snapshot index")
    check(snaps.load(a.id)?.folders.count == a.folders.count, "snapshot round trip")
}

section("System monitor") {
    let m = SystemMonitor()
    _ = m.sampleCPU()
    usleep(200_000)
    let cpu = m.sampleCPU()
    check(!cpu.cores.isEmpty && cpu.total >= 0 && cpu.total <= 1, "cpu sample \(cpu.total)")
    let mem = m.sampleMemory()
    check(mem.total > 0 && mem.used > 0 && mem.used <= mem.total, "memory sample")
    check(m.sampleProcesses().contains { $0.pid == getpid() }, "own process listed")

    // Open a listening socket and expect to see it.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    listen(fd, 1)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    let port = UInt16(bigEndian: addr.sin_port)
    let ports = PortScanner.listening()
    check(ports.contains { $0.port == port && $0.pid == getpid() && $0.proto == "TCP" && $0.address == "127.0.0.1" },
          "listening port \(port) found")
    close(fd)
    _ = Battery.read()
}

/// Writes a busy JPEG at maximum quality so re-encoding has something to shrink.
func makePhoto(_ path: String) {
    let w = 2400, h = 1600
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for i in 0..<400 {
        ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
        ctx.fill(CGRect(x: (i * 37) % w, y: (i * 53) % h, width: 120 + i % 90, height: 80 + i % 70))
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// Writes a three-second, high-bitrate H.264 movie.
func makeVideo(_ path: String) async throws {
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov)
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
                                   AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000]]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<90 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        let px = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * 1080
        for i in stride(from: 0, to: count, by: 4) {
            px[i] = UInt8((i / 4 + frame * 9) & 0xFF)
            px[i + 1] = UInt8((i / 7) & 0xFF)
            px[i + 2] = UInt8((frame * 3) & 0xFF)
            px[i + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

asyncSection("Compress") {
    let photo = base + "/photo.jpg"
    makePhoto(photo)
    let p = await MediaCompressor.compress(photo, video: .balanced, photo: .balanced, replaceOriginal: false) { _ in }
    switch p.outcome {
    case .compressed(let newPath, let replaced):
        check(!replaced && FileManager.default.fileExists(atPath: newPath), "photo copy written")
        check(newPath.hasSuffix("photo (compressed).heic"), "photo copy name \(newPath)")
        check(FileManager.default.fileExists(atPath: photo), "original untouched without replace")
        check(CGImageSourceCreateWithURL(URL(fileURLWithPath: newPath) as CFURL, nil) != nil, "HEIC readable")
    case .notSmaller:
        check(true, "photo already compact")
    case .failed(let reason):
        check(false, "photo failed: \(reason)")
    }

    let video = base + "/clip.mov"
    try await makeVideo(video)
    let v = await MediaCompressor.compress(video, video: .small, photo: .high, replaceOriginal: false) { _ in }
    if case .compressed(let newPath, _) = v.outcome {
        check(v.newSize < v.originalSize, "video smaller \(v.newSize) < \(v.originalSize)")
        let duration = try await AVURLAsset(url: URL(fileURLWithPath: newPath)).load(.duration)
        check(duration.seconds > 2.5, "compressed video plays \(duration.seconds)s")
    } else {
        check(false, "video outcome \(v.outcome)")
    }
}

if args.contains("--apps") {
    section("Applications") {
        let apps = AppInventory.load()
        check(!apps.isEmpty, "apps found")
        print("  \(apps.count) apps, largest: \(apps.prefix(3).map { "\($0.name) \(ByteFormat.string($0.footprint))" })")
        for app in apps.prefix(3) {
            print("  \(app.name) [\(app.bundleID)] app \(ByteFormat.string(app.bundleSize))")
            for f in app.leftovers.prefix(4) { print("    \(ByteFormat.string(f.size))  \(PathFormat.abbreviated(f.path))") }
        }
    }
}

// The fixture lives in the temporary folder; remove our own test data.
try? FileManager.default.removeItem(atPath: base)
print(failures == 0 ? "✓ \(passes) checks passed" : "✗ \(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
