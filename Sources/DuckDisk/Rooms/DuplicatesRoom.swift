import DuckDiskCore
import SwiftUI

/// Files that exist twice, matched byte for byte. One copy per set is always kept.
struct DuplicatesRoom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.phase != .ready {
            NeedsScanView(message: "Scan a drive and Duck Disk compares files of the same size, byte for byte, to find copies.")
        } else if model.duplicatePhase == .running {
            progressView
        } else if model.duplicateGroups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Theme.positive)
                Text("No duplicates found").font(Theme.figure(17))
                Text("Files over \(ByteFormat.string(Int64(UserDefaults.standard.integer(forKey: Prefs.duplicateMinSize)))) were compared. System folders, app bundles and libraries are left out.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            results
        }
    }

    private var progressView: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.duplicateProgress.fraction)
                .frame(width: 300)
            Text(model.duplicateProgress.stage + "…").font(.system(size: 13, weight: .medium))
            Text("Only files with the same size are read, so this is quicker than it sounds.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        let items = model.items(.duplicates)
        let wasted = model.duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        return VStack(spacing: 0) {
            if let report = model.lastReport { TrashBanner(report: report) }
            RoomScroll {
                VStack(alignment: .leading, spacing: 14) {
                    RoomHeader(title: "Duplicates",
                               subtitle: "\(model.duplicateGroups.count) set\(model.duplicateGroups.count == 1 ? "" : "s") of identical files · \(ByteFormat.string(wasted)) taken by extra copies") {
                        HStack {
                            Button("Select All Copies") { model.selection.formUnion(items.map(\.path)) }
                                .buttonStyle(QuietButtonStyle())
                            Button("Select None") { model.selection.subtract(items.map(\.path)) }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(model.duplicateGroups) { group in
                            GroupCard(group: group)
                        }
                    }
                }
                .padding(24)
            }
            ActionFooter {
                let selected = model.selectedBytes(in: .duplicates)
                Text("The copy marked Keep stays where it is.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Move \(ByteFormat.string(selected)) of Copies to Trash") {
                    model.askTrash(items: items.filter { model.selection.contains($0.path) }, source: "Duplicates")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == 0 || model.isTrashing)
            }
        }
    }
}

private struct GroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        let keep = model.duplicateKeep[group.id]
        let listed = Set(model.items(.duplicates).map(\.path))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FileIcon(path: group.files.first?.path ?? "", size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(group.files.count) copies of \(ByteFormat.string(group.size))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(ByteFormat.string(group.wastedBytes))
                    .font(Theme.figure(14))
                    .foregroundStyle(Theme.color(.duplicates))
            }
            .padding(12)
            Divider().overlay(Theme.hairline)
            ForEach(group.files) { file in
                FileRow(file: file, group: group, isKept: file.path == keep,
                        isListed: listed.contains(file.path))
            }
            .padding(.vertical, 4)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: DuplicateFile
    let group: DuplicateGroup
    let isKept: Bool
    /// False when another category already covers the file or it is a clone that frees nothing.
    let isListed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isKept {
                    badge("Keep", Theme.positive)
                } else if isListed {
                    CategoryCheckbox(state: model.selection.contains(file.path) ? .on : .off,
                                     color: Theme.color(.duplicates)) {
                        if model.selection.contains(file.path) { model.selection.remove(file.path) }
                        else { model.selection.insert(file.path) }
                    }
                } else if let other = model.category(forPath: file.path), other != .duplicates {
                    badge(other.title, Theme.color(other)).help("Listed under \(other.title) instead")
                } else {
                    badge("Clone", Theme.textTertiary).help("Shares storage with another copy, so it frees no space")
                }
            }
            .frame(width: 60)
            VStack(alignment: .leading, spacing: 1) {
                Text(PathFormat.lastComponent(file.path))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(PathFormat.abbreviated(PathFormat.parent(of: file.path))) · modified \(DateFormat.relativeString(file.modified))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isKept {
                Button("Keep This") { model.setKeep(file.path, in: group) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(model.inspected?.path == file.path ? Theme.panelRaised : Color.clear)
        .onTapGesture { model.inspected = InspectedItem(path: file.path, ref: file.ref) }
        .contextMenu {
            Button("Reveal in Finder") { Actions.reveal(file.path) }
            Button("Quick Look") { model.quickLookURL = URL(fileURLWithPath: file.path) }
            if !isKept {
                Divider()
                Button("Move to Trash…") { model.askTrash(paths: [(file.path, file.size)], source: "Duplicates") }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
