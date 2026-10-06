import Foundation
import CryptoKit
import Darwin

public struct DuplicateFile: Identifiable, Hashable, @unchecked Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date
    public let ref: ItemRef?
    /// APFS clone id; files sharing one occupy the same blocks.
    public let cloneID: UInt64?

    public static func == (a: DuplicateFile, b: DuplicateFile) -> Bool { a.path == b.path }
    public func hash(into h: inout Hasher) { h.combine(path) }
}

public struct DuplicateGroup: Identifiable, Sendable {
    /// Lowest path in the group; stable for the lifetime of a scan.
    public let id: String
    /// Allocated bytes of one copy.
    public let size: Int64
    public var files: [DuplicateFile]
    /// Index into `files` of the copy suggested to keep.
    public var suggestedKeep: Int

    /// Copies that occupy their own blocks (APFS clones share storage and count once).
    public var physicalCopies: Int {
        var clones = Set<UInt64>()
        var unique = 0
        for f in files {
            if let c = f.cloneID { clones.insert(c) } else { unique += 1 }
        }
        return clones.count + unique
    }

    public var wastedBytes: Int64 { size * Int64(max(0, physicalCopies - 1)) }
    public var name: String { files.first.map { PathFormat.lastComponent($0.path) } ?? "" }
}

/// Finds files with identical contents: group by size, then by a hash of the first and last 64 KB,
/// then by a full SHA-256. Hard links and APFS clones are not reported as wasted space.
public final class DuplicateFinder: @unchecked Sendable {
    public struct Options: Sendable {
        public var minSize: Int64 = 1_000_000
        public var home: String = NSHomeDirectory()
        public init() {}
    }

    public struct Progress: Sendable {
        public var stage: String = "Collecting files"
        public var done: Int64 = 0
        public var total: Int64 = 0
        public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        public init(stage: String = "Collecting files", done: Int64 = 0, total: Int64 = 0) {
            self.stage = stage
            self.done = done
            self.total = total
        }
    }

    struct Candidate {
        let path: String
        let size: Int64
        let modified: Double
        let ref: ItemRef?
    }

    private let options: Options
    private var candidates: [Candidate] = []
    private let lock = NSLock()
    private var state = Progress()
    private var cancelled = false

