import AppKit
import DuckDiskCore
import Observation
import SwiftUI

enum Room: String, CaseIterable, Identifiable {
    case overview, find, space, cleanup, duplicates, applications, monitor, compress, activity

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .find: return "magnifyingglass"
        case .space: return "square.grid.2x2"
        case .cleanup: return "trash"
        case .duplicates: return "doc.on.doc"
        case .applications: return "macwindow"
        case .monitor: return "waveform.path.ecg"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .activity: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct ScanTarget: Hashable, Identifiable {
    let path: String
    let name: String
    let isVolume: Bool
    var id: String { path }
}

enum ScanPhase: Equatable { case idle, scanning, analysing, ready }
enum DuplicatePhase: Equatable { case idle, running, done }

/// Something the user asked to move to the Trash, waiting for confirmation.
struct TrashRequest: Identifiable {
    let id = UUID()
    let items: [TrashService.Request]
    let source: String
    var onDone: ((TrashService.Result) -> Void)?
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct TrashReport: Identifiable {
    let id = UUID()
    let freed: Int64
    let count: Int
    let failures: [TrashService.Failure]
}

/// What the inspector shows.
struct InspectedItem: Equatable {
    let path: String
    let ref: ItemRef?
}

/// User preferences (UserDefaults keys and defaults).
enum Prefs {
    static let appearance = "appearance"
    static let oldDownloadDays = "oldDownloadDays"
    static let staleProjectDays = "staleProjectDays"
    static let duplicateMinSize = "duplicateMinSize"
    static let excludedPaths = "excludedPaths"
    static let autoSnapshot = "autoSnapshot"
    static let keepIndex = "keepIndex"

    static func register() {
        UserDefaults.standard.register(defaults: [
            appearance: "system", oldDownloadDays: 90, staleProjectDays: 30,
            duplicateMinSize: 1_000_000, excludedPaths: [String](), autoSnapshot: true, keepIndex: true,
        ])
    }

    static var excluded: [String] { UserDefaults.standard.stringArray(forKey: excludedPaths) ?? [] }
}

@MainActor
@Observable
final class AppModel {
    var room: Room = .overview
    var volumes: [VolumeInfo] = []
    var target: ScanTarget
    var phase: ScanPhase = .idle
    var progress = ScanProgress()
    var tree: ScanTree?
    var classification = Classification()
    /// Selected cleanup item paths.
    var selection = Set<String>()
    /// Bumped whenever the tree changes, so views re-read sizes.
    var revision = 0

    var inspected: InspectedItem?
    var showInspector = true
    var quickLookURL: URL?
    var pendingTrash: TrashRequest?
    var lastReport: TrashReport?
    var isTrashing = false
    var cleanupFocus: CleanupCategory?
    var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Changes whenever scan results are discarded; rooms are rebuilt so no view keeps old tree references.
    private(set) var scanGeneration = 0

    /// The saved index of the current target, used by Find until a scan finishes.
    var indexTree: ScanTree?
    /// The tree Find searches: the live scan, or the saved index from an earlier one.
    var searchTree: ScanTree? { tree ?? indexTree }

    /// Compress room queue. Lives here so leaving the room does not orphan running work.
    var compressJobs: [CompressJob] = []
    var compressRunning = false

    var duplicateGroups: [DuplicateGroup] = []
    /// Group id → path of the copy to keep.
    var duplicateKeep: [String: String] = [:]
    var duplicatePhase: DuplicatePhase = .idle
    var duplicateProgress = DuplicateFinder.Progress()

    let activity = ActivityStore()
    let snapshots = SnapshotStore()
    var activityRevision = 0

    /// Lazily built Applications room data.
    var apps: [AppInfo] = []
    var appsLoading = false
    var appsProgress = (done: 0, total: 0)

    @ObservationIgnored private var scanner: DiskScanner?
    /// Serial queue for saving, loading and deleting the Find index, so the three never overlap.
    @ObservationIgnored private let indexQueue = DispatchQueue(label: "app.duckdisk.index", qos: .utility)
    @ObservationIgnored private var duplicateFinder: DuplicateFinder?
    @ObservationIgnored private var context: ClassifierContext?
    /// path → category, for colouring rows and the inspector.
    @ObservationIgnored private(set) var categoryByPath: [String: CleanupCategory] = [:]
    /// For every folder that contains cleanup items: clearable bytes inside it per category. Built only when the
    /// treemap asks, and kept until the classification changes.
    @ObservationIgnored private var clearableInside: (version: Int, map: [String: [CleanupCategory: Int64]])?
    /// Bumped whenever the category index changes, so views that colour by category redraw.
    private(set) var classificationVersion = 0

