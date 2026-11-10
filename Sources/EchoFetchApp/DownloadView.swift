import AppKit
import EchoFetchCore
import SwiftUI

struct DownloadView: View {
    @Environment(EchoFetchRuntime.self) private var runtime
    @AppStorage(Preferences.saveFolderKey) private var saveFolderPath = ""
    @AppStorage(Preferences.audioFormatKey) private var audioFormat = AudioFormat.m4a.rawValue
    @AppStorage(Preferences.fillInCopiedLinksKey) private var fillInCopiedLinks = true
    @AppStorage(Preferences.videoQualityKey) private var videoQuality = VideoQuality.original.rawValue
    @State private var choosingPart: MediaItem?

    private var downloads: DownloadController { runtime.downloads }
    private var tools: ToolsController { runtime.tools }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EchoFetch")
                        .font(.largeTitle.weight(.semibold))
                    Text("Save videos and audio from a link.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                toolsStatus
                linkSection
                previewSection
                jobSection

                Label("Downloads are saved to \(Preferences.folderDisplayName(saveFolder)). You can change this in Settings.", systemImage: "folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: downloads.linkText) { _, _ in
            downloads.linkTextChanged()
        }
        .sheet(item: $choosingPart) { item in
            PartSheet(item: item, initialClip: downloads.clip) { chosen in
                downloads.setClip(chosen, for: item)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    private var saveFolder: URL {
        saveFolderPath.isEmpty ? Preferences.defaultSaveFolder : URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    private var chosenAudioFormat: AudioFormat {
        AudioFormat(rawValue: audioFormat) ?? .m4a
    }

    private var chosenVideoQuality: VideoQuality {
        VideoQuality.saved(videoQuality)
    }

    private var linkBinding: Binding<String> {
        Binding(
            get: { runtime.downloads.linkText },
            set: { runtime.downloads.linkText = $0 }
        )
    }

    private var wholePlaylistBinding: Binding<Bool> {
        Binding(
            get: { runtime.downloads.wholePlaylist },
            set: { runtime.downloads.setWholePlaylist($0) }
        )
    }

    // MARK: Tools

    @ViewBuilder
    private var toolsStatus: some View {
        switch tools.setupState {
        case .preparing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Setting up the download tools. The first time, EchoFetch downloads them, which takes a minute.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            GroupBox {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Try Again") {
                        Task { await tools.prepare() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        case .ready:
            EmptyView()
        }
    }

    // MARK: Link

    private var linkSection: some View {
        GroupBox("Link") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("Link", text: linkBinding, prompt: Text("Paste a YouTube or other video link"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { downloads.lookUp() }
                    Button("Paste") { downloads.pasteLink() }
                    if !downloads.linkText.isEmpty {
                        Button {
                            downloads.clearLink()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear the link")
                    }
                }
                Text(linkHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if downloads.playlistOffer != nil {
                    Toggle("Download the whole playlist instead of just this video", isOn: wholePlaylistBinding)
                        .disabled(downloads.isDownloading)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewSection: some View {
        switch downloads.preview {
        case .empty:
            EmptyView()
        case .loading:
            GroupBox("Preview") {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking up the link…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            }
        case .failed(let message):
            GroupBox("Preview") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        case .loaded(let info):
            switch info {
            case .single(let item):
                singlePreview(item)
            case .playlist(let playlist):
                playlistPreview(playlist)
            }
        }
    }

    private func singlePreview(_ item: MediaItem) -> some View {
        let subtitle = details([item.uploader, item.duration.map(DisplayFormat.duration), siteLabel(item.siteName)])
        return GroupBox("Preview") {
            HStack(alignment: .top, spacing: 18) {
                ThumbnailView(url: item.thumbnailURL, width: 256)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if item.isLiveOrUpcoming {
                        Label("Live streams and premieres that haven't finished can't be downloaded yet.", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        partRow(item)
                        qualityPicker
                        downloadButtons(video: downloads.clip == nil ? "Download Video" : "Download Part", audio: "Download Audio")
                        Text(formatNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
            }
            .padding(.vertical, 6)
        }
    }

    private func playlistPreview(_ playlist: MediaPlaylist) -> some View {
        let unavailable: String? = playlist.unavailableCount > 0 ? "\(playlist.unavailableCount) unavailable" : nil
        let subtitle = details([count(playlist.entries.count, "video"), playlist.uploader, unavailable])
        let videoTitle = "Download \(count(playlist.entries.count, "Video"))"
        let audioTitle = "Download Audio (\(playlist.entries.count))"
        return GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    ThumbnailView(url: playlist.displayThumbnailURL, width: 256)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Playlist", systemImage: "list.bullet.rectangle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(playlist.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        qualityPicker
                        downloadButtons(video: videoTitle, audio: audioTitle)
                        Text("Saved one at a time into a folder named after the playlist. Videos that can't be downloaded are skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
                }
                DisclosureGroup("Videos in this playlist") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(playlist.entries.prefix(200).enumerated()), id: \.offset) { index, entry in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(entry.title)
                                    .lineLimit(1)
                                    .foregroundStyle(entry.isAvailable ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                                Spacer()
                                if let duration = entry.duration {
                                    Text(DisplayFormat.duration(duration))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                            .padding(.vertical, 4)
                        }
                        if playlist.entries.count > 200 {
                            Text("and \(playlist.entries.count - 200) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// "Whole video · Choose Part…", or the chosen part with Change… and Whole Video.
    private func partRow(_ item: MediaItem) -> some View {
        let clip = downloads.clip
        let label: String = clip.map { "Part: \($0.displayText) (\(ClipTime.text($0.length)))" } ?? "Whole video"
        return HStack(spacing: 10) {
            Label(label, systemImage: clip == nil ? "film" : "scissors")
                .foregroundStyle(clip == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .monospacedDigit()
            Button(clip == nil ? "Choose Part…" : "Change…") {
                choosingPart = item
            }
            if clip != nil {
                Button("Whole Video") { downloads.setClip(nil, for: item) }
            }
        }
        .disabled(downloads.isDownloading)
    }

    private var qualityPicker: some View {
        Picker("Video quality", selection: $videoQuality) {
            ForEach(VideoQuality.allCases, id: \.self) { quality in
                Text(quality.title).tag(quality.rawValue)
            }
        }
        .fixedSize()
        .disabled(downloads.isDownloading)
    }

    private func downloadButtons(video: String, audio: String) -> some View {
        HStack(spacing: 10) {
            Button {
                downloads.download(.video)
            } label: {
                Label(video, systemImage: "film")
            }
            .buttonStyle(.borderedProminent)
            Button {
                downloads.download(.audio)
            } label: {
                Label(audio, systemImage: "music.note")
            }
        }
        .controlSize(.large)
        .disabled(!downloads.canDownload)
    }

    private var linkHint: String {
        fillInCopiedLinks
            ? "Copy a link anywhere, then switch to EchoFetch: it's filled in and looked up for you."
            : "Paste a link, then press Return."
    }

    private var formatNote: String {
        let video: String
        switch chosenVideoQuality {
        case .original:
            video = VideoSupport.playsAV1
                ? "Video: MP4 in the best quality QuickTime plays, up to 4K and 8K."
                : "Video: MP4 in the best quality QuickTime plays on this Mac (up to 1080p)."
        case .appleHEVC:
            video = "Video: the best quality, compressed to HEVC by your Mac. Fast, and smaller than the original."
        case .x265:
            video = "Video: the best quality, compressed with x265 for the smallest file. Slower: a long 4K video can take a while."
        }
        let audio = chosenAudioFormat == .m4a ? "Audio: M4A, original quality." : "Audio: MP3."
        return "\(video) \(audio)"
    }

    // MARK: Download

    @ViewBuilder
    private var jobSection: some View {
        switch downloads.job {
        case .idle:
            EmptyView()
        case .running(let job):
            GroupBox("Download") { runningView(job) }
        case .finished(let finished):
            GroupBox("Download") { finishedView(finished) }
        case .failed(let message):
            GroupBox("Download") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if downloads.canDownload, downloads.lastKind != nil {
                        Button("Try Again") { downloads.retry() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        case .cancelled:
            GroupBox("Download") {
                Label("Download cancelled. The partly downloaded file was removed.", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private func runningView(_ job: DownloadController.Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(job))
                        .font(.headline)
                    Text(job.progress.itemTitle ?? job.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { downloads.cancelDownload() }
            }
            if let compression = job.compression, let fraction = compression.fraction {
                ProgressView(value: fraction)
            } else if job.compression == nil, job.progress.phase == .downloading, let fraction = job.progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(detailLine(job))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if job.isPlaylist, job.compression == nil, let overall = job.progress.playlistFraction {
                Divider()
                HStack {
                    Text(playlistPosition(job))
                        .font(.callout)
                    Spacer()
                    Text("\(job.progress.savedFiles.count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: overall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func playlistPosition(_ job: DownloadController.Job) -> String {
        let total = job.progress.itemCount ?? job.totalItems
        let current = min(job.progress.itemIndex ?? 1, total)
        return "Video \(current) of \(total)"
    }

    private func statusTitle(_ job: DownloadController.Job) -> String {
        if let compression = job.compression {
            return compression.quality == .x265 ? "Compressing with x265…" : "Compressing with Apple HEVC…"
        }
        switch job.progress.phase {
        case .starting:
            return "Starting…"
        case .downloading:
            if job.clip != nil {
                return job.kind == .video ? "Downloading the part…" : "Downloading the part's audio…"
            }
            if job.kind == .video {
                return job.progress.isAudioPart ? "Downloading the audio…" : "Downloading the video…"
            }
            return "Downloading the audio…"
        case .finishing:
            if job.kind == .video { return "Finishing up…" }
            return job.audioFormat == .mp3 ? "Converting to MP3…" : "Finishing up…"
        }
    }

    private func detailLine(_ job: DownloadController.Job) -> String {
        if let compression = job.compression {
            var parts: [String] = []
            if let fraction = compression.fraction { parts.append(DisplayFormat.percent(fraction)) }
            if compression.count > 1 { parts.append("Video \(compression.index) of \(compression.count)") }
            parts.append("Only the compressed copy is saved.")
            return parts.joined(separator: " · ")
        }
        switch job.progress.phase {
        case .starting:
            return "Getting ready to download."
        case .downloading:
            let line = DisplayFormat.progressLine(fraction: job.progress.fraction, speed: job.progress.speed, eta: job.progress.eta)
            return line.isEmpty ? "Downloading…" : line
        case .finishing:
            return job.kind == .video ? "Putting the video and audio together into one MP4." : "Saving the audio file."
        }
    }

    private func finishedView(_ finished: DownloadController.Finished) -> some View {
        let record = finished.record
        let url = URL(fileURLWithPath: record.path, isDirectory: record.isFolder)
        let headline: String = record.isFolder
            ? "Saved \(finished.savedCount) of \(count(finished.totalItems, "video")) from “\(record.title)”"
            : "Saved “\(record.title)”"
        let place: String = record.isFolder ? url.lastPathComponent : Preferences.folderDisplayName(url.deletingLastPathComponent())
        let compressed: String? = record.compression.map { quality in
            let codec = quality == .x265 ? "x265" : "Apple HEVC"
            guard let original = record.originalByteCount, original > 0 else { return codec }
            return "\(codec), down from \(DisplayFormat.bytes(original))"
        }
        let part: String? = record.clip.map { "part \($0.displayText)" }
        let summary = details([record.fileExtension.uppercased(), part, DisplayFormat.bytes(record.byteCount), compressed, "in \(place)"])
        let problem = "\(count(finished.failedCount, "video")) couldn't be downloaded. \(finished.problem ?? "")"
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(headline)
                    .font(.headline)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if finished.failedCount > 0 {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                if !record.isFolder {
                    Button("Open") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: Text helpers

    private func details(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private func siteLabel(_ site: String?) -> String? {
        guard let site, !site.lowercased().hasPrefix("youtube"), site.lowercased() != "generic" else { return nil }
        return site
    }
}

/// A 16:9 thumbnail with a placeholder while it loads or when there is none.
struct ThumbnailView: View {
    let url: URL?
    let width: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: width / 7))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width > 150 ? 8 : 5))
    }
}
