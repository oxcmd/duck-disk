import Foundation

/// Decides which copy of each duplicate set stays and which copies are offered for the Trash.
public enum DuplicateSelection {
    /// True when `path` or one of its ancestors is in `set`.
    public static func covered(_ path: String, by set: Set<String>) -> Bool {
        var p = path
        while p.count > 1 {
            if set.contains(p) { return true }
            p = PathFormat.parent(of: p)
        }
        return set.contains("/")
    }

    /// Makes sure every group has a kept copy that is still in the group, preferring a copy no other cleanup
    /// category would remove, and lists the copies that would free space.
    /// - Parameters:
    ///   - keep: current choice per group id; missing or stale entries are re-picked.
    ///   - otherItemPaths: paths of items in the other cleanup categories.
    public static func resolve(_ groups: [DuplicateGroup], keep: [String: String], otherItemPaths: Set<String>,
                               home: String) -> (keep: [String: String], items: [CleanupItem]) {
        var keep = keep
        var items: [CleanupItem] = []
        for g in groups {
            if keep[g.id].map({ path in !g.files.contains { $0.path == path } }) ?? true {
                let safe = g.files.filter { !covered($0.path, by: otherItemPaths) }
                let pool = safe.isEmpty ? g.files : safe
                keep[g.id] = pool[DuplicateFinder.suggestKeep(pool, home: home)].path
            }
            guard let kept = g.files.first(where: { $0.path == keep[g.id] }) else { continue }
            let keptName = PathFormat.abbreviated(kept.path, home: home)
            // A clone of a copy already counted shares its blocks and frees nothing.
            var countedClones = Set<UInt64>(kept.cloneID.map { [$0] } ?? [])
            for f in g.files where f.path != kept.path && !covered(f.path, by: otherItemPaths) {
                if let c = f.cloneID, !countedClones.insert(c).inserted { continue }
                items.append(CleanupItem(path: f.path, ref: f.ref, category: .duplicates, size: f.size,
                                         detail: "Same as \(keptName)", modified: f.modified))
            }
        }
        return (keep, items.sorted { $0.size > $1.size })
    }

    /// Removes from a trash request every kept copy, and the individually requested copies of any set whose
    /// copies would otherwise all go.
    public static func protect(_ requests: [TrashService.Request], groups: [DuplicateGroup],
                               keep: [String: String]) -> [TrashService.Request] {
        let kept = Set(keep.values)
        var out = requests.filter { !kept.contains($0.path) }
        for g in groups {
            let requested = Set(out.map(\.path))
            guard g.files.allSatisfy({ covered($0.path, by: requested) }) else { continue }
            let individual = Set(g.files.map(\.path)).intersection(requested)
            out.removeAll { individual.contains($0.path) }
        }
        return out
    }
}
