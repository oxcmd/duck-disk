import Foundation

/// A regular file (or symlink) inside a scanned directory. Kept compact: a full-disk scan holds millions.
public struct FileEntry: Sendable {
    public var name: String
    /// Allocated bytes on disk (all forks).
    public var size: Int64
    /// Modification time, seconds since 1970.
    public var modified: Double
    public var fileID: UInt64
    public var flags: UInt8

    public static let isMedia: UInt8 = 1 << 0
    public static let isHidden: UInt8 = 1 << 1
    public static let isRemoved: UInt8 = 1 << 2
    public static let isHardLinkCopy: UInt8 = 1 << 3

    public var media: Bool { flags & Self.isMedia != 0 }
    public var hidden: Bool { flags & Self.isHidden != 0 }
    public var removed: Bool { flags & Self.isRemoved != 0 }
    public var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
}

/// A scanned directory. Child arrays are written only by the scanner thread that read this directory,
/// then treated as read-only except for main-thread removal bookkeeping.
public final class DirNode: @unchecked Sendable {
    /// For the root this is the full scan path; otherwise the entry name.
    public let name: String
    /// Weak so a reference kept after its tree is released degrades to a shorter path instead of a crash.
    public private(set) weak var parent: DirNode?
    public internal(set) var subdirs: [DirNode] = []
    public internal(set) var files: [FileEntry] = []
    /// Recursive allocated size.
    public internal(set) var size: Int64 = 0
    /// Recursive number of files.
    public internal(set) var fileCount: Int = 0
    /// Recursive bytes of photo, video and audio files.
    public internal(set) var mediaSize: Int64 = 0
    public internal(set) var modified: Double = 0
    public internal(set) var flags: UInt8 = 0

    public static let isPackage: UInt8 = 1 << 0
    public static let isHidden: UInt8 = 1 << 1
    public static let isUnreadable: UInt8 = 1 << 2
    public static let isRemoved: UInt8 = 1 << 3
    public static let isMediaLibrary: UInt8 = 1 << 4
    public static let isSkipped: UInt8 = 1 << 5

    public var isPackage: Bool { flags & Self.isPackage != 0 }
    public var isHidden: Bool { flags & Self.isHidden != 0 }
    public var isUnreadable: Bool { flags & Self.isUnreadable != 0 }
    public var isRemoved: Bool { flags & Self.isRemoved != 0 }
    public var modifiedDate: Date { Date(timeIntervalSince1970: modified) }

    init(name: String, parent: DirNode?) {
        self.name = name
        self.parent = parent
    }

    public var isRoot: Bool { parent == nil }

    /// Absolute path, rebuilt by walking up to the root.
    public var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base == "/" ? "/" + name : base + "/" + name
    }

    /// Depth below the scan root (root = 0).
    public var depth: Int {
        var d = 0
        var node = parent
        while let n = node { d += 1; node = n.parent }
        return d
    }

    public func subdir(named child: String) -> DirNode? {
        subdirs.first { $0.name == child && !$0.isRemoved }
    }

    public func fileIndex(named child: String) -> Int? {
        files.firstIndex { $0.name == child && !$0.removed }
    }

    /// Live (not removed) children, largest first.
    public var sortedChildren: [ItemRef] {
        var refs: [ItemRef] = []
        refs.reserveCapacity(subdirs.count + files.count)
        for d in subdirs where !d.isRemoved { refs.append(ItemRef(dir: d)) }
        for f in files where !f.removed { refs.append(ItemRef(dir: self, fileName: f.name)) }
        return refs.sorted { $0.size > $1.size }
    }

}

/// Stable reference to a node in the tree: a directory, or a file inside a directory.
public struct ItemRef: Hashable, @unchecked Sendable {
    public let dir: DirNode
    public let fileName: String?

    public init(dir: DirNode, fileName: String? = nil) {
        self.dir = dir
        self.fileName = fileName
    }

    public static func == (a: ItemRef, b: ItemRef) -> Bool {
        a.dir === b.dir && a.fileName == b.fileName
    }

    public func hash(into h: inout Hasher) {
        h.combine(ObjectIdentifier(dir))
        h.combine(fileName)
    }

    public var isDirectory: Bool { fileName == nil }
    public var name: String { fileName ?? dir.name }
    public var path: String {
        guard let fileName else { return dir.path }
        let base = dir.path
        return base == "/" ? "/" + fileName : base + "/" + fileName
    }

    public var file: FileEntry? {
        guard let fileName, let i = dir.fileIndex(named: fileName) else { return nil }
        return dir.files[i]
    }

    public var size: Int64 { fileName == nil ? dir.size : (file?.size ?? 0) }
    public var mediaSize: Int64 {
        if fileName == nil { return dir.mediaSize }
        guard let f = file else { return 0 }
        return f.media ? f.size : 0
    }
    public var modified: Date { fileName == nil ? dir.modifiedDate : (file?.modifiedDate ?? .distantPast) }
    public var itemCount: Int { fileName == nil ? dir.fileCount : 1 }
    public var isRemoved: Bool {
        if fileName == nil { return dir.isRemoved || dir.hasRemovedAncestor }
        return file == nil || dir.isRemoved || dir.hasRemovedAncestor
    }
}

