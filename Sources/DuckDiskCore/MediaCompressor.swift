import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case high = "High", balanced = "Balanced", small = "Small"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .high: return "HEVC, original resolution"
        case .balanced: return "HEVC, up to 1080p"
        case .small: return "H.264, up to 720p"
        }
    }
    var preset: String {
        switch self {
        case .high: return AVAssetExportPresetHEVCHighestQuality
        case .balanced: return AVAssetExportPresetHEVC1920x1080
        case .small: return AVAssetExportPreset1280x720
        }
    }
}

public enum PhotoQuality: String, CaseIterable, Identifiable, Sendable {
    case high = "High", balanced = "Balanced", small = "Small"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .high: return "HEIC, quality 80%"
        case .balanced: return "HEIC, quality 60%"
        case .small: return "HEIC, quality 45%, max 4K"
        }
    }
    var quality: Double {
        switch self {
        case .high: return 0.8
        case .balanced: return 0.6
        case .small: return 0.45
        }
    }
    var maxPixels: Int? { self == .small ? 3840 : nil }
}

public struct CompressionResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Smaller file written; `replaced` when the original went to the Trash.
        case compressed(newPath: String, replaced: Bool)
        /// Result was not smaller; nothing kept.
        case notSmaller
        case failed(String)
    }
    public let original: String
    public let originalSize: Int64
    public let newSize: Int64
    public let outcome: Outcome
    public var saved: Int64 {
        if case .compressed = outcome { return max(0, originalSize - newSize) }
        return 0
    }
}

/// Shrinks videos (AVFoundation re-encode) and photos (HEIC re-encode, metadata kept).
/// A result is only kept when it is smaller; originals only ever go to the Trash.
public enum MediaCompressor {
    public static func isVideo(_ path: String) -> Bool { FileKinds.isVideo(path) }
    /// Only single-image formats a HEIC re-encode cannot damage (see FileKinds.compressiblePhotoExtensions).
    public static func isPhoto(_ path: String) -> Bool { FileKinds.isCompressiblePhoto(path) }

    public static func compress(_ path: String, video: VideoQuality, photo: PhotoQuality, replaceOriginal: Bool,
                                progress: @escaping @Sendable (Double) -> Void) async -> CompressionResult {
        let originalSize = fileSize(path)
        let isVideo = isVideo(path)
        let ext = isVideo ? (FileKinds.lowercasedExtension(path) == "mp4" ? "mp4" : "mov") : "heic"
        // A unique name, so parallel runs never collide and no existing file is ever replaced.
        let temp = "\(path).duckdisk-\(UUID().uuidString.prefix(8)).\(ext)"

        let error: String?
        if isVideo {
            error = await exportVideo(path, to: temp, quality: video, progress: progress)
        } else if isPhoto(path) {
            error = encodePhoto(path, to: temp, quality: photo)
            progress(1)
        } else {
            error = "Not a photo or video."
        }
        if let error {
            removeOwnTemp(temp)
            return CompressionResult(original: path, originalSize: originalSize, newSize: 0, outcome: .failed(error))
        }
        let newSize = fileSize(temp)
        guard newSize > 0, newSize < originalSize * 95 / 100 else {
            removeOwnTemp(temp)
            return CompressionResult(original: path, originalSize: originalSize, newSize: newSize, outcome: .notSmaller)
        }
        copyDates(from: path, to: temp)

        let base = (path as NSString).deletingPathExtension
        if replaceOriginal {
            let trash = await TrashService.trash([.init(path: path, size: originalSize)])
            if let failure = trash.failures.first {
                removeOwnTemp(temp)
                return CompressionResult(original: path, originalSize: originalSize, newSize: newSize,
                                         outcome: .failed("Original could not go to the Trash: \(failure.reason)"))
            }
            let dest = uniquePath(base + "." + ext)
            do {
                try FileManager.default.moveItem(atPath: temp, toPath: dest)
            } catch {
                return CompressionResult(original: path, originalSize: originalSize, newSize: newSize,
                                         outcome: .failed("Compressed copy left at \(temp)"))
            }
            return CompressionResult(original: path, originalSize: originalSize, newSize: newSize,
                                     outcome: .compressed(newPath: dest, replaced: true))
        }
        let dest = uniquePath(base + " (compressed)." + ext)
        do {
            try FileManager.default.moveItem(atPath: temp, toPath: dest)
        } catch {
            removeOwnTemp(temp)
            return CompressionResult(original: path, originalSize: originalSize, newSize: newSize,
                                     outcome: .failed(error.localizedDescription))
        }
        return CompressionResult(original: path, originalSize: originalSize, newSize: newSize,
                                 outcome: .compressed(newPath: dest, replaced: false))
    }

    static func exportVideo(_ path: String, to out: String, quality: VideoQuality,
                            progress: @escaping @Sendable (Double) -> Void) async -> String? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let compatible = await withCheckedContinuation { cont in
            AVAssetExportSession.determineCompatibility(ofExportPreset: quality.preset, with: asset,
                                                        outputFileType: nil) { cont.resume(returning: $0) }
        }
        let preset = compatible ? quality.preset : AVAssetExportPresetMediumQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return "This video format cannot be re-encoded."
        }
        let type: AVFileType = out.hasSuffix(".mp4") ? .mp4 : .mov
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15, *) {
            let watcher = Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            do {
                try await session.export(to: URL(fileURLWithPath: out), as: type)
                progress(1)
                return nil
            } catch {
                return error.localizedDescription
            }
        } else {
            session.outputURL = URL(fileURLWithPath: out)
            session.outputFileType = type
            let poller = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poller.cancel() }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed { progress(1); return nil }
            return session.error?.localizedDescription ?? "Export failed."
        }
    }

    /// Removes an intermediate file this run created (unique name, never a user file).
    static func removeOwnTemp(_ path: String) {
        guard path.contains(".duckdisk-") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    static func encodePhoto(_ path: String, to out: String, quality: PhotoQuality) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return "Could not read the photo."
        }
        guard CGImageSourceGetCount(source) == 1 else {
            return "Contains several images; left as it is."
        }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                         UTType.heic.identifier as CFString, 1, nil) else {
            return "HEIC encoding is not available."
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality.quality]
        if let max = quality.maxPixels { options[kCGImageDestinationImageMaxPixelSize] = max }
        CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? nil : "Could not write the compressed photo."
    }

    static func fileSize(_ path: String) -> Int64 {
        var st = stat()
        return stat(path, &st) == 0 ? Int64(st.st_size) : 0
    }

    static func copyDates(from src: String, to dst: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: src) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        try? FileManager.default.setAttributes(keep, ofItemAtPath: dst)
    }

    /// Adds " 2", " 3"… before the extension until the name is free.
    static func uniquePath(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return path }
        let ext = (path as NSString).pathExtension
        let base = (path as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: "\(base) \(n).\(ext)") { n += 1 }
        return "\(base) \(n).\(ext)"
    }
}
