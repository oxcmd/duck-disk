import Foundation

/// Moves items to the Trash. Nothing in Duck Disk deletes files any other way.
public enum TrashService {
    public struct Failure: Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let reason: String
    }

    public struct Result: Sendable {
        /// Paths that reached the Trash, with the bytes each freed.
        public var trashed: [String: Int64] = [:]
        public var failures: [Failure] = []
        public var freedBytes: Int64 { trashed.values.reduce(0, +) }
        public init() {}
    }

    public struct Request: Sendable {
        public let path: String
        public let size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    /// Trashes every request that passes `SafetyGuard`, a few at a time off the main thread.
    public static func trash(_ requests: [Request], home: String = NSHomeDirectory()) async -> Result {
        // Drop items nested inside another requested item; trashing the parent covers them.
        let unique = removingNested(requests)

        return await withTaskGroup(of: (Request, String?, Int64).self) { group in
            var result = Result()
            var index = 0
            let width = 6
            func addNext() {
                guard index < unique.count else { return }
                let r = unique[index]
                index += 1
                group.addTask {
                    let freed = bytesFreed(r)
                    return (r, trashOne(r.path, home: home), freed)
                }
            }
            for _ in 0..<width { addNext() }
            while let (request, error, freed) = await group.next() {
                if let error {
                    result.failures.append(Failure(path: request.path, reason: error))
                } else {
                    result.trashed[request.path] = freed
                }
                addNext()
            }
            return result
        }
    }

    /// A file with other hard links keeps its blocks until the last link goes, so it frees nothing now.
    static func bytesFreed(_ r: Request) -> Int64 {
        var st = stat()
        if lstat(r.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink > 1 { return 0 }
        return r.size
    }

    /// Keeps only requests whose ancestors are not also requested (shortest paths first).
    public static func removingNested(_ requests: [Request]) -> [Request] {
        var kept = Set<String>()
        var out: [Request] = []
        for r in requests.sorted(by: { $0.path.count < $1.path.count }) where !kept.contains(r.path) {
            var ancestor = PathFormat.parent(of: r.path)
            var nested = false
            while ancestor != "/" && !ancestor.isEmpty {
                if kept.contains(ancestor) { nested = true; break }
                ancestor = PathFormat.parent(of: ancestor)
            }
            if nested || kept.contains("/") { continue }
            kept.insert(r.path)
            out.append(r)
        }
        return out
    }

    /// Returns nil on success, otherwise a readable reason.
    static func trashOne(_ path: String, home: String) -> String? {
        let verdict = SafetyGuard.check(path, home: home)
        if let reason = verdict.reason { return reason }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return nil
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
                return "Needs administrator rights."
            }
            return error.localizedDescription
        }
    }
}