    static let skippedDirNames: Set<String> = ["node_modules", ".git", ".svn", "Pods", ".build", "DerivedData"]
    static let skippedRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt",
                               "/Applications", "/cores", "/dev"]

    /// Collects candidates from the tree. Must run while the tree is not being mutated (it is fast).
    public init(tree: ScanTree, options: Options = Options()) {
        self.options = options
        candidates = Self.collect(tree, options)
    }

    /// Builds a finder over explicit paths (used by checks and folder pickers).
    public init(paths: [String], options: Options = Options()) {
        self.options = options
        candidates = paths.compactMap { p in
            var st = stat()
            guard stat(p, &st) == 0, st.st_size >= options.minSize else { return nil }
            return Candidate(path: p, size: Int64(st.st_blocks) * 512, modified: Double(st.st_mtimespec.tv_sec),
                             ref: nil)
        }
    }

    public var progress: Progress {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func update(_ body: (inout Progress) -> Void) {
        lock.lock(); body(&state); lock.unlock()
    }

    static func collect(_ tree: ScanTree, _ options: Options) -> [Candidate] {
        let homeLibrary = options.home + "/Library"
        var out: [Candidate] = []
        var stack = [tree.root]
        while let dir = stack.popLast() {
            for f in tree.files(of: dir) where !f.removed && !f.hidden && f.flags & FileEntry.isHardLinkCopy == 0
                && f.size >= options.minSize {
                let ref = ItemRef(dir: dir, fileName: f.name)
                out.append(Candidate(path: ref.path, size: f.size, modified: f.modified, ref: ref))
            }
            for sub in dir.subdirs where !sub.isRemoved && !sub.isPackage && !sub.isHidden
                && sub.flags & DirNode.isMediaLibrary == 0 && !skippedDirNames.contains(sub.name) {
                let path = sub.path
                if path == homeLibrary || skippedRoots.contains(path) { continue }
                stack.append(sub)
            }
        }
        return out
    }

    public func run() async -> [DuplicateGroup] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: self.runSync())
            }
        }
    }

    public func runSync() -> [DuplicateGroup] {
        // 1. Same allocated size.
        var bySize: [Int64: [Candidate]] = [:]
        for c in candidates { bySize[c.size, default: []].append(c) }
        var groups = bySize.values.filter { $0.count > 1 }

        // 2. Same logical length, distinct inodes.
        groups = groups.flatMap { group -> [[Candidate]] in
            var byLength: [Int64: [Candidate]] = [:]
            var inodes = Set<String>()
            for c in group {
                var st = stat()
                guard stat(c.path, &st) == 0, inodes.insert("\(st.st_dev):\(st.st_ino)").inserted else { continue }
                byLength[Int64(st.st_size), default: []].append(c)
            }
            return byLength.values.filter { $0.count > 1 }
        }
        if isCancelled { return [] }

        // 3. Same head and tail.
        let partialTotal = groups.reduce(0) { $0 + $1.count }
        update { $0 = Progress(stage: "Comparing", done: 0, total: Int64(partialTotal)) }
        groups = regroup(groups, weight: { _ in 1 }) { Self.partialHash($0.path) }
        if isCancelled { return [] }

        // 4. Same full contents.
        let fullTotal = groups.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.size } }
        update { $0 = Progress(stage: "Matching contents", done: 0, total: fullTotal) }
        groups = regroup(groups, weight: { $0.size }) { [unowned self] in Self.fullHash($0.path) { self.isCancelled } }
        if isCancelled { return [] }

        return groups.compactMap(makeGroup).sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// Splits every group by `key`, hashing files in parallel. Files whose key fails are dropped.
    private func regroup(_ groups: [[Candidate]], weight: @escaping (Candidate) -> Int64,
                         key: @escaping (Candidate) -> String?) -> [[Candidate]] {
        let flat = groups.enumerated().flatMap { gi, g in g.map { (gi, $0) } }
        var keys = [String?](repeating: nil, count: flat.count)
        let keysLock = NSLock()
        let workers = 6
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            var i = w
            while i < flat.count {
                if isCancelled { return }
                let k = key(flat[i].1)
                keysLock.lock(); keys[i] = k; keysLock.unlock()
                let wgt = weight(flat[i].1)
                update { $0.done += wgt }
                i += workers
            }
        }
        var buckets: [String: [Candidate]] = [:]
        for (i, entry) in flat.enumerated() {
            guard let k = keys[i] else { continue }
            buckets["\(entry.0)|\(k)", default: []].append(entry.1)
        }
        return buckets.values.filter { $0.count > 1 }
    }

    private func makeGroup(_ files: [Candidate]) -> DuplicateGroup? {
        guard let first = files.first else { return nil }
        let dupFiles = files.map {
            DuplicateFile(path: $0.path, size: $0.size, modified: Date(timeIntervalSince1970: $0.modified),
                          ref: $0.ref, cloneID: Self.cloneID($0.path))
        }
        let id = dupFiles.map(\.path).min() ?? first.path
        let group = DuplicateGroup(id: id, size: first.size, files: dupFiles,
                                   suggestedKeep: Self.suggestKeep(dupFiles, home: options.home))
        return group.physicalCopies > 1 ? group : nil
    }

    /// Keeps the copy outside Downloads/temp folders and without "copy"-style names, then the oldest.
    public static func suggestKeep(_ files: [DuplicateFile], home: String) -> Int {
        func penalty(_ f: DuplicateFile) -> Int {
            var p = 0
            if PathFormat.isInside(f.path, home + "/Downloads") { p += 4 }
            if f.path.hasPrefix("/private/var/folders") || f.path.hasPrefix("/private/tmp") { p += 4 }
            let name = PathFormat.lastComponent(f.path).lowercased()
            if name.contains(" copy") || name.range(of: #"\(\d+\)"#, options: .regularExpression) != nil
                || name.range(of: #" \d+\.[a-z0-9]+$"#, options: .regularExpression) != nil { p += 2 }
            return p
        }
        let indexed = files.enumerated().sorted { a, b in
            (penalty(a.element), a.element.modified, a.element.path.count)
                < (penalty(b.element), b.element.modified, b.element.path.count)
        }
        return indexed.first?.offset ?? 0
    }

    // MARK: - Hashing

    static let chunk = 1 << 20

    static func partialHash(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let window = 64 * 1024
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: window)
        let headCount = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, window, 0) }
        guard headCount >= 0 else { return nil }
        hasher.update(data: buf[0..<headCount])
        if st.st_size > Int64(window) * 2 {
            let tailCount = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, window, off_t(st.st_size) - off_t(window)) }
            guard tailCount >= 0 else { return nil }
            hasher.update(data: buf[0..<tailCount])
        }
        return hex(hasher.finalize())
    }

    static func fullHash(_ path: String, isCancelled: () -> Bool = { false }) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            if isCancelled() { return nil }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: buf[0..<n])
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// APFS clone id: files cloned from one another share it, so they occupy one set of blocks.
    static func cloneID(_ path: String) -> UInt64? {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buf = [UInt8](repeating: 0, count: 32)
        // FSOPT_ATTR_CMN_EXTENDED: interpret forkattr as extended common attributes.
        let r = buf.withUnsafeMutableBytes { getattrlist(path, &a, $0.baseAddress!, $0.count, UInt32(0x20)) }
        guard r == 0 else { return nil }
        let id = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return id == 0 ? nil : id
    }
}
