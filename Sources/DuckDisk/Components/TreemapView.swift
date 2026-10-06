import DuckDiskCore
import SwiftUI

/// What decides a rectangle's area and colour.
enum TreemapMetric: String, CaseIterable, Identifiable {
    case size = "Size", files = "Files", age = "Age"
    var id: String { rawValue }
}

/// One rectangle in the treemap.
struct TreemapCell {
    let ref: ItemRef?
    let rect: CGRect
    let depth: Int
    /// Height of the name/size strip for folders drawn with their children inside.
    let header: CGFloat
    let label: String
    let size: Int64
    let files: Int
    let modified: Date
    let color: Color
}

/// Nested rectangles sized by bytes (or file count), coloured by cleanup category or by age.
/// Click selects, double-click zooms into a folder, hover describes the rectangle in the status line.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let folder: DirNode
    let metric: TreemapMetric
    let depth: Int
    @Binding var selected: ItemRef?
    let open: (DirNode) -> Void

    @State private var cells: [TreemapCell] = []
    @State private var layoutVersion = 0
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TreemapCanvas(cells: cells, version: layoutVersion, selected: selected)
                    .equatable()
                    // Hover is drawn on its own layer so moving the pointer never repaints every rectangle.
                    .overlay {
                        Canvas { ctx, _ in
                            if let i = hovered, i < cells.count {
                                let path = Path(roundedRect: cells[i].rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
                                ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .task(id: layoutKey(geo.size)) {
                        cells = layout(in: CGRect(origin: .zero, size: geo.size))
                        layoutVersion += 1
                        hovered = nil
                    }
                    .onContinuousHover { phase in
                        let index: Int?
                        if case .active(let point) = phase { index = cellIndex(at: point) } else { index = nil }
                        if index != hovered { hovered = index }
                    }
                    .onTapGesture(count: 2, coordinateSpace: .local) { point in
                        if let i = cellIndex(at: point), let ref = cells[i].ref, ref.isDirectory, !ref.dir.isPackage {
                            open(ref.dir)
                        }
                    }
                    .onTapGesture(count: 1, coordinateSpace: .local) { point in
                        if let i = cellIndex(at: point), let ref = cells[i].ref {
                            selected = ref
                            model.inspected = InspectedItem(path: ref.path, ref: ref)
                        }
                    }
                    .contextMenu {
                        if let i = hovered, let ref = cells[i].ref {
                            ItemMenuItems(refs: [ref], model: model, source: "Space")
                        }
                    }
                    .accessibilityLabel("Treemap of \(folder.name)")
            }
            statusLine
        }
    }

    private func layoutKey(_ size: CGSize) -> String {
        "\(ObjectIdentifier(folder).hashValue)|\(Int(size.width))x\(Int(size.height))|\(metric)|\(depth)|\(model.revision)"
    }

    private func cellIndex(at point: CGPoint) -> Int? {
        cells.indices.last { cells[$0].rect.contains(point) }
    }

    // MARK: - Layout

    private struct Child {
        let ref: ItemRef?
        let value: Double
        let label: String
        let size: Int64
        let files: Int
        let modified: Date
    }

    private func layout(in bounds: CGRect) -> [TreemapCell] {
        var out: [TreemapCell] = []
        place(folder, in: bounds.insetBy(dx: 1, dy: 1), depth: 0, into: &out)
        return out
    }

    private func value(size: Int64, files: Int) -> Double {
        metric == .files ? Double(files) : Double(size)
    }

    private func children(of dir: DirNode) -> [Child] {
        var list: [Child] = []
        for d in dir.subdirs where !d.isRemoved {
            list.append(Child(ref: ItemRef(dir: d), value: value(size: d.size, files: d.fileCount), label: d.name,
                              size: d.size, files: d.fileCount, modified: d.modifiedDate))
        }
        for f in dir.files where !f.removed {
            list.append(Child(ref: ItemRef(dir: dir, fileName: f.name), value: value(size: f.size, files: 1),
                              label: f.name, size: f.size, files: 1, modified: f.modifiedDate))
        }
        list = list.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        // Keep the picture readable: show the biggest entries, merge the long tail.
        let limit = 150
        if list.count > limit {
            let tail = list[limit...]
            list = Array(list[..<limit])
            let size = tail.reduce(Int64(0)) { $0 + $1.size }
            let files = tail.reduce(0) { $0 + $1.files }
            list.append(Child(ref: nil, value: tail.reduce(0) { $0 + $1.value },
                              label: "\(tail.count.formatted()) smaller items", size: size, files: files,
                              modified: .distantPast))
        }
        return list
    }

    private func place(_ dir: DirNode, in rect: CGRect, depth level: Int, into out: inout [TreemapCell]) {
        let list = children(of: dir)
        let rects = Treemap.squarify(list.map(\.value), in: rect)
        for (child, r) in zip(list, rects) where r.width >= 2 && r.height >= 2 {
            let isFolder = child.ref?.isDirectory == true && child.ref?.dir.isPackage == false
            let canNest = isFolder && level + 1 < depth && r.width > 40 && r.height > 34
            let header: CGFloat = canNest ? 17 : 0
            out.append(TreemapCell(ref: child.ref, rect: r, depth: level, header: header, label: child.label,
                                   size: child.size, files: child.files, modified: child.modified,
                                   color: color(for: child)))
            if canNest, let ref = child.ref {
                let inner = CGRect(x: r.minX + 2, y: r.minY + header, width: r.width - 4, height: r.height - header - 2)
                if inner.width > 4 && inner.height > 4 {
                    place(ref.dir, in: inner, depth: level + 1, into: &out)
                }
            }
        }
    }

    // MARK: - Colour

    private func color(for child: Child) -> Color {
        guard let ref = child.ref else { return Theme.kept.opacity(0.5) }
        if metric == .age { return TreemapPalette.age(child.modified) }
        if let category = model.category(forPath: ref.path) { return Theme.color(category) }
        if ref.isDirectory, let category = model.dominantCategory(inside: ref.path, size: child.size) {
            return Theme.color(category)
        }
        return TreemapPalette.kept(ref)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 8) {
            if let i = hovered, i < cells.count {
                let cell = cells[i]
                Image(systemName: cell.ref?.isDirectory == true ? "folder" : "doc")
                Text(cell.ref.map { PathFormat.abbreviated($0.path) } ?? cell.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteFormat.string(cell.size)).foregroundStyle(Theme.textPrimary)
                if cell.files > 1 { Text("\(cell.files.formatted()) files") }
                if cell.modified > .distantPast { Text("changed \(DateFormat.relativeString(cell.modified))") }
            } else {
                Text("Click to inspect · double-click a folder to open it · right-click for actions")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .frame(height: 24)
    }
}

/// Draws the rectangles. Equatable on the layout version and selection, so hovering does not repaint it.
private struct TreemapCanvas: View, Equatable {
    let cells: [TreemapCell]
    let version: Int
    let selected: ItemRef?

    static func == (a: TreemapCanvas, b: TreemapCanvas) -> Bool {
        a.version == b.version && a.selected == b.selected
    }

    var body: some View {
        Canvas { ctx, _ in draw(&ctx) }
    }

    // MARK: - Drawing

    func draw(_ ctx: inout GraphicsContext) {
        for cell in cells {
            let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
            let path = Path(roundedRect: rect, cornerRadius: cell.header > 0 ? 3 : 2)
            let isFolderFrame = cell.header > 0
            ctx.fill(path, with: .color(cell.color.opacity(isFolderFrame ? 0.22 : 0.62)))
            ctx.stroke(path, with: .color(Theme.background), lineWidth: 1)
            if isFolderFrame {
                label(&ctx, cell, in: CGRect(x: rect.minX + 4, y: rect.minY + 1, width: rect.width - 8, height: 15),
                      bold: true)
            } else if rect.width > 56 && rect.height > 30 {
                label(&ctx, cell, in: CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 15),
                      bold: false)
            }
            if cell.ref.map({ $0 == selected }) == true {
                ctx.stroke(path, with: .color(Theme.color(.developer)), lineWidth: 2)
            }
        }
    }

    func label(_ ctx: inout GraphicsContext, _ cell: TreemapCell, in rect: CGRect, bold: Bool) {
        let name = Text(cell.label).font(.system(size: 11, weight: bold ? .semibold : .regular))
            .foregroundStyle(.white.opacity(0.92))
        let size = Text(ByteFormat.string(cell.size)).font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        let sizeWidth: CGFloat = rect.width > 120 ? 60 : 0
        let nameRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - sizeWidth - 4, height: rect.height)
        ctx.drawLayer { layer in
            layer.clip(to: Path(nameRect))
            layer.draw(name, at: CGPoint(x: nameRect.minX, y: nameRect.midY), anchor: .leading)
        }
        if sizeWidth > 0 {
            ctx.draw(size, at: CGPoint(x: rect.maxX, y: rect.midY), anchor: .trailing)
        }
    }

}

