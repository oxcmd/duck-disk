import AppKit
import SwiftUI

/// Development aid (debug builds only): `DuckDisk -scanPath <folder> -snapshotDir <dir>` renders every room
/// to PNG once the scan is ready, then quits. No screen-recording permission is needed.
enum DevSnapshots {
    #if DEBUG
    @MainActor
    static func runIfRequested(_ model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            while model.phase != .ready || model.duplicatePhase == .running {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            UserDefaults.standard.set("Folders", forKey: "spaceMode")
            for room in Room.allCases where room != .applications {
                model.room = room
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                capture(to: "\(dir)/\(room.rawValue).png")
                render(room, model: model, to: "\(dir)/\(room.rawValue)-render.png")
            }
            UserDefaults.standard.set("Treemap", forKey: "spaceMode")
            model.room = .space
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(to: "\(dir)/space-treemap.png")
            NSApp.terminate(nil)
        }
    }

    @MainActor
    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the room alone with SwiftUI's renderer (AppKit-backed controls show as placeholders).
    @MainActor
    static func render(_ room: Room, model: AppModel, to path: String) {
        let view = RoomView(room: room)
            .environment(model)
            .environment(\.snapshotMode, true)
            .frame(width: 900, height: 700)
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static var isActive: Bool { UserDefaults.standard.string(forKey: "snapshotDir") != nil }
    #else
    static let isActive = false
    #endif
}

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while DevSnapshots renders rooms; scroll views are laid out flat so they can be captured.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// Vertical scroll container for room content.
struct RoomScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder var content: () -> Content

    var body: some View {
        if snapshotMode {
            VStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        } else {
            ScrollView { content() }
        }
    }
}
