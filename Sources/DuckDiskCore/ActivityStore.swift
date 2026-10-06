import Foundation

public enum AppSupport {
    /// ~/Library/Application Support/Duck Disk
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Duck Disk", isDirectory: true)
    }
}

/// One trip to the Trash made from Duck Disk.
public struct CleanupEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var bytes: Int64
    public var items: Int
    /// Bytes per cleanup category raw value; "other" for items outside a category.
    public var categories: [String: Int64]
    /// Room the cleanup came from ("Overview", "Duplicates", "Applications", ...).
    public var source: String

    public init(date: Date = Date(), bytes: Int64, items: Int, categories: [String: Int64], source: String) {
        self.date = date
        self.bytes = bytes
        self.items = items
        self.categories = categories
        self.source = source
    }
}

public struct WeekBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let bytes: Int64
}

/// Persists cleanup events as JSON.
public final class ActivityStore: @unchecked Sendable {
    public private(set) var events: [CleanupEvent] = []
    private let file: URL

    public init(directory: URL = AppSupport.directory) {
        file = directory.appendingPathComponent("activity.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder.iso.decode([CleanupEvent].self, from: data) {
            events = decoded.sorted { $0.date > $1.date }
        }
    }

    public func record(_ event: CleanupEvent) {
        guard event.bytes > 0 || event.items > 0 else { return }
        events.insert(event, at: 0)
        save()
    }

    public func clear() {
        events = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(events) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public var totalBytes: Int64 { events.reduce(0) { $0 + $1.bytes } }

    public func bytes(since date: Date) -> Int64 {
        events.filter { $0.date >= date }.reduce(0) { $0 + $1.bytes }
    }

    /// Reclaimed bytes per calendar week, oldest first, including empty weeks.
    public func weekly(weeks: Int = 12, now: Date = Date(), calendar: Calendar = .current) -> [WeekBucket] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<weeks).reversed().compactMap { back -> WeekBucket? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let total = events.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.bytes }
            return WeekBucket(start: start, bytes: total)
        }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
