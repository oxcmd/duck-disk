import DuckDiskCore
import SwiftUI

/// Any file, found as you type. Searches the scan index, hidden folders included.
struct FindRoom: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var kind = SearchQuery.Kind.any
    @State private var minSize: Int64 = 0
    @State private var includeHidden = true
    @State private var hits: [SearchHit] = []
    @State private var elapsed: TimeInterval = 0
    @State private var searching = false
    @State private var selected: ItemRef?
    @FocusState private var focused: Bool

    private let sizes: [(String, Int64)] = [("Any size", 0), ("Over 1 MB", 1_000_000), ("Over 100 MB", 100_000_000),
                                            ("Over 1 GB", 1_000_000_000)]

    var body: some View {
        if let tree = model.searchTree {
            content(tree)
        } else {
            NeedsScanView(message: "Scan a drive and Find searches every file name on it as you type, hidden folders too.")
        }
    }

    /// Shown when results come from the saved index rather than a scan made in this session.
    private var indexNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Searching the index from \(DateFormat.relativeString(model.indexTree?.startedAt ?? Date())). Scan again for fresh results.")
            if model.phase == .scanning || model.phase == .analysing { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }

    private func content(_ tree: ScanTree) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                RoomHeader(title: "Find")
                if model.tree == nil && model.indexTree != nil { indexNote }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Search \(tree.stats.files.formatted()) files", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                    if searching { ProgressView().controlSize(.small) }
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))

                HStack(spacing: 12) {
                    Picker("", selection: $kind) {
                        ForEach(SearchQuery.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 380)
                    Picker("", selection: $minSize) {
                        ForEach(sizes, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Toggle("Hidden files", isOn: $includeHidden).toggleStyle(.checkbox)
                    Spacer()
                    if !text.isEmpty && !searching {
                        Text("\(hits.count == 1000 ? "1,000+" : hits.count.formatted()) results · \(Int(elapsed * 1000)) ms")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().overlay(Theme.hairline)

            List(hits, id: \.ref, selection: $selected) { hit in
                FindRow(hit: hit)
            }
            .contextMenu(forSelectionType: ItemRef.self) { refs in
                ItemMenuItems(refs: Array(refs), model: model, source: "Find")
            } primaryAction: { refs in
                if let ref = refs.first { Actions.reveal(ref.path) }
            }
            .onChange(of: selected) { _, ref in
                if let ref { model.inspected = InspectedItem(path: ref.path, ref: ref) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if text.isEmpty {
                    Text("Type part of a name. Results are sorted by size.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                } else if hits.isEmpty && !searching {
                    Text("Nothing called “\(text)”.").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .onAppear { focused = true }
        .task(id: "\(text)|\(kind)|\(minSize)|\(includeHidden)|\(model.revision)") {
            await search(tree)
        }
    }

    private func search(_ tree: ScanTree) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            return
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        var query = SearchQuery(text: text)
        query.kind = kind
        query.minSize = minSize
        query.includeHidden = includeHidden
        searching = true
        let cancelled = CancelFlag()
        let started = Date()
        let fromIndex = model.tree == nil
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                let hits = TreeSearch.run(tree, query) { cancelled.isSet }
                // A saved index can list files that have gone since; show only what still exists.
                return fromIndex ? hits.filter { access($0.ref.path, F_OK) == 0 } : hits
            }.value
        } onCancel: {
            cancelled.set()
        }
        guard !Task.isCancelled else { return }
        hits = result
        elapsed = Date().timeIntervalSince(started)
        searching = false
    }
}

/// Thread-safe flag for cancelling detached work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private struct FindRow: View {
    @Environment(AppModel.self) private var model
    let hit: SearchHit

    var body: some View {
        let category = model.category(forPath: hit.ref.path)
        HStack(spacing: 10) {
            FileIcon(path: hit.ref.path, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.ref.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let category {
                        Text(category.title)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.color(category).opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.color(category))
                    }
                }
                Text(PathFormat.abbreviated(PathFormat.parent(of: hit.ref.path)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(DateFormat.relativeString(hit.modified))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .trailing)
            Text(ByteFormat.string(hit.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
