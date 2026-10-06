import DuckDiskCore
import SwiftUI

/// The heavy things come to the top: drill down folder by folder, see the drive as a treemap,
/// or list the largest files.
struct SpaceRoom: View {
    @Environment(AppModel.self) private var model
    @State private var current: DirNode?
    @AppStorage("spaceMode") private var mode = Mode.folders
    @State private var rows: [ItemRef] = []
    @State private var largest: [SearchHit] = []
    @State private var selected: ItemRef?
    @State private var metric = TreemapMetric.size
    @State private var depth = 4

    enum Mode: String, CaseIterable, Identifiable {
        case folders = "Folders", treemap = "Treemap", largest = "Largest files"
        var id: String { rawValue }
    }

    var body: some View {
        if let tree = model.tree {
            content(tree)
        } else {
            NeedsScanView(message: "Scan a drive to see which folders and files take the most space.")
        }
    }

    @ViewBuilder
    private func content(_ tree: ScanTree) -> some View {
        let dir = (current?.isRemoved == false ? current : nil) ?? tree.root
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                RoomHeader(title: "Space", subtitle: "\(ByteFormat.string(dir.size)) in \(dir.fileCount.formatted()) files") {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }
                if mode != .largest { breadcrumb(dir, tree: tree) }
                if mode == .treemap {
                    treemapControls
                    ScrollView(.horizontal, showsIndicators: false) { legend }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().overlay(Theme.hairline)

            if mode == .treemap {
                TreemapView(folder: dir, metric: metric, depth: depth, selected: $selected) { folder in
                    current = folder
                    selected = nil
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
            Group {
                if mode == .folders {
                    List(rows, id: \.self, selection: $selected) { ref in
                        SpaceRow(ref: ref, parentSize: dir.size)
                    }
                    .overlay {
                        if rows.isEmpty { Text("Empty folder").foregroundStyle(Theme.textTertiary) }
                    }
                } else {
                    List(largest, id: \.ref, selection: $selected) { hit in
                        SpaceRow(ref: hit.ref, parentSize: largest.first?.size ?? 1, showPath: true)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: ItemRef.self) { refs in
                ItemMenuItems(refs: Array(refs), model: model, source: "Space")
            } primaryAction: { refs in
                if let ref = refs.first { open(ref) }
            }
            }
        }
        .onChange(of: selected) { _, ref in
            if let ref { model.inspected = InspectedItem(path: ref.path, ref: ref) }
        }
        .task(id: "\(ObjectIdentifier(dir).hashValue)|\(model.revision)|\(mode)") {
            guard mode == .folders else { return }
            rows = dir.sortedChildren
        }
        .task(id: "\(mode)|\(model.revision)") {
            guard mode == .largest else { return }
            let found = await Task.detached(priority: .userInitiated) { TreeSearch.largestFiles(tree) }.value
            if !Task.isCancelled { largest = found }
        }
        .onKeyPress(.return) {
            if let selected { open(selected) }
            return .handled
        }
        .onKeyPress(.delete) {
            guard let parent = dir.parent, current != nil else { return .ignored }
            current = parent
            return .handled
        }
    }

    /// Size / Files / Age, depth and a colour legend, like a map key.
    private var treemapControls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $metric) {
                ForEach(TreemapMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            HStack(spacing: 6) {
                Text("Depth \(depth)").font(.system(size: 12).monospacedDigit())
                Button { depth = max(1, depth - 1) } label: { Image(systemName: "minus") }
                    .disabled(depth <= 1)
                Button { depth = min(8, depth + 1) } label: { Image(systemName: "plus") }
                    .disabled(depth >= 8)
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 10) {
            if metric == .age {
                ForEach(TreemapPalette.ages, id: \.label) { swatch($0.label, $0.color) }
            } else {
                ForEach(CleanupCategory.allCases.filter { !model.items($0).isEmpty }) { swatch($0.title, Theme.color($0)) }
                swatch("Media", TreemapPalette.media)
                swatch("Apps", TreemapPalette.apps)
                swatch("System", TreemapPalette.system)
                swatch("Other", TreemapPalette.other)
            }
        }
        .lineLimit(1)
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.75)).frame(width: 9, height: 9)
            Text(label)
        }
    }

    private func breadcrumb(_ dir: DirNode, tree: ScanTree) -> some View {
        var chain: [DirNode] = []
        var node: DirNode? = dir
        while let n = node { chain.insert(n, at: 0); node = n.parent }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, n in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    }
                    Button(n.isRoot ? model.target.name : n.name) {
                        current = n
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: n === dir ? .semibold : .regular))
                    .foregroundStyle(n === dir ? Theme.textPrimary : Theme.textSecondary)
                }
            }
        }
    }

    private func open(_ ref: ItemRef) {
        if ref.isDirectory && !ref.dir.isPackage {
            current = ref.dir
            selected = nil
        } else {
            model.quickLookURL = URL(fileURLWithPath: ref.path)
        }
    }
}

private struct SpaceRow: View {
    @Environment(AppModel.self) private var model
    let ref: ItemRef
    let parentSize: Int64
    var showPath = false

    var body: some View {
        let category = model.category(forPath: ref.path)
        let size = ref.size
        HStack(spacing: 10) {
            FileIcon(path: ref.path, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if showPath {
                    Text(PathFormat.abbreviated(PathFormat.parent(of: ref.path)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if ref.isDirectory {
                    Text("\(ref.itemCount.formatted()) files")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 12)
            SizeBar(fraction: Double(size) / Double(max(1, parentSize)),
                    color: category.map { Theme.color($0) } ?? Theme.kept)
                .frame(width: 140)
            Text(ByteFormat.string(size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .trailing)
            if ref.isDirectory && !ref.dir.isPackage {
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            } else {
                Color.clear.frame(width: 7)
            }
        }
        .padding(.vertical, 3)
    }
}
