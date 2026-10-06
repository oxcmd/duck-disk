import Charts
import DuckDiskCore
import SwiftUI

/// The space you got back, week by week, and how the drive changed between snapshots.
struct ActivityRoom: View {
    @Environment(AppModel.self) private var model
    @State private var olderID: UUID?
    @State private var newerID: UUID?
    @State private var comparison: SnapshotComparison?

    var body: some View {
        let _ = model.activityRevision
        RoomScroll {
            VStack(alignment: .leading, spacing: 18) {
                RoomHeader(title: "Activity", subtitle: "Everything Duck Disk moved to the Trash, and how your drive changed")
                stats
                weeklyChart
                snapshotsSection
                eventsSection
            }
            .padding(24)
        }
        .onAppear(perform: pickDefaults)
        .onChange(of: model.activityRevision) { _, _ in pickDefaults() }
        .task(id: "\(olderID?.uuidString ?? "")|\(newerID?.uuidString ?? "")") { compare() }
    }

    // MARK: Reclaimed space

    private var stats: some View {
        let now = Date()
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return HStack(spacing: 14) {
            stat("This week", model.activity.bytes(since: weekStart))
            stat("Last 30 days", model.activity.bytes(since: now.addingTimeInterval(-30 * 86_400)))
            stat("All time", model.activity.totalBytes)
            stat("Cleanups", nil, count: model.activity.events.count)
        }
    }

    private func stat(_ label: String, _ bytes: Int64?, count: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            Text(bytes.map(ByteFormat.string) ?? "\(count ?? 0)").font(Theme.figure(22))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var weeklyChart: some View {
        let weeks = model.activity.weekly(weeks: 12)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Space recovered per week")
            Chart(weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Recovered", Double(week.bytes) / 1_000_000_000))
                    .foregroundStyle(Theme.color(.developer).gradient)
                    .cornerRadius(4)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.0f GB", v)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 180)
            .overlay {
                if weeks.allSatisfy({ $0.bytes == 0 }) {
                    Text("Nothing cleared in the last 12 weeks yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .card()
    }

    // MARK: Snapshots

    private var snapshotsSection: some View {
        let list = model.snapshots.summaries
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Snapshots")
                Spacer()
                Button("Take Snapshot") {
                    guard let tree = model.tree else { return }
                    model.snapshots.save(Snapshot.make(tree: tree, classification: model.classification))
                    model.activityRevision += 1
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.tree == nil)
                .help("Saved automatically after every scan")
            }
            if list.count < 2 {
                Text("A snapshot is saved after each scan. Scan again later to compare what grew and what shrank.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 10) {
                    picker("From", selection: $olderID, list: list)
                    Image(systemName: "arrow.right").foregroundStyle(Theme.textTertiary)
                    picker("To", selection: $newerID, list: list)
                    Spacer()
                }
                if let c = comparison { ComparisonView(comparison: c) }
            }
        }
        .card()
    }

    private func picker(_ title: String, selection: Binding<UUID?>, list: [SnapshotSummary]) -> some View {
        Picker(title, selection: selection) {
            ForEach(list) { s in
                Text("\(s.targetName) — \(DateFormat.shortString(s.date))").tag(Optional(s.id))
            }
        }
        .frame(width: 300)
    }

    private func pickDefaults() {
        let list = model.snapshots.summaries
        guard list.count >= 2 else { comparison = nil; return }
        let newest = list[0]
        newerID = newest.id
        olderID = (list.dropFirst().first { $0.targetPath == newest.targetPath } ?? list[1]).id
    }

    private func compare() {
        guard let a = olderID, let b = newerID, a != b,
              let older = model.snapshots.load(a), let newer = model.snapshots.load(b) else {
            comparison = nil
            return
        }
        comparison = SnapshotDiff.compare(older, newer)
    }

    // MARK: Events

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recent cleanups")
            if model.activity.events.isEmpty {
                Text("Nothing yet. Everything you clear with Duck Disk shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.activity.events.prefix(50)) { e in
                        HStack(spacing: 10) {
                            Image(systemName: e.source == "Compress" ? "arrow.down.right.and.arrow.up.left" : "trash")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(e.items) item\(e.items == 1 ? "" : "s") from \(e.source)").font(.system(size: 12))
                                Text(DateFormat.shortString(e.date)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                ForEach(e.categories.sorted { $0.value > $1.value }.prefix(4), id: \.key) { key, _ in
                                    if let c = CleanupCategory(rawValue: key) {
                                        Circle().fill(Theme.color(c)).frame(width: 6, height: 6)
                                    }
                                }
                            }
                            Text(ByteFormat.string(e.bytes))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .card(padding: 4)
            }
        }
    }
}

private struct ComparisonView: View {
    let comparison: SnapshotComparison

    var body: some View {
        let maxDelta = comparison.changes.map { abs($0.delta) }.max() ?? 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Used space").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(ByteFormat.signed(comparison.usedDelta))
                    .font(Theme.figure(15))
                    .foregroundStyle(comparison.usedDelta > 0 ? Theme.negative : Theme.positive)
                Text("between \(DateFormat.shortString(comparison.older.date)) and \(DateFormat.shortString(comparison.newer.date))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if comparison.changes.isEmpty {
                Text("No folder changed by more than 10 MB.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(comparison.changes) { change in
                HStack(spacing: 10) {
                    Image(systemName: change.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(change.delta > 0 ? Theme.negative : Theme.positive)
                        .frame(width: 14)
                    Text(PathFormat.abbreviated(change.path))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    SizeBar(fraction: Double(abs(change.delta)) / Double(max(1, maxDelta)),
                            color: change.delta > 0 ? Theme.negative.opacity(0.7) : Theme.positive.opacity(0.7))
                        .frame(width: 120)
                    Text(ByteFormat.signed(change.delta))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}
