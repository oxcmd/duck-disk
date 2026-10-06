// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DuckDisk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DuckDisk", targets: ["DuckDisk"]),
        .executable(name: "DuckDiskChecks", targets: ["DuckDiskChecks"]),
    ],
    targets: [
        // Scanning, classification, cleanup and system logic. No SwiftUI.
        .target(name: "DuckDiskCore"),
        // The SwiftUI app.
        .executableTarget(name: "DuckDisk", dependencies: ["DuckDiskCore"]),
        // Self-contained check runner (XCTest is unavailable with Command Line Tools only).
        .executableTarget(name: "DuckDiskChecks", dependencies: ["DuckDiskCore"]),
    ],
    swiftLanguageModes: [.v5]
)
