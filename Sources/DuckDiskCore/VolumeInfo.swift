import Foundation

/// Capacity figures for a mounted volume.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let total: Int64
    /// Available for important usage (includes purgeable space), matching Finder's "available".
    public let available: Int64
    public let isInternal: Bool
    public let isRoot: Bool

    public var used: Int64 { max(0, total - available) }

    /// Volume containing `path`.
    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let volURL = v.volume else { return nil }
        return make(volURL)
    }

    /// Browsable mounted volumes, boot volume first.
    public static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let vols = urls.compactMap { url -> VolumeInfo? in
            let rv = try? url.resourceValues(forKeys: [.volumeIsBrowsableKey])
            guard rv?.volumeIsBrowsable ?? true else { return nil }
            return make(url)
        }
        return vols.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    static func make(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeIsInternalKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        let available = important > 0 ? important : Int64(v.volumeAvailableCapacity ?? 0)
        let path = url.path.isEmpty ? "/" : url.path
        return VolumeInfo(path: path, name: v.volumeName ?? PathFormat.lastComponent(path),
                          total: total, available: available,
                          isInternal: v.volumeIsInternal ?? false, isRoot: path == "/")
    }
}
