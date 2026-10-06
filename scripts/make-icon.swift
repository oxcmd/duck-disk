// Renders the Duck Disk app icon into an .iconset folder. The drawing lives in
// Sources/DuckDisk/DuckArtwork.swift so the app's own logo matches the icon.
// Usage (scripts/package-app.sh does this):
//   swiftc -parse-as-library scripts/make-icon.swift Sources/DuckDisk/DuckArtwork.swift -o make-icon
//   ./make-icon <output.iconset>
import AppKit

@main
enum MakeIcon {
    static func main() throws {
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try DuckArtwork.iconPNG(pixels: base).write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base).png"))
            try DuckArtwork.iconPNG(pixels: base * 2)
                .write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base)@2x.png"))
        }
        print("Wrote \(output)")
    }
}
