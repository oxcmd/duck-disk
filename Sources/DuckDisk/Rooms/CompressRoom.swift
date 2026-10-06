import AppKit
import DuckDiskCore
import SwiftUI
import UniformTypeIdentifiers

/// Shrink videos and photos instead of deleting them.
struct CompressRoom: View {
    @Environment(AppModel.self) private var model
    @State private var video = VideoQuality.balanced
    @State private var photo = PhotoQuality.high
    @State private var replace = true
    @State private var dropTargeted = false
    @State private var suggestions: [SearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            RoomScroll {
                VStack(alignment: .leading, spacing: 18) {
                    RoomHeader(title: "Compress",
                               subtitle: "Re-encode videos and photos to take less space. Results are kept only when they are smaller.")
                    settings
                    dropZone
                    if !jobs.isEmpty { queue }
                    if !suggestions.isEmpty { suggestionList }
                }
                .padding(24)
            }
            ActionFooter {
                let saved = jobs.compactMap(\.result).reduce(Int64(0)) { $0 + $1.saved }
                Text(saved > 0 ? "Saved \(ByteFormat.string(saved))" : "\(pending.count) file\(pending.count == 1 ? "" : "s") waiting")
                    .font(.system(size: 13))
                    .foregroundStyle(saved > 0 ? Theme.positive : Theme.textSecondary)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Clear List") { model.compressJobs.removeAll() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(jobs.isEmpty || running)
                Button("Compress \(pending.count) File\(pending.count == 1 ? "" : "s")") {
                    model.runCompression(video: video, photo: photo, replaceOriginals: replace)
                }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(pending.isEmpty || running)
            }
        }
        .task(id: model.revision) {
            guard let tree = model.tree else { suggestions = []; return }
            let found = await Task.detached(priority: .utility) { TreeSearch.largeMedia(tree) }.value
            if !Task.isCancelled { suggestions = found }
        }
    }

    private var jobs: [CompressJob] { model.compressJobs }
    private var running: Bool { model.compressRunning }
    private var pending: [CompressJob] { jobs.filter { $0.result == nil } }

    private var settings: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Videos")
                Picker("", selection: $video) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(video.detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Photos")
                Picker("", selection: $photo) {
                    ForEach(PhotoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(photo.detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Originals")
                Toggle("Replace originals", isOn: $replace).toggleStyle(.switch).controlSize(.small)
                Text(replace ? "Originals go to the Trash." : "Compressed copies are saved next to them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
        }
        .disabled(running)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("Drop videos and photos here").font(.system(size: 14, weight: .medium))
            Text("JPEG, PNG, HEIC, WebP and BMP photos; most video formats. RAW, PSD, TIFF and GIF are left alone.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Button("Choose Files…") { choose() }.buttonStyle(QuietButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(dropTargeted ? Theme.panelRaised : Theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .foregroundStyle(dropTargeted ? Theme.textSecondary : Theme.hairline))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add(url.path) } }
                }
            }
            return true
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "To compress")
            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    JobRow(job: job) { model.compressJobs.removeAll { $0.id == job.id } }
                        .disabled(running)
                }
            }
            .card(padding: 4)
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Large videos and photos from your scan")
            VStack(spacing: 0) {
                ForEach(suggestions.filter { hit in !jobs.contains { $0.path == hit.ref.path } }.prefix(15)) { hit in
                    HStack(spacing: 10) {
                        FileIcon(path: hit.ref.path, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.ref.name).font(.system(size: 12)).lineLimit(1)
                            Text(PathFormat.abbreviated(PathFormat.parent(of: hit.ref.path)))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteFormat.string(hit.size))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        Button("Add") { add(hit.ref.path) }.buttonStyle(.link).font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
            .card(padding: 4)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .image]
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { add($0.path) }
    }

    private func add(_ path: String) {
        guard MediaCompressor.isVideo(path) || MediaCompressor.isPhoto(path),
              !jobs.contains(where: { $0.path == path && $0.result == nil }) else { return }
        model.compressJobs.append(CompressJob(path: path, size: DirectorySize.of(path)))
    }
}

struct CompressJob: Identifiable {
    let id = UUID()
    let path: String
    let size: Int64
    var progress: Double?
    var result: CompressionResult?
}

private struct JobRow: View {
    let job: CompressJob
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: job.path, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(PathFormat.lastComponent(job.path)).font(.system(size: 12)).lineLimit(1)
                status
            }
            Spacer()
            Text(ByteFormat.string(job.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if job.result == nil && job.progress == nil {
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var status: some View {
        if let r = job.result {
            switch r.outcome {
            case .compressed(_, let replaced):
                Text("\(ByteFormat.string(r.newSize)) · saved \(ByteFormat.string(r.saved))\(replaced ? " · original in Trash" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.positive)
            case .notSmaller:
                Text("Already compact — left as it is").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            case .failed(let reason):
                Text(reason).font(.system(size: 11)).foregroundStyle(Theme.negative).lineLimit(2)
            }
        } else if let p = job.progress {
            ProgressView(value: p).frame(width: 180)
        } else {
            Text(MediaCompressor.isVideo(job.path) ? "Video" : "Photo")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