/// Colours for space that stays, and for the Age view.
enum TreemapPalette {
    static let media = Color(nsColor: NSColor(hex: 0x8E6FD1))
    static let apps = Color(nsColor: NSColor(hex: 0x5A7BC4))
    static let system = Color(nsColor: NSColor(hex: 0x6B7385))
    static let other = Color(nsColor: NSColor(hex: 0x7A7A80))

    static let systemRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores"]

    static func kept(_ ref: ItemRef) -> Color {
        let path = ref.path
        if path.hasSuffix(".app") || PathFormat.isInside(path, "/Applications") { return apps }
        if systemRoots.contains(where: { PathFormat.isInside(path, $0) }) { return system }
        if ref.size > 0 && Double(ref.mediaSize) / Double(ref.size) > 0.5 { return media }
        return other
    }

    static let ages: [(days: Double, label: String, color: Color)] = [
        (7, "This week", Color(nsColor: NSColor(hex: 0xE5584F))),
        (30, "This month", Color(nsColor: NSColor(hex: 0xE8A33D))),
        (180, "6 months", Color(nsColor: NSColor(hex: 0xC9B458))),
        (365, "This year", Color(nsColor: NSColor(hex: 0x36B3C4))),
        (.infinity, "Older", Color(nsColor: NSColor(hex: 0x4C6A9C))),
    ]

    static func age(_ date: Date) -> Color {
        let days = Date().timeIntervalSince(date) / 86_400
        return ages.first { days <= $0.days }?.color ?? other
    }
}
