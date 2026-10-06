import Foundation

/// Builds a fake home folder with known contents for the checks (and for UI previews via -homeOverride).
enum Fixture {
    static let old = Date().addingTimeInterval(-400 * 86_400)

    @discardableResult
    static func make(at root: String) throws -> String {
        let fm = FileManager.default
        // Only ever recreate a folder that is clearly a fixture.
        precondition(root.hasSuffix("duckdisk-fixture"), "Fixture folder must end with duckdisk-fixture")
        if fm.fileExists(atPath: root) { try fm.removeItem(atPath: root) }

        func file(_ rel: String, bytes: Int, fill: UInt8? = nil, date: Date? = nil) throws {
            let path = root + "/" + rel
            try fm.createDirectory(atPath: PathFormat_parent(path), withIntermediateDirectories: true)
            var data = Data(count: bytes)
            if let fill {
                data = Data(repeating: fill, count: bytes)
            } else {
                data.withUnsafeMutableBytes { buf in
                    for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
                }
            }
            try data.write(to: URL(fileURLWithPath: path))
            if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: path) }
        }
        func touchDir(_ rel: String, _ date: Date) throws {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: root + "/" + rel)
        }

        try file("Library/Caches/com.example.browser/Cache.db", bytes: 3_000_000)
        try file("Library/Caches/com.example.browser/blobs/1", bytes: 2_000_000)
        try file("Library/Caches/com.apple.bird/state", bytes: 500_000)
        try file("Library/Logs/SomeApp/app.log", bytes: 800_000)
        try file("Library/Logs/DiagnosticReports/crash1.ips", bytes: 120_000)
        try file("Library/Application Support/com.gone.app/data.bin", bytes: 1_500_000)
        try file("Library/Application Support/com.apple.something/x", bytes: 10_000)
        try file("Library/Application Support/Plain Name/y", bytes: 10_000)
        try file("Library/Preferences/com.gone.app.plist", bytes: 4_000)
        try file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/out.o", bytes: 4_000_000)
        try file("Downloads/installer.dmg", bytes: 6_000_000)
        try file("Downloads/old-archive.zip", bytes: 2_000_000, date: old)
        try file("Downloads/new-notes.txt", bytes: 20_000)
        try file("Projects/web/package.json", bytes: 200, date: old)
        try file("Projects/web/node_modules/lib/index.js", bytes: 2_500_000, date: old)
        try touchDir("Projects/web", old)
        // Local AI models.
        try file(".ollama/models/manifests/registry.ollama.ai/library/llama3/latest", bytes: 500)
        try file(".ollama/models/blobs/sha256-0f3a", bytes: 2_000_000)
        try file(".lmstudio/models/lmstudio-community/Qwen-7B-GGUF/qwen-7b.Q4.gguf", bytes: 2_000_000)
        try file(".cache/huggingface/hub/models--openai--whisper-small/blobs/9a1c", bytes: 1_500_000)
        try file(".cache/pip/http/wheel", bytes: 1_000_000)
        try file("Documents/llama-7b.Q4.gguf", bytes: 2_000_000)
        try file("Applications/Painter.app/Contents/Resources/style.safetensors", bytes: 2_000_000)
        try file(".Trash/old-model.gguf", bytes: 2_000_000)
        try file("Documents/Quarterly REPORT.pdf", bytes: 900_000)
        try file("Documents/.hidden-config", bytes: 1_000)
        try file("Pictures/beach.jpg", bytes: 3_000_000, fill: 7)
        try file("Pictures/beach copy.jpg", bytes: 3_000_000, fill: 7)
        try file("Pictures/other.jpg", bytes: 3_000_000, fill: 9)
        // Hard link: same inode, must count once and never be a duplicate.
        try fm.linkItem(atPath: root + "/Pictures/beach.jpg", toPath: root + "/Pictures/beach-link.jpg")
        // APFS clone: shares blocks with the original, so it frees nothing.
        let clone = Process()
        clone.executableURL = URL(fileURLWithPath: "/bin/cp")
        clone.arguments = ["-c", root + "/Pictures/beach.jpg", root + "/Pictures/beach clone.jpg"]
        try clone.run()
        clone.waitUntilExit()
        // Downloads entries are judged by their own dates; installer stays new on purpose.
        try touchDir("Downloads", Date())
        return root
    }

    private static func PathFormat_parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
}
