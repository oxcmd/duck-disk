import AppKit
import SwiftUI

@main
struct DuckDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(Prefs.appearance) private var appearance = "system"

    var body: some Scene {
        WindowGroup("Duck Disk") {
            ContentView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan \(model.target.name)") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.phase == .scanning || model.phase == .analysing)
                Button("Choose Folder to Scan…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.phase != .scanning)
            }
            CommandMenu("Go") {
                ForEach(Array(Room.allCases.enumerated()), id: \.element) { index, room in
                    Button(room.title) { model.room = room }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