extension DirNode {
    var hasRemovedAncestor: Bool {
        var node = parent
        while let n = node {
            if n.isRemoved { return true }
            node = n.parent
        }
        return false
    }
}

public struct ScanStats: Sendable {
    public var files: Int = 0
    public var dirs: Int = 0
    public var bytes: Int64 = 0
    public var unreadableDirs: Int = 0
    public var duration: TimeInterval = 0
    public init() {}
}

/// Result of a scan. Owns every node.
public final class ScanTree: @unchecked Sendable {
    public let root: DirNode
    public let rootPath: String
    public let volume: VolumeInfo?
    public let startedAt: Date
    public internal(set) var stats: ScanStats
    /// Guards file lists while the main thread removes items and background work reads them.
    let lock = NSLock()

    init(root: DirNode, rootPath: String, volume: VolumeInfo?, startedAt: Date, stats: ScanStats) {
        self.root = root
        self.rootPath = rootPath
        self.volume = volume
        self.startedAt = startedAt
        self.stats = stats
    }

    /// True when the scan covered a whole volume (so "used" space can be compared against it).
    public var isVolumeScan: Bool { volume.map { $0.path == rootPath } ?? false }

    /// Bytes on the volume that the scan could not attribute (system data, snapshots, unreadable folders).
    public var unaccountedBytes: Int64 {
        guard isVolumeScan, let v = volume else { return 0 }
        return max(0, v.used - root.size)
    }

    /// Adds each directory's totals (initially its direct files only) into every ancestor, children first.
    static func rollUp(_ root: DirNode) {
        var order: [DirNode] = []
        var stack = [root]
        while let d = stack.popLast() {
            order.append(d)
            stack.append(contentsOf: d.subdirs)
        }
        for node in order.reversed() {
            guard let parent = node.parent else { continue }
            parent.size += node.size
            parent.fileCount += node.fileCount
            parent.mediaSize += node.mediaSize
        }
    }

    /// Every directory that has not been removed, skipping removed subtrees.
    public func liveDirs() -> [DirNode] {
        var out: [DirNode] = []
        out.reserveCapacity(stats.dirs + 1)
        var stack = [root]
        while let d = stack.popLast() {
            guard !d.isRemoved else { continue }
            out.append(d)
            stack.append(contentsOf: d.subdirs)
        }
        return out
    }

    /// Finds the node for an absolute path inside the scan root.
    public func node(atPath path: String) -> DirNode? {
        guard PathFormat.isInside(path, rootPath) else { return nil }
        if path == rootPath { return root }
        let rel = rootPath == "/" ? path.dropFirst(1) : path.dropFirst(rootPath.count + 1)
        var node = root
        for comp in rel.split(separator: "/") {
            guard let next = node.subdir(named: String(comp)) else { return nil }
            node = next
        }
        return node
    }

    public func ref(forPath path: String) -> ItemRef? {
        if let d = node(atPath: path) { return ItemRef(dir: d) }
        let parentPath = PathFormat.parent(of: path)
        guard let p = node(atPath: parentPath) else { return nil }
        let name = PathFormat.lastComponent(path)
        return p.fileIndex(named: name) != nil ? ItemRef(dir: p, fileName: name) : nil
    }

    /// Marks an item as removed and subtracts its size from every ancestor. Main-thread only.
    @discardableResult
    public func remove(_ ref: ItemRef) -> Int64 {
        var bytes: Int64 = 0, count = 0, media: Int64 = 0
        var start: DirNode?
        if let name = ref.fileName {
            guard let i = ref.dir.fileIndex(named: name) else { return 0 }
            let f = ref.dir.files[i]
            bytes = f.size; count = 1; media = f.media ? f.size : 0
            lock.lock()
            ref.dir.files[i].flags |= FileEntry.isRemoved
            lock.unlock()
            start = ref.dir
        } else {
            guard !ref.dir.isRemoved else { return 0 }
            bytes = ref.dir.size; count = ref.dir.fileCount; media = ref.dir.mediaSize
            ref.dir.flags |= DirNode.isRemoved
            start = ref.dir.parent
        }
        var node = start
        while let n = node {
            n.size -= bytes; n.fileCount -= count; n.mediaSize -= media
            node = n.parent
        }
        stats.bytes -= bytes
        stats.files -= count
        return bytes
    }

    /// A stable copy of a directory's file list, safe to iterate off the main thread.
    public func files(of dir: DirNode) -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return dir.files
    }

    /// Visits every live file. The visitor returns false to stop.
    public func forEachFile(_ body: (DirNode, FileEntry) -> Bool) {
        for d in liveDirs() {
            for f in files(of: d) where !f.removed {
                if !body(d, f) { return }
            }
        }
    }
}
