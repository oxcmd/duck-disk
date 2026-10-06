import DuckDiskCore
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            RoomView(room: model.room)
                // A new scan discards the tree; rebuild rooms so none keeps references into the old one.
                .id(model.scanGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
                .toolbar { toolbar }
        }
        .sheet(item: $model.pendingTrash) { request in
            TrashConfirmSheet(request: request)
        }
        .quickLookPreview($model.quickLookURL)
        .environment(\.snapshotMode, DevSnapshots.isActive)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshVolumes()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            TargetMenu()
            Button {
                model.startScan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Scan again (⌘R)")
            .disabled(model.phase == .scanning || model.phase == .analysing)
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }
    }
}

struct RoomView: View {
    let room: Room
    var body: some View {
        switch room {
        case .overview: OverviewRoom()
        case .find: FindRoom()
        case .space: SpaceRoom()
        case .cleanup: CleanupRoom()
        case .duplicates: DuplicatesRoom()
        case .applications: ApplicationsRoom()
        case .monitor: MonitorRoom()
        case .compress: CompressRoom()
        case .activity: ActivityRoom()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LogoMark(size: 20)
                Text("Duck Disk").font(Theme.figure(15)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)

            List(selection: $model.room) {
                // Keyed by the room itself and tagged last: a tag placed before `.badge` is lost and the
                // list falls back to the String id, which never matches the Room selection.
                ForEach(Room.allCases, id: \.self) { room in
                    Label(room.title, systemImage: room.symbol)
                        .badge(badge(for: room))
                        .tag(room)
                }
            }
            .listStyle(.sidebar)

            VolumeFooter()
                .padding(14)
        }
    }

    private func badge(for room: Room) -> Text? {
        switch room {
        case .cleanup where model.phase == .ready:
            let bytes = model.classification.clearableTotal
            return bytes > 0 ? Text(ByteFormat.string(bytes)) : nil
        case .duplicates where model.duplicatePhase == .done && !model.duplicateGroups.isEmpty:
            return Text("\(model.duplicateGroups.count)")
        default:
            return nil
        }
    }
}

/// Free-space bar for the selected drive at the bottom of the sidebar.
private struct VolumeFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let v = model.targetVolume {
            VStack(alignment: .leading, spacing: 6) {
                Text(v.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                SizeBar(fraction: Double(v.used) / Double(max(1, v.total)), color: Theme.textSecondary)
                Text("\(ByteFormat.string(v.available)) free of \(ByteFormat.string(v.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// The ring-and-duck mark used in the sidebar and empty states; the same drawing as the app icon.
struct LogoMark: View {
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: DuckArtwork.mark)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Duck Disk")
    }
}

private struct TargetMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Drives") {
                ForEach(model.volumes) { v in
                    Button {
                        model.choose(ScanTarget(path: v.path, name: v.name, isVolume: true))
                    } label: {
                        Text("\(v.name) — \(ByteFormat.string(v.available)) free")
                    }
                }
            }
            Section("Folders") {
                Button("Home Folder") {
                    model.choose(ScanTarget(path: NSHomeDirectory(), name: "Home", isVolume: false))
                }
                Button("Choose Folder…") { model.chooseFolder() }
            }
        } label: {
            Label(model.target.name, systemImage: model.target.isVolume ? "internaldrive" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .help("Choose what to scan")
    }
}

/// Confirmation before anything moves to the Trash.
private struct TrashConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TrashRequest
    /// Items SafetyGuard will refuse, worked out once (it touches the file system).
    private let blocked: [(String, String)]
    /// Total without counting an item twice when its folder is also listed.
    private let total: Int64

    init(request: TrashRequest) {
        self.request = request
        blocked = request.items.compactMap { item in SafetyGuard.check(item.path).reason.map { (item.path, $0) } }
        let blockedPaths = Set(blocked.map(\.0))
        total = TrashService.removingNested(request.items)
            .filter { !blockedPaths.contains($0.path) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Move \(ByteFormat.string(total)) to the Trash?")
                        .font(Theme.figure(17))
                    Text("\(request.items.count) item\(request.items.count == 1 ? "" : "s"). Nothing is deleted — you can put things back from the Trash in Finder.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(request.items.prefix(200), id: \.path) { item in
                        HStack(spacing: 8) {
                            FileIcon(path: item.path, size: 16)
                            Text(PathFormat.abbreviated(item.path))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(item.size))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if request.items.count > 200 {
                        Text("and \(request.items.count - 200) more")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(10)
            }
            .frame(height: 200)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
            if !blocked.isEmpty {
                Label("\(blocked.count) protected item\(blocked.count == 1 ? "" : "s") will be skipped: \(blocked[0].1)",
                      systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingTrash = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(QuietButtonStyle())
                Button("Move to Trash") {
                    model.pendingTrash = request
                    model.confirmTrash()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(blocked.count == request.items.count)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
