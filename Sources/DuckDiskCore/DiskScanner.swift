import Foundation
import Darwin

public struct ScanProgress: Sendable {
    public var files: Int = 0
    public var dirs: Int = 0
    public var bytes: Int64 = 0
    public var currentPath: String = ""
    public var elapsed: TimeInterval = 0
    public init() {}
}

public struct ScanOptions: Sendable {
    /// Absolute paths that are never entered.
    public var excludedPaths: Set<String> = []
    /// Directory-reading threads. Disk-bound work, so more threads than cores helps on SSDs.
    public var threadCount: Int = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))
    /// Follow into other mounted volumes found below the root.
    public var crossMountPoints = false
    public init() {}
}

/// Parallel directory walker built on getattrlistbulk(2): each directory is read with one syscall batch
/// returning name, type, dates, flags, file id, mount status, link count and allocated size together.
public final class DiskScanner: @unchecked Sendable {
    public let rootPath: String
    public let options: ScanOptions

    private let cond = NSCondition()
    private var queue: [(DirNode, String)] = []
    private var pending = 0
    private var cancelled = false

    private let statsLock = NSLock()
    private var live = ScanProgress()
    private var unreadable = 0
    private var startTime = Date()

    private let linkLock = NSLock()
    private var seenHardLinks = Set<UInt64>()

    private static let bufferSize = 256 * 1024
    /// FSOPT_PACK_INV_ATTRS (not imported into Swift): every requested attribute is packed even when it
    /// does not apply to the entry, which keeps the record layout fixed.
    private static let packInvalidAttributes: UInt64 = 0x8

    public init(rootPath: String, options: ScanOptions = ScanOptions()) {
        self.rootPath = PathFormat.realPath(rootPath)
        self.options = options
    }

    public var progress: ScanProgress {
        statsLock.lock(); defer { statsLock.unlock() }
        var p = live
        p.elapsed = Date().timeIntervalSince(startTime)
        return p
    }

    public func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    public var isCancelled: Bool {
        cond.lock(); defer { cond.unlock() }
        return cancelled
    }

