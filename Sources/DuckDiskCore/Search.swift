import Foundation

public struct SearchQuery: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case any = "Everything", folders = "Folders", files = "Files", media = "Photos & videos"
        public var id: String { rawValue }
    }

    public var text: String
    public var kind: Kind = .any
    public var minSize: Int64 = 0
    public var includeHidden = true
    public var limit = 1_000

    public init(text: String) { self.text = text }
}

public struct SearchHit: Identifiable, Hashable, @unchecked Sendable {
    public var id: ItemRef { ref }
    public let ref: ItemRef
    public let size: Int64
    public let modified: Date
}

/// Name search over the scan index, split across cores. ASCII queries use a byte-level case-folding
/// matcher; other queries fall back to Foundation's case-insensitive search.
public enum TreeSearch {
    public static func run(_ tree: ScanTree, _ query: SearchQuery, isCancelled: @escaping () -> Bool = { false })
        -> [SearchHit] {
        let needle = query.text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let dirs = tree.liveDirs()
        let asciiNeedle: [UInt8]? = needle.utf8.allSatisfy { $0 < 128 }
            ? needle.utf8.map(FileKinds.lowercased) : nil
        let matches: (String) -> Bool = { name in
            if let asciiNeedle { return containsFolded(name, asciiNeedle) }
            return name.localizedCaseInsensitiveContains(needle)
        }

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var partial = [[SearchHit]](repeating: [], count: workers)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            var local: [SearchHit] = []
            var i = w
            var steps = 0
            while i < dirs.count {
                steps += 1
                if steps & 1023 == 0 && isCancelled() { return }
                let d = dirs[i]
                i += workers
                if !query.includeHidden && d.isHidden { continue }
                if query.kind == .any || query.kind == .folders, !d.isRoot,
                   d.size >= query.minSize, matches(d.name) {
                    local.append(SearchHit(ref: ItemRef(dir: d), size: d.size, modified: d.modifiedDate))
                }
                if query.kind == .folders { continue }
                for f in tree.files(of: d) where !f.removed && f.size >= query.minSize {
                    if !query.includeHidden && f.hidden { continue }
                    if query.kind == .media && !f.media { continue }
                    if matches(f.name) {
                        local.append(SearchHit(ref: ItemRef(dir: d, fileName: f.name), size: f.size,
                                               modified: f.modifiedDate))
                    }
                }
            }
            lock.lock(); partial[w] = local; lock.unlock()
        }
        var hits = partial.flatMap { $0 }
        if !query.includeHidden {
            hits = hits.filter { !hasHiddenAncestor($0.ref.dir) }
        }
        hits.sort { $0.size > $1.size }
        return Array(hits.prefix(query.limit))
    }

    static func hasHiddenAncestor(_ dir: DirNode) -> Bool {
        var node: DirNode? = dir
        while let n = node {
            if n.isHidden { return true }
            node = n.parent
        }
        return false
    }

    /// Case-insensitive (ASCII) substring test on the name's UTF-8 bytes.
    static func containsFolded(_ name: String, _ needle: [UInt8]) -> Bool {
        var name = name
        return name.withUTF8 { hay -> Bool in
            let n = needle.count, h = hay.count
            guard n <= h else { return false }
            let first = needle[0]
            var i = 0
            while i <= h - n {
                if FileKinds.lowercased(hay[i]) == first {
                    var j = 1
                    while j < n && FileKinds.lowercased(hay[i + j]) == needle[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }

    /// The biggest files anywhere in the tree.
    public static func largestFiles(_ tree: ScanTree, limit: Int = 200) -> [SearchHit] {
        var top: [SearchHit] = []
        var threshold: Int64 = 0
        for d in tree.liveDirs() {
            for f in tree.files(of: d) where !f.removed && f.size > threshold {
                top.append(SearchHit(ref: ItemRef(dir: d, fileName: f.name), size: f.size, modified: f.modifiedDate))
                if top.count >= limit * 2 {
                    top.sort { $0.size > $1.size }
                    top.removeLast(top.count - limit)
                    threshold = top.last?.size ?? 0
                }
            }
        }
        top.sort { $0.size > $1.size }
        return Array(top.prefix(limit))
    }

    /// Largest photos and videos, for Compress suggestions.
    public static func largeMedia(_ tree: ScanTree, minVideo: Int64 = 50_000_000, minPhoto: Int64 = 4_000_000,
                                  limit: Int = 40) -> [SearchHit] {
        var out: [SearchHit] = []
        for d in tree.liveDirs() where d.flags & DirNode.isMediaLibrary == 0 && !d.isPackage {
            for f in tree.files(of: d) where !f.removed && f.media && f.size >= minPhoto {
                let isVideo = FileKinds.isVideo(f.name)
                if (isVideo && f.size >= minVideo) || (!isVideo && FileKinds.isCompressiblePhoto(f.name)) {
                    out.append(SearchHit(ref: ItemRef(dir: d, fileName: f.name), size: f.size, modified: f.modifiedDate))
                }
            }
        }
        out.sort { $0.size > $1.size }
        return Array(out.prefix(limit))
    }
}
