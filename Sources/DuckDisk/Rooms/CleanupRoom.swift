import DuckDiskCore
import SwiftUI

/// Caches, build files and old installers, grouped and totalled.
struct CleanupRoom: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = Set<CleanupCategory>()

    var body: some View {
        if model.phase != .ready {
            NeedsScanView(message: "Scan a drive to find caches, logs, leftovers, build files and old downloads.")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let report = model.lastReport { TrashBanner(report: report) }
            RoomScroll {
                VStack(alignment: .leading, spacing: 14) {
                    RoomHeader(title: "Cleanup",
                               subtitle: "\(ByteFormat.string(model.classification.clearableTotal)) could be cleared. Select what should go.")
                    ForEach([CleanupCategory.Group.safe, .review], id: \.self) { group in
                        SectionLabel(text: group.rawValue).padding(.top, 6)
                        ForEach(CleanupCategory.allCases.filter { $0.group == group }) { c in
                            CategorySection(category: c, expanded: binding(c))
                        }
                    }
                }
                .padding(24)
            }
            .onAppear {
                // Opened from an Overview row: show that category's items.
                if let focus = model.cleanupFocus {
                    expanded.insert(focus)
                    model.cleanupFocus = nil
                }
            }
            ActionFooter {
                Text("\(model.selection.count.formatted()) items selected")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if model.isTrashing { ProgressView().controlSize(.small) }
                Button("Move \(ByteFormat.string(model.selectedBytes)) to Trash") {
                    model.askTrash(items: model.selectedItems, source: "Cleanup")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.selectedBytes == 0 || model.isTrashing)
            }
        }
    }

    private func binding(_ c: CleanupCategory) -> Binding<Bool> {
        Binding(get: { expanded.contains(c) },
                set: { if $0 { expanded.insert(c) } else { expanded.remove(c) } })
    }
}

private struct CategorySection: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @Binding var expanded: Bool

    var body: some View {
        let items = model.items(category)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CategoryCheckbox(state: model.state(category), color: Theme.color(category)) {
                    model.toggle(category)
                }
                .disabled(items.isEmpty)
                .padding(.top, 2)
                Image(systemName: category.symbol)
                    .foregroundStyle(Theme.color(category))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title).font(.system(size: 14, weight: .semibold))
                    Text(category.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormat.string(model.classification.total(category)))
                        .font(Theme.figure(15))
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
            }
            .padding(14)

            if expanded && !items.isEmpty {
                Divider().overlay(Theme.hairline)
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        ItemRow(item: item)
                        if item.id != items.last?.id {
                            Divider().overlay(Theme.hairline).padding(.leading, 66)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 12) {
            CategoryCheckbox(state: model.selection.contains(item.path) ? .on : .off,
                             color: Theme.color(item.category)) { model.toggle(item) }
            FileIcon(path: item.path, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Text(PathFormat.abbreviated(PathFormat.parent(of: item.path)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if item.modified > .distantPast {
                Text(DateFormat.relativeString(item.modified))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(ByteFormat.string(item.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .padding(.leading, 26)
        .contentShape(Rectangle())
        .background(model.inspected?.path == item.path ? Theme.panelRaised : Color.clear)
        .onTapGesture { model.inspected = InspectedItem(path: item.path, ref: item.ref) }
        .itemContextMenu(path: item.path, size: item.size, model: model, source: "Cleanup")
    }
}