    /// Scans on dedicated threads; returns nil when cancelled.
    public func scan() async -> ScanTree? {
        await withCheckedContinuation { cont in
            let t = Thread { cont.resume(returning: self.scanSync()) }
            t.stackSize = 4 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    /// Blocking scan. Call from a background thread.
    public func scanSync() -> ScanTree? {
        startTime = Date()
        let root = DirNode(name: rootPath, parent: nil)
        var st = stat()
        if stat(rootPath, &st) == 0 { root.modified = Double(st.st_mtimespec.tv_sec) }

        cond.lock()
        queue = [(root, rootPath)]
        pending = 1
        cond.unlock()

        let group = DispatchGroup()
        for _ in 0..<max(1, options.threadCount) {
            group.enter()
            let t = Thread { [self] in
                worker()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        if isCancelled { return nil }

        aggregate(root)
        var stats = ScanStats()
        statsLock.lock()
        stats.files = live.files
        stats.dirs = live.dirs
        stats.unreadableDirs = unreadable
        statsLock.unlock()
        stats.bytes = root.size
        stats.duration = Date().timeIntervalSince(startTime)
        return ScanTree(root: root, rootPath: rootPath, volume: VolumeInfo.forPath(rootPath),
                        startedAt: startTime, stats: stats)
    }

    // MARK: - Work queue

    private func nextWork() -> (DirNode, String)? {
        cond.lock()
        defer { cond.unlock() }
        while queue.isEmpty && pending > 0 && !cancelled { cond.wait() }
        if cancelled || queue.isEmpty { return nil }
        return queue.removeLast()
    }

    private func finish(_ newDirs: [(DirNode, String)]) {
        cond.lock()
        queue.append(contentsOf: newDirs)
        pending += newDirs.count - 1
        if pending == 0 || !newDirs.isEmpty { cond.broadcast() }
        cond.unlock()
    }

    private func worker() {
        // Never make iCloud / File Provider placeholders download while listing them.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while let (node, path) = nextWork() {
            let children = read(node, path: path, buffer: buffer)
            finish(children)
        }
    }

    // MARK: - Directory reading

    private static func makeAttrList() -> attrlist {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        a.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        a.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return a
    }

    /// Reads one directory, fills `node` with its files and returns the subdirectories to visit.
    private func read(_ node: DirNode, path: String, buffer: UnsafeMutableRawPointer) -> [(DirNode, String)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            node.flags |= DirNode.isUnreadable
            statsLock.lock(); unreadable += 1; statsLock.unlock()
            return []
        }
        defer { close(fd) }

        var attrs = Self.makeAttrList()
        var files: [FileEntry] = []
        var subdirs: [DirNode] = []
        var work: [(DirNode, String)] = []
        var directBytes: Int64 = 0
        var directMedia: Int64 = 0
        let inMediaLibrary = node.flags & DirNode.isMediaLibrary != 0
        let prefix = path == "/" ? "/" : path + "/"

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, Self.bufferSize, Self.packInvalidAttributes)
            if count < 0 {
                if files.isEmpty && subdirs.isEmpty {
                    node.flags |= DirNode.isUnreadable
                    statsLock.lock(); unreadable += 1; statsLock.unlock()
                }
                break
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4 + MemoryLayout<attribute_set_t>.size

                // ATTR_CMN_NAME: attrreference_t relative to its own position.
                let nameOffset = Int(p.loadUnaligned(as: Int32.self))
                let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                let name = String(decoding: UnsafeRawBufferPointer(start: p + nameOffset,
                                                                   count: max(0, nameLength - 1)),
                                  as: UTF8.self)
                p += 8
                let objType = p.loadUnaligned(as: UInt32.self); p += 4
                let modSeconds = p.loadUnaligned(as: Int.self); p += MemoryLayout<timespec>.size
                let bsdFlags = p.loadUnaligned(as: UInt32.self); p += 4
                let fileID = p.loadUnaligned(as: UInt64.self); p += 8
                // Directory records carry only dir attributes, everything else only file attributes,
                // even with FSOPT_PACK_INV_ATTRS.
                let isDir = objType == VDIR.rawValue
                var mountStatus: UInt32 = 0, linkCount: UInt32 = 1, allocSize: Int64 = 0
                if isDir {
                    mountStatus = p.loadUnaligned(as: UInt32.self)
                } else {
                    linkCount = p.loadUnaligned(as: UInt32.self)
                    allocSize = p.loadUnaligned(fromByteOffset: 4, as: Int64.self)
                }
                entry += length

                let hidden = name.hasPrefix(".") || bsdFlags & UInt32(UF_HIDDEN) != 0

                if isDir {
                    let childPath = prefix + name
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 && !options.crossMountPoints { continue }
                    if options.excludedPaths.contains(childPath) { continue }
                    let child = DirNode(name: name, parent: node)
                    child.modified = Double(modSeconds)
                    if hidden { child.flags |= DirNode.isHidden }
                    let ext = FileKinds.extensionKey(name)
                    if FileKinds.packageExtensions.contains(ext) { child.flags |= DirNode.isPackage }
                    if inMediaLibrary || FileKinds.mediaLibraryExtensions.contains(ext) {
                        child.flags |= DirNode.isMediaLibrary
                    }
                    subdirs.append(child)
                    work.append((child, childPath))
                } else if objType == VREG.rawValue || objType == VLNK.rawValue {
                    var size = max(0, allocSize)
                    var flags: UInt8 = hidden ? FileEntry.isHidden : 0
                    if objType == VREG.rawValue && linkCount > 1 {
                        linkLock.lock()
                        let first = seenHardLinks.insert(fileID).inserted
                        linkLock.unlock()
                        if !first { size = 0; flags |= FileEntry.isHardLinkCopy }
                    }
                    if inMediaLibrary || FileKinds.isMedia(name) {
                        flags |= FileEntry.isMedia
                        directMedia += size
                    }
                    directBytes += size
                    files.append(FileEntry(name: name, size: size, modified: Double(modSeconds),
                                           fileID: fileID, flags: flags))
                }
            }
        }

        node.files = files
        node.subdirs = subdirs
        node.size = directBytes
        node.fileCount = files.count
        node.mediaSize = directMedia

        statsLock.lock()
        live.files += files.count
        live.dirs += 1
        live.bytes += directBytes
        live.currentPath = path
        statsLock.unlock()
        return work
    }