    init() {
        Prefs.register()
        let vols = VolumeInfo.mounted()
        volumes = vols
        if let boot = vols.first(where: { $0.isRoot }) {
            target = ScanTarget(path: boot.path, name: boot.name, isVolume: true)
        } else {
            target = ScanTarget(path: NSHomeDirectory(), name: "Home", isVolume: false)
        }
        #if DEBUG
        // Development aid: `DuckDisk -scanPath <folder>` scans that folder on launch.
        if let path = UserDefaults.standard.string(forKey: "scanPath") {
            target = ScanTarget(path: path, name: PathFormat.lastComponent(path), isVolume: false)
            Task { @MainActor in
                self.startScan()
                DevSnapshots.runIfRequested(self)
            }
        }
        #endif
        loadIndex()
    }

    // MARK: - Saved index

    /// Loads the saved index for the current target in the background.
    func loadIndex() {
        dropIndexTree()
        guard UserDefaults.standard.bool(forKey: Prefs.keepIndex) else { return }
        let path = target.path
        let generation = scanGeneration
        Task {
            let loaded: ScanTree? = await withCheckedContinuation { cont in
                indexQueue.async { cont.resume(returning: ScanIndex.load(root: path)) }
            }
            guard generation == scanGeneration, tree == nil, target.path == path,
                  UserDefaults.standard.bool(forKey: Prefs.keepIndex) else { return }
            indexTree = loaded
        }
    }

    /// Writes the index after a scan, unless the setting was turned off by the time the queue gets to it.
    private func saveIndex(_ tree: ScanTree) {
        indexQueue.async {
            guard UserDefaults.standard.bool(forKey: Prefs.keepIndex) else { return }
            try? ScanIndex.save(tree)
        }
    }

    /// Turns the saved index off: drops the loaded one and deletes Duck Disk's index files. The serial queue
    /// runs the deletion after any save that was already queued.
    func forgetIndexes() {
        dropIndexTree()
        indexQueue.async { ScanIndex.removeAll() }
    }

    /// Releases the loaded index off the main thread; freeing millions of nodes takes a moment.
    private func dropIndexTree() {
        guard let old = indexTree else { return }
        indexTree = nil
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
    }

    // MARK: - Targets

    var targetVolume: VolumeInfo? {
        volumes.first { $0.path == target.path } ?? VolumeInfo.forPath(target.path)
    }

