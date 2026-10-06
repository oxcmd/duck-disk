import AppKit
import DuckDiskCore
import SwiftUI

/// Design tokens. Quiet near-black surfaces in dark mode, warm off-white in light mode;
/// kept space is grey, clearable space is colour.
enum Theme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = adaptive(0xF6F6F3, 0x19191B)
    static let panel = adaptive(0xFFFFFF, 0x222225)
    static let panelRaised = adaptive(0xEFEFEC, 0x2A2A2E)
    static let hairline = adaptive(0xE2E2DE, 0x303034)
    static let textPrimary = adaptive(0x141416, 0xF2F2F3)
    static let textSecondary = adaptive(0x6A6A70, 0x95959B)
    static let textTertiary = adaptive(0x9C9CA2, 0x606066)
    static let track = adaptive(0xE7E7E3, 0x2D2D31)
    static let buttonFill = adaptive(0x141416, 0xF4F4F5)
    static let buttonText = adaptive(0xFFFFFF, 0x141416)
    static let positive = adaptive(0x2E9D5B, 0x4CC27A)
    static let negative = adaptive(0xD2483F, 0xF0675D)

    static func color(_ c: CleanupCategory) -> Color {
        switch c {
        case .caches: return Color(nsColor: NSColor(hex: 0xE8A33D))
        case .logs: return Color(nsColor: NSColor(hex: 0xE5584F))
        case .leftovers: return Color(nsColor: NSColor(hex: 0xD65A9C))
        case .developer: return Color(nsColor: NSColor(hex: 0x7C5CFF))
        case .aiModels: return Color(nsColor: NSColor(hex: 0x4FB477))
        case .downloads: return Color(nsColor: NSColor(hex: 0x4C7DFF))
        case .duplicates: return Color(nsColor: NSColor(hex: 0x36B3C4))
        }
    }

    static func color(_ k: KeptCategory) -> Color {
        switch k {
        case .media: return adaptive(0xC9C9CE, 0x5C5C62)
        case .apps: return adaptive(0xBABAC0, 0x4E4E54)
        case .documents: return adaptive(0xD6D6DA, 0x434348)
        case .system: return adaptive(0xA9A9AF, 0x38383D)
        }
    }

    static let kept = adaptive(0xC4C4C9, 0x4A4A50)

    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let radius: CGFloat = 12
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Surfaces and buttons

struct Card: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(Card(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(Theme.buttonText)
            .background(Theme.buttonFill.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.panelRaised.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Small components

enum CheckState { case on, off, mixed }

/// Rounded-square checkbox tinted with the category colour.
struct CategoryCheckbox: View {
    let state: CheckState
    let color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state == .off ? Color.clear : color)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(state == .off ? Theme.textTertiary : color, lineWidth: 1.2)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = Theme.kept

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// Finder icon for a path, cached.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}

struct RoomHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.figure(22)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

extension RoomHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Footer bar with a summary on the left and an action on the right.
struct ActionFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Theme.background)
    }
}

/// Shown in rooms that need a scan first.
struct NeedsScanView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if model.phase == .scanning || model.phase == .analysing {
                ProgressView().controlSize(.small)
            } else {
                Button("Scan \(model.target.name)") { model.startScan() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Standard context menu for anything with a path.
    func itemContextMenu(path: String, size: Int64, model: AppModel, source: String) -> some View {
        contextMenu {
            Button("Reveal in Finder") { Actions.reveal(path) }
            Button("Quick Look") { model.quickLookURL = URL(fileURLWithPath: path) }
            Button("Copy Path") { Actions.copy(path) }
            Divider()
            Button("Move to Trash…") {
                model.askTrash(paths: [(path, size)], source: source)
            }
            .disabled(!SafetyGuard.check(path).isAllowed)
        }
    }
}

/// Menu items for one or more selected tree items.
struct ItemMenuItems: View {
    let refs: [ItemRef]
    let model: AppModel
    let source: String

    var body: some View {
        if let first = refs.first {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(refs.map { URL(fileURLWithPath: $0.path) })
            }
            Button("Quick Look") { model.quickLookURL = URL(fileURLWithPath: first.path) }
            Button("Copy Path") { Actions.copy(refs.map(\.path).joined(separator: "\n")) }
            Divider()
            Button(refs.count == 1 ? "Move to Trash…" : "Move \(refs.count) Items to Trash…") {
                model.askTrash(paths: refs.map { ($0.path, $0.size) }, source: source)
            }
            .disabled(!refs.contains { SafetyGuard.check($0.path).isAllowed })
        }
    }
}

enum Actions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }
}