    /// Rolls direct totals up into every ancestor (children before parents).
    private func aggregate(_ root: DirNode) {
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
}

/// File-type lookups keyed by lowercase extension, packed into an integer to avoid string allocation.
public enum FileKinds {
    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif",
                                                     "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "webp",
                                                     "bmp", "psd", "orf", "rw2", "raf", "avif"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mts",
                                                     "m2ts", "3gp", "wmv", "flv", "mpg", "mpeg", "hevc"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac",
                                                     "ogg", "opus", "caf", "alac", "wma"]
    static let mediaKeys: Set<UInt64> = Set((photoExtensions.union(videoExtensions).union(audioExtensions))
        .map { key(for: $0) })
    static let packageExtensions: Set<UInt64> = Set(["app", "bundle", "framework", "plugin", "kext", "appex",
                                                     "xpc", "photoslibrary", "musiclibrary", "tvlibrary",
                                                     "fcpbundle", "imovielibrary", "logicx", "band", "rtfd",
                                                     "pages", "numbers", "key", "xcodeproj", "xcworkspace",
                                                     "playground", "sparsebundle", "xcarchive", "photolibrary",
                                                     "aplibrary", "savedstate"]
        .map { key(for: $0) })
    static let mediaLibraryExtensions: Set<UInt64> = Set(["photoslibrary", "photolibrary", "aplibrary",
                                                          "fcpbundle", "imovielibrary", "tvlibrary"]
        .map { key(for: $0) })

    /// Packs up to 8 lowercase ASCII bytes of a string into a UInt64 (longer strings get a sentinel bit).
    static func key(for ext: String) -> UInt64 {
        var k: UInt64 = 0
        var n = 0
        for b in ext.utf8 {
            if n == 8 { return k | (1 << 63) }
            k = (k << 8) | UInt64(lowercased(b))
            n += 1
        }
        return k
    }

    @inline(__always) static func lowercased(_ b: UInt8) -> UInt8 {
        (b >= 65 && b <= 90) ? b + 32 : b
    }

    /// Key for the extension of a file name (0 when there is none).
    static func extensionKey(_ name: String) -> UInt64 {
        var name = name
        return name.withUTF8 { buf -> UInt64 in
            guard let dot = buf.lastIndex(of: 46), dot > 0, dot < buf.count - 1 else { return 0 }
            let len = buf.count - dot - 1
            if len > 13 { return 0 }
            var k: UInt64 = 0
            var n = 0
            for i in (dot + 1)..<buf.count {
                if n == 8 { return k | (1 << 63) }
                k = (k << 8) | UInt64(lowercased(buf[i]))
                n += 1
            }
            return k
        }
    }

    public static func isMedia(_ name: String) -> Bool { mediaKeys.contains(extensionKey(name)) }

    public static func lowercasedExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public static func isVideo(_ name: String) -> Bool { videoExtensions.contains(lowercasedExtension(name)) }
    public static func isPhoto(_ name: String) -> Bool { photoExtensions.contains(lowercasedExtension(name)) }

    /// Single-image formats that survive a HEIC re-encode. RAW, PSD, TIFF and GIF carry data
    /// (raw sensor data, layers, pages, animation) that would be lost, so they are never compressed.
    public static let compressiblePhotoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp"]
    public static func isCompressiblePhoto(_ name: String) -> Bool {
        compressiblePhotoExtensions.contains(lowercasedExtension(name))
    }
}
