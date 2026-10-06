import DuckDiskCore
import SwiftUI

/// Details for whatever is selected in Space, Find, Cleanup or Duplicates.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var details: FileDetails?

    var body: some View {
        Group {
            if let item = model.inspected {
                RoomScroll {
                    content(item)
                        .padding(18)
                }
                .task(id: "\(item.path)|\(model.revision)") {
                    details = await FileDetails.load(item)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Select an item to see what it is and whether it is safe to clear.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func content(_ item: InspectedItem) -> some View {
        let category = model.category(forPath: item.path)
        let verdict = SafetyGuard.check(item.path)
        let size = item.ref?.size ?? details?.size ?? 0
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                FileIcon(path: item.path, size: 56)
                Text(PathFormat.lastComponent(item.path))
                    .font(Theme.figure(16))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                Text(ByteFormat.string(size))
                    .font(Theme.figure(26))
                    .foregroundStyle(category.map { Theme.color($0) } ?? Theme.textPrimary)
            }

            if let category {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(category)).frame(width: 8, height: 8)
                        Text(category.title).font(.system(size: 12, weight: .semibold))
                        Text("· " + category.group.rawValue).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(category.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 12)
            }

            VStack(alignment: .leading, spacing: 8) {
                row("Where", PathFormat.abbreviated(PathFormat.parent(of: item.path)))
                if let ref = item.ref, let parent = ref.isDirectory ? ref.dir.parent : ref.dir, parent.size > 0 {
                    row("Of parent", String(format: "%.1f%% of %@", Double(size) / Double(parent.size) * 100,
                                            parent.isRoot ? model.target.name : parent.name))
                }
                if let d = details {
                    row("Kind", d.kind)
                    if d.isDirectory { row("Contains", "\(d.itemCount.formatted()) files") }
                    if let m = d.modified { row("Modified", DateFormat.shortString(m)) }
                    if let o = d.opened { row("Last opened", DateFormat.relativeString(o)) }
                    if let c = d.created { row("Created", DateFormat.shortString(c)) }
                }
                row("Safety", verdict.reason ?? "Can go to the Trash")
            }

            if let inside = details?.largestInside, !inside.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Largest inside").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    ForEach(inside, id: \.self) { child in
                        Button {
                            model.inspected = InspectedItem(path: child.path, ref: child)
                        } label: {
                            HStack(spacing: 6) {
                                FileIcon(path: child.path, size: 14)
                                Text(child.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.string(child.size)).monospacedDigit()
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .font(.system(size: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 8) {
                Button {
                    Actions.reveal(item.path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    model.quickLookURL = URL(fileURLWithPath: item.path)
                } label: {
                    Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    model.askTrash(paths: [(item.path, size)], source: model.room.title)
                } label: {
                    Label("Move to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!verdict.isAllowed || model.isKeptDuplicate(item.path))
                if model.isKeptDuplicate(item.path) {
                    Text("This is the copy Duck Disk keeps from a set of duplicates.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// File-system facts loaded off the main thread for the inspector.
struct FileDetails: Sendable {
    var kind = ""
    var isDirectory = false
    var itemCount = 0
    var size: Int64 = 0
    var modified: Date?
    var opened: Date?
    var created: Date?
    /// The three biggest things in a folder, worked out once per selection rather than on every redraw.
    var largestInside: [ItemRef] = []

    static func load(_ item: InspectedItem) async -> FileDetails {
        let path = item.path
        let count = item.ref?.itemCount
        let knownSize = item.ref?.size
        let inside = item.ref.map { $0.isDirectory ? Array($0.dir.sortedChildren.prefix(3)) : [] } ?? []
        return await Task.detached(priority: .userInitiated) {
            var d = FileDetails()
            let url = URL(fileURLWithPath: path)
            let v = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isDirectoryKey,
                                                     .contentModificationDateKey, .contentAccessDateKey,
                                                     .creationDateKey])
            d.kind = v?.localizedTypeDescription ?? "Item"
            d.isDirectory = v?.isDirectory ?? false
            d.modified = v?.contentModificationDate
            d.opened = v?.contentAccessDate
            d.created = v?.creationDate
            d.size = knownSize ?? DirectorySize.of(path)
            d.itemCount = count ?? 0
            d.largestInside = inside
            return d
        }.value
    }
}
