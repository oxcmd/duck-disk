import Foundation

/// A record of where the space was at one moment, used to compare a drive over time.
public struct Snapshot: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var targetPath: String
    public var targetName: String
    public var capacity: Int64
    public var used: Int64
    public var scanned: Int64
    /// Bytes per cleanup category and kept category ("kept.<name>").
    public var categories: [String: Int64]
    /// Folder sizes for folders of at least `minFolderSize`, up to `maxDepth` below the root.
    public var folders: [String: Int64]

    public static let minFolderSize: Int64 = 50_000_000
    public static let maxDepth = 4
    public static let maxFolders = 5_000

    public var summary: SnapshotSummary {
        SnapshotSummary(id: id, date: date, targetPath: targetPath, targetName: targetName,
                        capacity: capacity, used: used, scanned: scanned)
    }

    public static func make(tree: ScanTree, classification: Classification, date: Date = Date()) -> Snapshot {
        var cats: [String: Int64] = [:]
        for c in CleanupCategory.allCases { cats[c.rawValue] = classification.total(c) }
        for (k, v) in classification.kept { cats["kept." + k.rawValue] = v }

        var folders: [String: Int64] = [:]
        var stack: [(DirNode, String, Int)] = [(tree.root, tree.rootPath, 0)]
        while let (node, path, depth) = stack.popLast(), folders.count < maxFolders {
            folders[path] = node.size
            guard depth < maxDepth else { continue }
            for sub in node.subdirs where !sub.isRemoved && sub.size >= minFolderSize {
                let childPath = path == "/" ? "/" + sub.name : path + "/" + sub.name
                stack.append((sub, childPath, depth + 1))
            }
        }
        let used = tree.isVolumeScan ? (tree.volume?.used ?? tree.root.size) : tree.root.size
        return Snapshot(date: date, targetPath: tree.rootPath,
                        targetName: tree.isVolumeScan ? (tree.volume?.name ?? tree.rootPath)
                                                      : PathFormat.abbreviated(tree.rootPath),
                        capacity: tree.volume?.total ?? 0, used: used, scanned: tree.root.size,
                        categories: cats, folders: folders)
    }
}

public struct SnapshotSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let targetPath: String
    public let targetName: String
    public let capacity: Int64
    public let used: Int64
    public let scanned: Int64
}

public struct FolderChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let before: Int64
    public let after: Int64
    public var delta: Int64 { after - before }
}

public struct SnapshotComparison: Sendable {
    public let older: SnapshotSummary
    public let newer: SnapshotSummary
    public let usedDelta: Int64
    public let categoryDeltas: [(key: String, delta: Int64)]
    public let changes: [FolderChange]
}

public enum SnapshotDiff {
    /// Folders that changed most. A parent is hidden when one child accounts for 80% of its change.
    public static func compare(_ a: Snapshot, _ b: Snapshot, limit: Int = 40,
                               minDelta: Int64 = 10_000_000) -> SnapshotComparison {
        let (old, new) = a.date <= b.date ? (a, b) : (b, a)
        let paths = Set(old.folders.keys).union(new.folders.keys)
        var changes = paths.compactMap { p -> FolderChange? in
            let c = FolderChange(path: p, before: old.folders[p] ?? 0, after: new.folders[p] ?? 0)
            return abs(c.delta) >= minDelta ? c : nil
        }
        var childrenByParent: [String: [FolderChange]] = [:]
        for c in changes where c.path != "/" { childrenByParent[PathFormat.parent(of: c.path), default: []].append(c) }
        changes = changes.filter { parent in
            let explainedByChild = (childrenByParent[parent.path] ?? []).contains { child in
                child.delta.signum() == parent.delta.signum()
                    && Double(abs(child.delta)) >= 0.8 * Double(abs(parent.delta))
            }
            return !explainedByChild
        }
        changes.sort { abs($0.delta) > abs($1.delta) }

        let keys = Set(old.categories.keys).union(new.categories.keys)
        let cats = keys.map { (key: $0, delta: (new.categories[$0] ?? 0) - (old.categories[$0] ?? 0)) }
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) > abs($1.delta) }
        return SnapshotComparison(older: old.summary, newer: new.summary, usedDelta: new.used - old.used,
                                  categoryDeltas: cats, changes: Array(changes.prefix(limit)))
    }
}

/// Stores each snapshot as its own JSON file plus a small index of summaries.
public final class SnapshotStore: @unchecked Sendable {
    private let dir: URL
    private let indexFile: URL
    public private(set) var summaries: [SnapshotSummary] = []
    public static let keepCount = 60

    public init(directory: URL = AppSupport.directory.appendingPathComponent("Snapshots", isDirectory: true)) {
        dir = directory
        indexFile = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile),
           let list = try? JSONDecoder.iso.decode([SnapshotSummary].self, from: data) {
            summaries = list.sorted { $0.date > $1.date }
        }
    }

    private func file(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".json") }

    public func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
        try? data.write(to: file(snapshot.id), options: .atomic)
        summaries.insert(snapshot.summary, at: 0)
        while summaries.count > Self.keepCount, let last = summaries.popLast() {
            try? FileManager.default.removeItem(at: file(last.id))
        }
        writeIndex()
    }

    public func load(_ id: UUID) -> Snapshot? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder.iso.decode(Snapshot.self, from: data)
    }

    /// Removes a snapshot record created by Duck Disk (its own data, not user files).
    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        summaries.removeAll { $0.id == id }
        writeIndex()
    }

    private func writeIndex() {
        if let data = try? JSONEncoder.iso.encode(summaries) { try? data.write(to: indexFile, options: .atomic) }
    }
}
