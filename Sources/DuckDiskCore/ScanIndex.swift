import CryptoKit
import Foundation

/// Saves a scan's names, sizes and dates so Find works right after launch, before a new scan.
/// Format: "DDIX" + version, root path and scan date, then folders in pre-order (parent index, name, flags,
/// date, files), then a SHA-256 of everything before it; LZ4-compressed (fast to write after every scan).
/// Stored in ~/Library/Application Support/Duck Disk/Index. Anything that does not check out loads as nil.
public enum ScanIndex {
    static let magic: [UInt8] = Array("DDIX".utf8)
    static let version: UInt8 = 2
    static let checksumLength = 32
    /// Paths are at most 1024 bytes, so real folders are never nested anywhere near this deep.
    static let maxDepth = 2_048

    public static var directory: URL { AppSupport.directory.appendingPathComponent("Index", isDirectory: true) }

    /// One file per scanned root, named by a hash of the root path.
    public static func url(forRoot root: String, in dir: URL = directory) -> URL {
        let digest = SHA256.hash(data: Data(PathFormat.realPath(root).utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".ddindex")
    }

    public static func save(_ tree: ScanTree, in dir: URL = directory) throws {
        var w = Writer()
        w.buffer.reserveCapacity(tree.stats.files * 40 + tree.stats.dirs * 40 + 64)
        w.bytes(magic)
        w.u8(version)
        w.string(tree.rootPath)
        w.double(tree.startedAt.timeIntervalSince1970)

        var order: [(DirNode, Int32)] = []
        var stack: [(DirNode, Int32)] = [(tree.root, -1)]
        while let (dir, parent) = stack.popLast() {
            let index = Int32(order.count)
            order.append((dir, parent))
            for sub in dir.subdirs.reversed() where !sub.isRemoved { stack.append((sub, index)) }
        }
        w.u32(UInt32(order.count))
        for (dir, parent) in order {
            w.i32(parent)
            w.string(dir.isRoot ? "" : dir.name)
            w.u8(dir.flags & ~(DirNode.isRemoved | DirNode.isUnreadable))
            w.double(dir.modified)
            let files = tree.files(of: dir)
            w.u32(UInt32(files.reduce(0) { $0 + ($1.removed ? 0 : 1) }))
            for f in files where !f.removed {
                w.string(f.name)
                w.i64(f.size)
                w.double(f.modified)
                w.u8(f.flags & ~FileEntry.isRemoved)
            }
        }
        w.bytes(Array(SHA256.hash(data: w.buffer)))
        let compressed = try (Data(w.buffer) as NSData).compressed(using: .lz4) as Data
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try compressed.write(to: url(forRoot: tree.rootPath, in: dir), options: .atomic)
    }

    /// Loads the saved index for a root, or nil when there is none or it cannot be read.
    public static func load(root: String, in dir: URL = directory) -> ScanTree? {
        guard let compressed = try? Data(contentsOf: url(forRoot: root, in: dir)),
              let raw = try? (compressed as NSData).decompressed(using: .lz4) as Data,
              raw.count > checksumLength else { return nil }
        let body = raw.prefix(raw.count - checksumLength)
        guard Array(SHA256.hash(data: body)) == Array(raw.suffix(checksumLength)) else { return nil }

        var r = Reader(data: [UInt8](body))
        guard r.bytes(4) == magic, r.u8() == version, let rootPath = r.string(),
              rootPath == PathFormat.realPath(root), let started = r.double(),
              let count = r.u32(), count > 0, Int(count) <= body.count else { return nil }

        var dirs: [DirNode] = []
        var depths: [Int] = []
        dirs.reserveCapacity(Int(count))
        depths.reserveCapacity(Int(count))
        var stats = ScanStats()
        var total: Int64 = 0
        let keepDir = ~(DirNode.isRemoved | DirNode.isUnreadable)
        for index in 0..<Int(count) {
            guard let parentIndex = r.i32(), let name = r.string(), let flags = r.u8(), let modified = r.double(),
                  let fileCount = r.u32(), Int(fileCount) <= body.count else { return nil }
            // Only the first record is the root; every other folder names an earlier one as its parent.
            let parent: DirNode?
            if index == 0 {
                guard parentIndex == -1 else { return nil }
                parent = nil
                depths.append(0)
            } else {
                guard parentIndex >= 0, Int(parentIndex) < dirs.count, !name.isEmpty, !name.contains("/"),
                      depths[Int(parentIndex)] < maxDepth else { return nil }
                parent = dirs[Int(parentIndex)]
                depths.append(depths[Int(parentIndex)] + 1)
            }
            let node = DirNode(name: parent == nil ? rootPath : name, parent: parent)
            node.flags = flags & keepDir
            node.modified = modified.isFinite ? modified : 0
            var files: [FileEntry] = []
            files.reserveCapacity(Int(fileCount))
            for _ in 0..<fileCount {
                guard let fname = r.string(), let size = r.i64(), let fmod = r.double(), let fflags = r.u8(),
                      size >= 0, !fname.isEmpty, !fname.contains("/") else { return nil }
                // A running total that cannot overflow keeps every folder sum in range too.
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { return nil }
                total = sum
                files.append(FileEntry(name: fname, size: size, modified: fmod.isFinite ? fmod : 0, fileID: 0,
                                       flags: fflags & ~FileEntry.isRemoved))
                node.size += size
                if fflags & FileEntry.isMedia != 0 { node.mediaSize += size }
            }
            node.files = files
            node.fileCount = files.count
            parent?.subdirs.append(node)
            dirs.append(node)
            stats.files += files.count
            stats.dirs += 1
        }
        guard r.offset == body.count else { return nil }
        ScanTree.rollUp(dirs[0])
        stats.bytes = dirs[0].size
        return ScanTree(root: dirs[0], rootPath: rootPath, volume: nil,
                        startedAt: Date(timeIntervalSince1970: started.isFinite ? started : 0), stats: stats)
    }

    /// Deletes every saved index (Duck Disk's own files).
    public static func removeAll(in dir: URL = directory) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Binary helpers

    struct Writer {
        var buffer: [UInt8] = []
        mutating func bytes(_ b: [UInt8]) { buffer.append(contentsOf: b) }
        mutating func u8(_ v: UInt8) { buffer.append(v) }
        mutating func little<T: FixedWidthInteger>(_ v: T) {
            var x = v
            for _ in 0..<MemoryLayout<T>.size {
                buffer.append(UInt8(truncatingIfNeeded: x))
                x >>= 8
            }
        }
        mutating func u16(_ v: UInt16) { little(v) }
        mutating func u32(_ v: UInt32) { little(v) }
        mutating func i32(_ v: Int32) { little(UInt32(bitPattern: v)) }
        mutating func i64(_ v: Int64) { little(UInt64(bitPattern: v)) }
        mutating func double(_ v: Double) { little(v.bitPattern) }
        mutating func string(_ s: String) {
            var s = s
            s.withUTF8 { utf8 in
                let n = min(utf8.count, Int(UInt16.max))
                u16(UInt16(n))
                buffer.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[0..<n]))
            }
        }
    }

    struct Reader {
        let data: [UInt8]
        var offset = 0

        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return Array(data[offset..<offset + n])
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            for i in 0..<size { value |= T(data[offset + i]) << (8 * i) }
            offset += size
            return value
        }

        mutating func u8() -> UInt8? { integer(UInt8.self) }
        mutating func u32() -> UInt32? { integer(UInt32.self) }
        mutating func i32() -> Int32? { integer(UInt32.self).map { Int32(bitPattern: $0) } }
        mutating func i64() -> Int64? { integer(UInt64.self).map { Int64(bitPattern: $0) } }
        mutating func double() -> Double? { integer(UInt64.self).map { Double(bitPattern: $0) } }
        mutating func string() -> String? {
            guard let len = integer(UInt16.self), offset + Int(len) <= data.count else { return nil }
            defer { offset += Int(len) }
            return String(decoding: data[offset..<offset + Int(len)], as: UTF8.self)
        }
    }
}
