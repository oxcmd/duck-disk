import AppKit
import DuckDiskCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CleanupSettings().tabItem { Label("Cleanup", systemImage: "trash") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.autoSnapshot) private var autoSnapshot = true
    @State private var excluded: [String] = Prefs.excluded

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("Match System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle("Save a snapshot after every scan", isOn: $autoSnapshot)
            Section("Never scan these folders") {
                List {
                    ForEach(excluded, id: \.self) { path in
                        HStack {
                            FileIcon(path: path, size: 16)
                            Text(PathFormat.abbreviated(path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                excluded.removeAll { $0 == path }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 90)
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    guard panel.runModal() == .OK else { return }
                    for url in panel.urls where !excluded.contains(url.path) { excluded.append(url.path) }
                    save()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        UserDefaults.standard.set(excluded, forKey: Prefs.excludedPaths)
    }
}

private struct CleanupSettings: View {
    @AppStorage(Prefs.oldDownloadDays) private var oldDownloadDays = 90
    @AppStorage(Prefs.staleProjectDays) private var staleProjectDays = 30
    @AppStorage(Prefs.duplicateMinSize) private var duplicateMinSize = 1_000_000

    var body: some View {
        Form {
            Picker("Downloads count as old after", selection: $oldDownloadDays) {
                ForEach([30, 60, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
            }
            Picker("Build folders count as stale after", selection: $staleProjectDays) {
                ForEach([14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
            }
            Picker("Look for duplicates larger than", selection: $duplicateMinSize) {
                Text("100 KB").tag(100_000)
                Text("1 MB").tag(1_000_000)
                Text("10 MB").tag(10_000_000)
                Text("100 MB").tag(100_000_000)
            }
            Section {
                Text("Changes apply to the next scan. Cleared items always go to the Trash, and macOS system folders are never touched.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        Form {
            Section("Full Disk Access") {
                HStack {
                    Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(granted ? .green : .orange)
                    Text(granted ? "Granted. Duck Disk can see the whole drive."
                                 : "Not granted. Some folders are hidden from scans.")
                }
                Button("Open Privacy & Security Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                Text("After a rebuild of an unsigned copy you may need to switch access off and on again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("What leaves your Mac") {
                Text("Nothing. Duck Disk has no account, no sync, no analytics and makes no network requests. Scan results, snapshots and history stay in ~/Library/Application Support/Duck Disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = FullDiskAccess.isGranted
        }
    }
}
