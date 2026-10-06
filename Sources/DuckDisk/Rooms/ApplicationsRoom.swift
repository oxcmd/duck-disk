import AppKit
import DuckDiskCore
import SwiftUI

/// Every app with everything it left behind, and what it runs in the background.
struct ApplicationsRoom: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", unused = "Unused"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty && model.appsLoading {
                VStack(spacing: 12) {
                    ProgressView(value: Double(model.appsProgress.done), total: Double(max(1, model.appsProgress.total)))
                        .frame(width: 280)
                    Text("Measuring apps and their data… \(model.appsProgress.done) of \(model.appsProgress.total)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 320)
                    Divider().overlay(Theme.hairline)
                    if let app = model.apps.first(where: { $0.id == selectedID }) {
                        AppDetail(app: app)
                    } else {
                        Text("Select an app")
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear { model.loadApps() }
    }

    private var filtered: [AppInfo] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        return model.apps.filter { app in
            (query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                || app.bundleID.localizedCaseInsensitiveContains(query))
                && (filter != .running || app.isRunning)
                && (filter != .unused || (app.lastUsed.map { $0 < cutoff } ?? true))
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Applications").font(Theme.figure(20))
                    Spacer()
                    Button {
                        model.loadApps(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Measure again")
                    .disabled(model.appsLoading)
                }
                TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("\(filtered.count) apps · \(ByteFormat.string(filtered.reduce(0) { $0 + $1.footprint }))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            List(filtered, selection: $selectedID) { app in
                HStack(spacing: 10) {
                    FileIcon(path: app.path, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13)).lineLimit(1)
                        Text(app.leftoverSize > 0 ? "App \(ByteFormat.string(app.bundleSize)) · data \(ByteFormat.string(app.leftoverSize))"
                                                  : (app.version.map { "Version \($0)" } ?? app.bundleID))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if app.isRunning {
                        Circle().fill(Theme.positive).frame(width: 6, height: 6).help("Running")
                    }
                    Text(ByteFormat.string(app.footprint))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 2)
                .tag(app.id)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let app: AppInfo
    @State private var chosenLeftovers = Set<String>()
    /// The action waiting for the running app to quit.
    @State private var pendingAfterQuit: AfterQuit?

    enum AfterQuit: Identifiable {
        case uninstall, clearCache
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            RoomScroll {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        FileIcon(path: app.path, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(Theme.figure(22))
                            Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                            Text(app.lastUsed.map { "Last opened \(DateFormat.relativeString($0))" } ?? "Never opened, as far as Spotlight knows")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteFormat.string(app.footprint)).font(Theme.figure(24))
                            Text("in total").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        stat("App", app.bundleSize, Theme.kept)
                        stat("Data and leftovers", app.leftoverSize, Theme.color(.leftovers))
                    }

                    if !app.leftovers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Data it keeps around")
                            VStack(spacing: 0) {
                                ForEach(app.leftovers) { file in
                                    HStack(spacing: 10) {
                                        CategoryCheckbox(state: chosenLeftovers.contains(file.path) ? .on : .off,
                                                         color: Theme.color(.leftovers)) {
                                            if chosenLeftovers.contains(file.path) { chosenLeftovers.remove(file.path) }
                                            else { chosenLeftovers.insert(file.path) }
                                        }
                                        FileIcon(path: file.path, size: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(PathFormat.lastComponent(file.path)).font(.system(size: 12)).lineLimit(1)
                                            Text(file.kind).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                        Text(ByteFormat.string(file.size))
                                            .font(.system(size: 12).monospacedDigit())
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.inspected = InspectedItem(path: file.path, ref: nil) }
                                    .itemContextMenu(path: file.path, size: file.size, model: model, source: "Applications")
                                }
                            }
                            .card(padding: 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "In the background")
                        if app.background.isEmpty {
                            Text("Nothing running or scheduled to run.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(app.background) { item in
                                    HStack(spacing: 10) {
                                        Image(systemName: item.kind == .process ? "gearshape.2" : "clock.arrow.circlepath")
                                            .foregroundStyle(Theme.textSecondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name).font(.system(size: 12)).lineLimit(1)
                                            Text(item.kind.rawValue + (item.pid.map { " · PID \($0)" } ?? ""))
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                            }
                            .card(padding: 4)
                        }
                    }
                }
                .padding(24)
            }
            ActionFooter {
                Button("Reveal in Finder") { Actions.reveal(app.path) }.buttonStyle(QuietButtonStyle())
                if app.isRunning {
                    Button("Quit") { quit() }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                if !chosenLeftovers.isEmpty {
                    Button("Clear \(chosenLeftovers.count) Data Item\(chosenLeftovers.count == 1 ? "" : "s")") {
                        let files = app.leftovers.filter { chosenLeftovers.contains($0.path) }
                        model.askTrash(paths: files.map { ($0.path, $0.size) }, source: "Applications") { _ in
                            model.loadApps(force: true)
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Clear Cache (\(ByteFormat.string(app.cacheSize)))") {
                    if app.isRunning { pendingAfterQuit = .clearCache } else { askClearCache() }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(app.cacheSize == 0)
                .help("Moves the app's caches and web data to the Trash. Settings and documents stay.")
                Button("Uninstall…") { uninstall() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(app.isApple || !SafetyGuard.check(app.path).isAllowed)
                    .help(app.isApple ? "Part of macOS" : "Moves the app and its data to the Trash")
            }
        }
        .onAppear { chosenLeftovers = [] }
        .onChange(of: app.id) { _, _ in chosenLeftovers = [] }
        .alert("Quit \(app.name) first?", isPresented: Binding(get: { pendingAfterQuit != nil },
                                                               set: { if !$0 { pendingAfterQuit = nil } }),
               presenting: pendingAfterQuit) { action in
            Button(action == .uninstall ? "Quit and Uninstall" : "Quit and Clear Cache") {
                quit()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if action == .uninstall { askUninstall() } else { askClearCache() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .uninstall
                 ? "\(app.name) is running. It needs to quit before it can go to the Trash."
                 : "\(app.name) is running. Quit it first so it does not write to its cache while it is cleared.")
        }
    }

    private func stat(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Text(ByteFormat.string(bytes)).font(Theme.figure(17))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private func quit() {
        let pids = Set(app.background.compactMap(\.pid))
        for running in NSWorkspace.shared.runningApplications
        where running.bundleURL?.path == app.path || pids.contains(running.processIdentifier) {
            running.terminate()
        }
    }

    private func uninstall() {
        if app.isRunning { pendingAfterQuit = .uninstall } else { askUninstall() }
    }

    private func askClearCache() {
        model.askTrash(paths: app.caches.map { ($0.path, $0.size) }, source: "Applications") { _ in
            model.loadApps(force: true)
        }
    }

    private func askUninstall() {
        var paths = [(app.path, app.bundleSize)]
        paths += app.leftovers.map { ($0.path, $0.size) }
        model.askTrash(paths: paths, source: "Applications") { result in
            if result.trashed[app.path] != nil {
                model.apps.removeAll { $0.id == app.id }
            }
        }
    }
}