    func refreshVolumes() {
        volumes = VolumeInfo.mounted()
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    func choose(_ newTarget: ScanTarget) {
        guard newTarget != target else { return }
        cancelScan()
        target = newTarget
        resetResults()
        phase = .idle
        loadIndex()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder or drive to scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(ScanTarget(path: url.path, name: url.lastPathComponent, isVolume: false))
    }

    // MARK: - Scanning

    private func resetResults() {
        duplicateFinder?.cancel()
        duplicateFinder = nil
        scanGeneration += 1
        // Freeing millions of nodes takes a moment; do it off the main thread.
        if let old = tree {
            tree = nil
            DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
        }
        classification = Classification()
        selection = []
        categoryByPath = [:]
        clearableInside = nil
        duplicateGroups = []
        duplicateKeep = [:]
        duplicatePhase = .idle
        inspected = nil
        lastReport = nil
        revision += 1
    }

    func startScan() {
        guard phase != .scanning && phase != .analysing else { return }
        resetResults()
        hasFullDiskAccess = FullDiskAccess.isGranted
        phase = .scanning
        progress = ScanProgress()

        var options = ScanOptions()
        options.excludedPaths = Set(Prefs.excluded)
        let scanner = DiskScanner(rootPath: target.path, options: options)
        self.scanner = scanner
        let generation = scanGeneration

        Task {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    self.progress = scanner.progress
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let result = await scanner.scan()
            poll.cancel()
            guard self.scanner === scanner else { return }
            self.scanner = nil
            guard let result else {
                phase = .idle
                return
            }
            progress = scanner.progress
            phase = .analysing
            await analyse(result, generation: generation)
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        if phase == .scanning { phase = .idle }
    }

    private func analyse(_ tree: ScanTree, generation: Int) async {
        let defaults = UserDefaults.standard
        let oldDays = defaults.integer(forKey: Prefs.oldDownloadDays)
        let staleDays = defaults.integer(forKey: Prefs.staleProjectDays)
        var dupOptions = DuplicateFinder.Options()
        dupOptions.minSize = Int64(defaults.integer(forKey: Prefs.duplicateMinSize))

        #if DEBUG
        // Development aid: `-homeOverride <folder>` treats a fixture folder as the home folder.
        let home = defaults.string(forKey: "homeOverride") ?? NSHomeDirectory()
        #else
        let home = NSHomeDirectory()
        #endif
        dupOptions.home = home
        let (classification, ctx, finder) = await Task.detached(priority: .userInitiated) {
            var ctx = ClassifierContext(home: home, registry: InstalledAppRegistry.load())
            ctx.oldDownloadDays = oldDays
            ctx.staleProjectDays = staleDays
            let c = Classifier.classify(tree, context: ctx)
            return (c, ctx, DuplicateFinder(tree: tree, options: dupOptions))
        }.value
        // The user may have picked another target or rescanned meanwhile.
        guard generation == scanGeneration else {
            finder.cancel()
            return
        }

        self.tree = tree
        self.context = ctx
        self.classification = classification
        selection = Set(classification.allItems.filter { $0.category.selectedByDefault }.map(\.path))
        rebuildCategoryIndex()
        phase = .ready
        revision += 1
        if defaults.bool(forKey: Prefs.autoSnapshot) {
            snapshots.save(Snapshot.make(tree: tree, classification: classification))
            activityRevision += 1
        }
        dropIndexTree()
        saveIndex(tree)
        findDuplicates(finder)
    }

    private func findDuplicates(_ finder: DuplicateFinder) {
        duplicateFinder = finder
        duplicatePhase = .running
        duplicateProgress = finder.progress
        Task {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    self.duplicateProgress = finder.progress
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let groups = await finder.run()
            poll.cancel()
            guard duplicateFinder === finder else { return }
            duplicateFinder = nil
            duplicateGroups = groups.compactMap { g in
                var g = g
                g.files = g.files.filter { !($0.ref?.isRemoved ?? false) }
                return g.files.count > 1 ? g : nil
            }
            duplicateKeep = [:]
            duplicatePhase = .done
            rebuildDuplicateItems()
        }
    }

    /// Duplicates category = copies that would free space, except the kept one and files other categories
    /// already list. Re-picks the kept copy whenever it is gone.
    func rebuildDuplicateItems() {
        let others = Set(classification.allItems.filter { $0.category != .duplicates }.map(\.path))
        let resolved = DuplicateSelection.resolve(duplicateGroups, keep: duplicateKeep, otherItemPaths: others,
                                                  home: context?.home ?? NSHomeDirectory())
        duplicateKeep = resolved.keep
        selection.subtract(duplicateKeep.values)
        classification.items[.duplicates] = resolved.items
        refreshKept()
        rebuildCategoryIndex()
    }

    func isKeptDuplicate(_ path: String) -> Bool { duplicateKeep.values.contains(path) }

    func setKeep(_ path: String, in group: DuplicateGroup) {
        duplicateKeep[group.id] = path
        selection.remove(path)
        rebuildDuplicateItems()
    }

    private func refreshKept() {
        guard let tree, let context else { return }
        classification.kept = Classifier.keptBreakdown(tree, items: classification.allItems, context)
    }

    private func rebuildCategoryIndex() {
        var map: [String: CleanupCategory] = [:]
        for i in classification.allItems { map[i.path] = i.category }
        categoryByPath = map
        clearableInside = nil
        classificationVersion += 1
    }

    private func clearableInsideMap() -> [String: [CleanupCategory: Int64]] {
        if let cached = clearableInside, cached.version == classificationVersion { return cached.map }
        var inside: [String: [CleanupCategory: Int64]] = [:]
        for i in classification.allItems {
            var p = PathFormat.parent(of: i.path)
            while p.count > 1 {
                inside[p, default: [:]][i.category, default: 0] += i.size
                p = PathFormat.parent(of: p)
            }
        }
        clearableInside = (classificationVersion, inside)
        return inside
    }

    /// The cleanup category that makes up at least half of a folder's bytes, if any.
    func dominantCategory(inside path: String, size: Int64) -> CleanupCategory? {
        guard size > 0, let byCategory = clearableInsideMap()[path],
              let top = byCategory.max(by: { $0.value < $1.value }), top.value * 2 >= size else { return nil }
        return top.key
    }

    /// Category of a path or of the nearest cleanup item containing it.
    func category(forPath path: String) -> CleanupCategory? {
        var p = path
        while p.count > 1 {
            if let c = categoryByPath[p] { return c }
            p = PathFormat.parent(of: p)
        }
        return nil
    }

    // MARK: - Selection

    func items(_ c: CleanupCategory) -> [CleanupItem] { classification.items[c] ?? [] }

    func state(_ c: CleanupCategory) -> CheckState {
        let list = items(c)
        guard !list.isEmpty else { return .off }
        let count = list.reduce(0) { $0 + (selection.contains($1.path) ? 1 : 0) }
        return count == 0 ? .off : count == list.count ? .on : .mixed
    }

    func toggle(_ c: CleanupCategory) {
        let paths = items(c).map(\.path)
        if state(c) == .on { selection.subtract(paths) } else { selection.formUnion(paths) }
    }

    func toggle(_ item: CleanupItem) {
        if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
    }

    var selectedItems: [CleanupItem] { classification.allItems.filter { selection.contains($0.path) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func selectedBytes(in c: CleanupCategory) -> Int64 {
        items(c).reduce(0) { $0 + (selection.contains($1.path) ? $1.size : 0) }
    }

    // MARK: - Trash

    func askTrash(items: [CleanupItem], source: String, onDone: ((TrashService.Result) -> Void)? = nil) {
        askTrash(paths: items.map { ($0.path, $0.size) }, source: source, onDone: onDone)
    }

    func askTrash(paths: [(String, Int64)], source: String, onDone: ((TrashService.Result) -> Void)? = nil) {
        guard !isTrashing else { return }
        let requests = protectingKeptCopies(paths.map { TrashService.Request(path: $0.0, size: $0.1) })
        guard !requests.isEmpty else { return }
        pendingTrash = TrashRequest(items: requests, source: source, onDone: onDone)
    }

    /// Never lets a request remove the kept copy of a duplicate set, nor every remaining copy of a set.
    private func protectingKeptCopies(_ requests: [TrashService.Request]) -> [TrashService.Request] {
        DuplicateSelection.protect(requests, groups: duplicateGroups, keep: duplicateKeep)
    }

    func confirmTrash() {
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        isTrashing = true
        Task {
            let result = await TrashService.trash(request.items)
            var categories: [String: Int64] = [:]
            for (path, bytes) in result.trashed {
                categories[category(forPath: path)?.rawValue ?? "other", default: 0] += bytes
            }
            apply(result)
            activity.record(CleanupEvent(bytes: result.freedBytes, items: result.trashed.count,
                                         categories: categories, source: request.source))
            activityRevision += 1
            lastReport = TrashReport(freed: result.freedBytes, count: result.trashed.count,
                                     failures: result.failures)
            isTrashing = false
            request.onDone?(result)
            refreshVolumes()
        }
    }

    /// Updates the tree, items, duplicates and selection after items reached the Trash.
    func apply(_ result: TrashService.Result) {
        let trashed = Set(result.trashed.keys)
        guard !trashed.isEmpty else { return }
        func covered(_ path: String) -> Bool {
            var p = path
            while p.count > 1 {
                if trashed.contains(p) { return true }
                p = PathFormat.parent(of: p)
            }
            return false
        }
        for t in [tree, indexTree].compactMap({ $0 }) {
            for path in trashed {
                if let ref = t.ref(forPath: path) { t.remove(ref) }
            }
        }
        for c in CleanupCategory.allCases where c != .duplicates {
            classification.items[c] = items(c).filter { !covered($0.path) }.map { item in
                guard let ref = item.ref, !ref.isRemoved else { return item }
                var copy = item
                copy.size = ref.size
                return copy
            }.filter { $0.size > 0 }
        }
        duplicateGroups = duplicateGroups.compactMap { g in
            var g = g
            g.files.removeAll { covered($0.path) }
            return g.files.count > 1 ? g : nil
        }
        selection = selection.filter { !covered($0) }
        if let inspected, covered(inspected.path) { self.inspected = nil }
        rebuildDuplicateItems()
        revision += 1
    }

    // MARK: - Compress

    /// Compresses waiting jobs one at a time. Originals only ever go to the Trash.
    func runCompression(video: VideoQuality, photo: PhotoQuality, replaceOriginals: Bool) {
        guard !compressRunning else { return }
        compressRunning = true
        Task {
            while let index = compressJobs.firstIndex(where: { $0.result == nil && $0.progress == nil }) {
                compressJobs[index].progress = 0
                let job = compressJobs[index]
                let result = await MediaCompressor.compress(job.path, video: video, photo: photo,
                                                            replaceOriginal: replaceOriginals) { p in
                    Task { @MainActor in
                        if let i = self.compressJobs.firstIndex(where: { $0.id == job.id }) {
                            self.compressJobs[i].progress = p
                        }
                    }
                }
                if let i = compressJobs.firstIndex(where: { $0.id == job.id }) { compressJobs[i].result = result }
                if case .compressed(_, let replaced) = result.outcome {
                    if replaced {
                        var trashed = TrashService.Result()
                        trashed.trashed[job.path] = result.originalSize
                        apply(trashed)
                    }
                    activity.record(CleanupEvent(bytes: result.saved, items: 1,
                                                 categories: ["compress": result.saved], source: "Compress"))
                    activityRevision += 1
                }
            }
            compressRunning = false
            refreshVolumes()
        }
    }

    // MARK: - Applications

    func loadApps(force: Bool = false) {
        guard !appsLoading, force || apps.isEmpty else { return }
        appsLoading = true
        appsProgress = (0, 0)
        Task {
            let list = await Task.detached(priority: .userInitiated) {
                AppInventory.load { done, total in
                    Task { @MainActor in self.appsProgress = (done, total) }
                }
            }.value
            apps = list
            appsLoading = false
        }
    }
}
