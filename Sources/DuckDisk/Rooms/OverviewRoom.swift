import DuckDiskCore
import SwiftUI

/// One scan, and the whole drive on one screen.
struct OverviewRoom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: StartView()
            case .scanning, .analysing: ScanningView()
            case .ready: ResultView()
            }
        }
    }
}

// MARK: - Before a scan

private struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            LogoMark(size: 72)
            VStack(spacing: 8) {
                Text("Find out where the space went.")
                    .font(Theme.figure(30, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Duck Disk maps every byte of \(model.target.name), then shows what you keep in grey and what you could clear in colour. Nothing is deleted — cleared items go to the Trash.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                model.startScan()
            } label: {
                Label("Scan \(model.target.name)", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .controlSize(.large)
            if !model.hasFullDiskAccess {
                FullDiskAccessNote().frame(maxWidth: 460)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FullDiskAccessNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18))
                .foregroundStyle(Theme.color(.caches))
            VStack(alignment: .leading, spacing: 6) {
                Text("See everything with Full Disk Access")
                    .font(.system(size: 13, weight: .semibold))
                Text("Without it, macOS hides Mail, Messages, Safari and some app data from the scan, and may ask about Desktop, Documents and Downloads separately.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .card(padding: 14)
    }
}

// MARK: - While scanning

private struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                ScanningRing()
                VStack(spacing: 4) {
                    Text(ByteFormat.string(model.progress.bytes))
                        .font(Theme.figure(30))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(model.phase == .analysing ? "sorting it out…" : "\(model.progress.files.formatted()) files")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 280, height: 280)
            VStack(spacing: 6) {
                Text(model.phase == .analysing ? "Working out what can go" : "Scanning \(model.target.name)")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.phase == .analysing ? " " : PathFormat.abbreviated(model.progress.currentPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                Text(String(format: "%.0f s", model.progress.elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.phase == .scanning {
                Button("Stop") { model.cancelScan() }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

private struct ResultView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let report = model.lastReport {
                TrashBanner(report: report)
            }
            HStack(alignment: .center, spacing: 36) {
                ZStack {
                    DonutChart(segments: segments)
                    VStack(spacing: 4) {
                        Text(ByteFormat.string(model.selectedBytes))
                            .font(Theme.figure(34))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: model.selectedBytes)
                        Text("ready to clear")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(minWidth: 240, maxWidth: 330, minHeight: 240, maxHeight: 330)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

                CategoryList()
                    .frame(width: 320)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxHeight: .infinity)

            ScanSummary()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ActionFooter {
                Text("Found \(ByteFormat.string(model.classification.clearableTotal)) you could clear")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if model.isTrashing { ProgressView().controlSize(.small) }
                Button("Move \(ByteFormat.string(model.selectedBytes)) to Trash") {
                    model.askTrash(items: model.selectedItems, source: "Overview")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.selectedBytes == 0 || model.isTrashing)
            }
        }
    }

    /// Kept space in grey first, then every clearable category in colour (dimmed when unselected).
    private var segments: [DonutSegment] {
        var s = KeptCategory.allCases.map {
            DonutSegment(id: "kept." + $0.rawValue, value: Double(model.classification.kept[$0] ?? 0),
                         color: Theme.color($0))
        }
        for c in CleanupCategory.allCases {
            let total = model.classification.total(c)
            let selected = model.selectedBytes(in: c)
            if selected > 0 {
                s.append(DonutSegment(id: c.rawValue, value: Double(selected), color: Theme.color(c)))
            }
            if total - selected > 0 {
                s.append(DonutSegment(id: c.rawValue + ".rest", value: Double(total - selected),
                                      color: Theme.color(c).opacity(0.5)))
            }
        }
        return s
    }
}

private struct CategoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            group(.safe)
            group(.review).padding(.top, 10)
            SectionLabel(text: "Kept").padding(.top, 10).padding(.bottom, 2)
            ForEach(KeptCategory.allCases) { k in
                let bytes = model.classification.kept[k] ?? 0
                if bytes > 0 {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(k)).frame(width: 7, height: 7).frame(width: 15)
                        Text(k.title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(ByteFormat.string(bytes))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func group(_ g: CleanupCategory.Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        SectionLabel(text: g.rawValue).padding(.bottom, 2)
        ForEach(CleanupCategory.allCases.filter { $0.group == g }) { c in
            HStack(spacing: 10) {
                CategoryCheckbox(state: model.state(c), color: Theme.color(c)) { model.toggle(c) }
                    .disabled(model.items(c).isEmpty)
                Button {
                    model.cleanupFocus = c
                    model.room = c == .duplicates ? .duplicates : .cleanup
                } label: {
                    HStack {
                        Text(c.title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if c == .duplicates && model.duplicatePhase == .running {
                            ProgressView().controlSize(.mini)
                            Text("Checking").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        } else {
                            Text(ByteFormat.string(model.classification.total(c)))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.explanation)
            }
            .padding(.vertical, 5)
        }
        }
    }
}

private struct ScanSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree {
            HStack(spacing: 6) {
                Text("\(tree.stats.files.formatted()) files in \(String(format: "%.1f", tree.stats.duration)) s")
                if tree.stats.unreadableDirs > 0 {
                    Text("·")
                    Text("\(tree.stats.unreadableDirs.formatted()) folders macOS kept private")
                        .help("Give Duck Disk Full Disk Access in System Settings to include them.")
                }
                if let v = tree.volume, tree.isVolumeScan {
                    Text("·")
                    Text("\(ByteFormat.string(v.available)) free of \(ByteFormat.string(v.total))")
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
        }
    }
}

struct TrashBanner: View {
    @Environment(AppModel.self) private var model
    let report: TrashReport
    @State private var showFailures = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(report.failures.isEmpty ? Theme.positive : Theme.color(.caches))
            Text("Done. \(ByteFormat.string(report.freed)) is in the Trash.")
                .font(.system(size: 13, weight: .medium))
            if !report.failures.isEmpty {
                Button("\(report.failures.count) could not be moved") { showFailures = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .popover(isPresented: $showFailures) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(report.failures) { f in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(PathFormat.abbreviated(f.path)).font(.system(size: 12)).lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(f.reason).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            .padding(12)
                        }
                        .frame(width: 380, height: 220)
                    }
            }
            Spacer()
            Button("Open Trash") { Actions.openTrash() }.buttonStyle(QuietButtonStyle())
            Button {
                model.lastReport = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.panelRaised)
    }
}
