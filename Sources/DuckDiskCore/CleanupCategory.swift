import Foundation

/// Space that could be cleared, grouped the way the Overview presents it.
public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case caches, logs, leftovers, developer, aiModels, downloads, duplicates

    public var id: String { rawValue }

    public enum Group: String, Sendable { case safe = "Safe to clear", review = "Worth a look" }

    public var group: Group {
        switch self {
        case .caches, .logs, .leftovers: return .safe
        case .developer, .aiModels, .downloads, .duplicates: return .review
        }
    }

    public var title: String {
        switch self {
        case .caches: return "Caches"
        case .logs: return "Logs and temp files"
        case .leftovers: return "App leftovers"
        case .developer: return "Developer files"
        case .aiModels: return "AI models"
        case .downloads: return "Old downloads"
        case .duplicates: return "Duplicates"
        }
    }

    /// Why this category is (or may be) safe to clear. Shown in Cleanup and the inspector.
    public var explanation: String {
        switch self {
        case .caches:
            return "Apps keep caches to load faster. They rebuild them automatically when needed."
        case .logs:
            return "Diagnostic logs, crash reports and old temporary files. Nothing relies on them."
        case .leftovers:
            return "Settings and data left behind by apps that are no longer installed."
        case .developer:
            return "Build products, simulator caches and package caches. Tools re-create them, but rebuilding takes time."
        case .aiModels:
            return "Models downloaded by apps like Ollama, LM Studio and Hugging Face can be downloaded again, but they are big. Loose model files may be your own work, so check them first."
        case .downloads:
            return "Installers and files in Downloads you have not touched for a long time."
        case .duplicates:
            return "Files whose contents match another file byte for byte. One copy is always kept."
        }
    }

    public var symbol: String {
        switch self {
        case .caches: return "shippingbox"
        case .logs: return "doc.text"
        case .leftovers: return "puzzlepiece.extension"
        case .developer: return "hammer"
        case .aiModels: return "brain"
        case .downloads: return "arrow.down.circle"
        case .duplicates: return "doc.on.doc"
        }
    }

    /// Whether items start selected in a fresh scan.
    public var selectedByDefault: Bool { group == .safe }
}

/// Space that stays, shown in grey.
public enum KeptCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case media, apps, documents, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .media: return "Photos and media"
        case .apps: return "Apps"
        case .documents: return "Documents and other"
        case .system: return "System and other"
        }
    }
}

/// One thing the user could move to the Trash.
public struct CleanupItem: Identifiable, Hashable, @unchecked Sendable {
    /// Absolute path; unique across the classification.
    public var id: String { path }
    public let path: String
    public let ref: ItemRef?
    public let category: CleanupCategory
    public var size: Int64
    public let name: String
    /// Short context, e.g. the app a cache belongs to or why a download is flagged.
    public let detail: String
    public let modified: Date

    public init(path: String, ref: ItemRef?, category: CleanupCategory, size: Int64,
                name: String? = nil, detail: String = "", modified: Date = .distantPast) {
        self.path = path
        self.ref = ref
        self.category = category
        self.size = size
        self.name = name ?? PathFormat.lastComponent(path)
        self.detail = detail
        self.modified = modified
    }

    public static func == (a: CleanupItem, b: CleanupItem) -> Bool { a.path == b.path && a.size == b.size }
    public func hash(into h: inout Hasher) { h.combine(path) }
}

/// Classifier output: clearable items per category and the grey "kept" breakdown.
public struct Classification: Sendable {
    public var items: [CleanupCategory: [CleanupItem]] = [:]
    public var kept: [KeptCategory: Int64] = [:]

    public init() {}

    public func total(_ category: CleanupCategory) -> Int64 {
        items[category]?.reduce(0) { $0 + $1.size } ?? 0
    }

    public var clearableTotal: Int64 { CleanupCategory.allCases.reduce(0) { $0 + total($1) } }

    public var allItems: [CleanupItem] { CleanupCategory.allCases.flatMap { items[$0] ?? [] } }
}
