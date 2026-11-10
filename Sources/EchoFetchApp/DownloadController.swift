import AppKit
import EchoFetchCore
import Foundation
import Observation

/// The Download tab: the link, its preview, and the one download that can run at a time.
@MainActor
@Observable
final class DownloadController {
    enum PreviewState: Equatable {
        case empty
        case loading
        case loaded(MediaInfo)
        case failed(String)
    }

    /// Compressing the downloaded videos, one at a time.
    struct Compression: Equatable {
        let quality: VideoQuality
        var index: Int
        let count: Int
        var fraction: Double?
    }

    struct Job: Equatable {
        let kind: DownloadKind
        let audioFormat: AudioFormat
        let title: String
        let isPlaylist: Bool
        let totalItems: Int
        let clip: ClipRange?
        var progress: DownloadProgressState
        var compression: Compression?
    }

    struct Finished: Equatable {
        let record: DownloadRecord
        let savedCount: Int
        let totalItems: Int
        let failedCount: Int
        let problem: String?
    }

    enum JobState: Equatable {
        case idle
        case running(Job)
        case finished(Finished)
        case failed(String)
        case cancelled
    }

    static let notALinkMessage = "That doesn't look like a link. Copy the address of a video or playlist and paste it here."

    var linkText = ""
    private(set) var wholePlaylist = false
    private(set) var preview: PreviewState = .empty
    private(set) var job: JobState = .idle
    /// Set when the link is a YouTube video opened from a playlist.
    private(set) var playlistOffer: String?
    private(set) var lastKind: DownloadKind?
    /// The part of the previewed video to download; nil downloads all of it.
    private(set) var clip: ClipRange?

    private let tools: ToolsController
    private let history: HistoryController
    private var previewedLink: String?
    private var previewedWholePlaylist = false
    private var previewGeneration = 0
    private var previewProcess: ToolProcess?
    private var downloadProcess: ToolProcess?
    private var compressor: VideoCompressor?
    private var lookupDelay: Task<Void, Never>?
    private var lastPasteboardChangeCount = -1
    private var lastFilledLink: String?

    init(tools: ToolsController, history: HistoryController) {
        self.tools = tools
        self.history = history
    }

    var isDownloading: Bool {
        if case .running = job { return true }
        return false
    }

    var canDownload: Bool {
        guard case .loaded = preview else { return false }
        return !isDownloading && tools.setupState == .ready
    }

    /// The previewed video when the link is a single video (parts can't be chosen for playlists).
    var previewedVideo: MediaItem? {
        if case .loaded(.single(let item)) = preview { return item }
        return nil
    }

    // MARK: Part

    /// Sets the part of `video` to download. A part covering the whole video, or none, downloads
    /// everything. Ignored when the link has changed since the part was chosen.
    func setClip(_ newClip: ClipRange?, for video: MediaItem) {
        guard !isDownloading, let item = previewedVideo, item.id == video.id, item.webpageURL == video.webpageURL else { return }
        guard var adjusted = newClip else {
            clip = nil
            return
        }
        // The player's length can be a moment longer than the one the site reported.
        if let length = item.duration, length > 0 { adjusted.end = min(adjusted.end, length) }
        guard adjusted.isValid(videoLength: item.duration), !adjusted.coversWholeVideo(videoLength: item.duration) else {
            clip = nil
            return
        }
        clip = adjusted
    }

    // MARK: Link

    /// Called whenever the link box changes. Looks the link up after a short pause in typing.
    func linkTextChanged() {
        lookupDelay?.cancel()
        guard let url = LinkPolicy.link(from: linkText) else {
            cancelPreview()
            preview = .empty
            playlistOffer = nil
            return
        }
        guard url.absoluteString != previewedLink else { return }
        lookupDelay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.lookUp(showProblems: false)
        }
    }

    /// Looks up the link in the box now (Return key, Paste button, or a copied link).
    func lookUp(showProblems: Bool = true) {
        lookupDelay?.cancel()
        guard let url = LinkPolicy.link(from: linkText) else {
            cancelPreview()
            let isEmpty = linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            preview = (isEmpty || !showProblems) ? .empty : .failed(Self.notALinkMessage)
            playlistOffer = nil
            return
        }
        let link = url.absoluteString
        let offer = LinkPolicy.playlistOffer(for: url)
        if offer != playlistOffer { wholePlaylist = false }
        playlistOffer = offer
        let wantsPlaylist = offer != nil && wholePlaylist
        if link == previewedLink, wantsPlaylist == previewedWholePlaylist, preview != .empty {
            if case .failed = preview {} else { return }
        }

        cancelPreview()
        clip = nil
        previewGeneration += 1
        let generation = previewGeneration
        previewedLink = link
        previewedWholePlaylist = wantsPlaylist
        preview = .loading
        Task { [weak self] in
            await self?.fetchPreview(link: link, wholePlaylist: wantsPlaylist, generation: generation)
        }
    }

    func setWholePlaylist(_ value: Bool) {
        guard value != wholePlaylist else { return }
        wholePlaylist = value
        lookUp()
    }

    func pasteLink() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        lastFilledLink = nil
        linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lookUp()
    }

    func clearLink() {
        lookupDelay?.cancel()
        cancelPreview()
        linkText = ""
        lastFilledLink = nil
        clip = nil
        preview = .empty
        playlistOffer = nil
    }

    /// When EchoFetch comes to the front with a new link on the clipboard, puts it in the box and
    /// looks it up. A link the user typed or pasted themselves is never replaced.
    func fillInCopiedLink() {
        guard Preferences.fillInCopiedLinks, tools.setupState == .ready else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), let url = LinkPolicy.link(from: text) else { return }
        let link = url.absoluteString
        let current = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == lastFilledLink, link != current else { return }
        linkText = link
        lastFilledLink = link
        lookUp()
    }

    private func cancelPreview() {
        previewGeneration += 1
        previewProcess?.cancel()
        previewProcess = nil
        previewedLink = nil
    }

    private func fetchPreview(link: String, wholePlaylist: Bool, generation: Int) async {
        guard await tools.waitUntilReady() else {
            if generation == previewGeneration {
                preview = .failed(tools.setupProblem ?? "The download tools aren't ready.")
            }
            return
        }
        guard generation == previewGeneration else { return }
        let process = ToolProcess(
            executableURL: tools.paths.ytDLP,
            arguments: DownloadCommand.previewArguments(link: link, wholePlaylist: wholePlaylist, tools: tools.paths)
        )
        previewProcess = process
        do {
            let result = try await process.run(collectOutput: true)
            guard generation == previewGeneration, !result.wasCancelled else { return }
            previewProcess = nil
            let json = Data(result.standardOutput.joined(separator: "\n").utf8)
            if result.exitCode == 0, let info = try? MediaInfoParser.parse(json) {
                preview = .loaded(info)
            } else {
                preview = .failed(DownloadErrorExplainer.explain(errorLines: result.standardError, exitCode: result.exitCode))
            }
        } catch {
            guard generation == previewGeneration else { return }
            previewProcess = nil
            preview = .failed(error.localizedDescription)
        }
    }

    // MARK: Download

    func download(_ kind: DownloadKind) {
        guard !isDownloading, case .loaded(let info) = preview, let link = previewedLink else { return }
        let totalItems: Int
        let isPlaylist: Bool
        switch info {
        case .single:
            totalItems = 1
            isPlaylist = false
        case .playlist(let playlist):
            totalItems = playlist.entries.count
            isPlaylist = true
        }
        let request = DownloadRequest(
            link: link,
            kind: kind,
            audioFormat: Preferences.audioFormat,
            isPlaylist: isPlaylist,
            allowsAV1: VideoSupport.playsAV1,
            clip: isPlaylist ? nil : clip,
            videoQuality: kind == .video ? Preferences.videoQuality : .original
        )
        lastKind = kind
        job = .running(Job(
            kind: kind,
            audioFormat: request.audioFormat,
            title: info.title,
            isPlaylist: request.isPlaylist,
            totalItems: totalItems,
            clip: request.effectiveClip,
            progress: DownloadProgressState(partLength: request.effectiveClip?.length),
            compression: nil
        ))
        Task { [weak self] in
            await self?.runDownload(request: request, info: info)
        }
    }

    func retry() {
        guard let lastKind else { return }
        download(lastKind)
    }

    func cancelDownload() {
        downloadProcess?.cancel()
        compressor?.cancel()
    }

    /// Stops any running tools right away (EchoFetch is quitting).
    func stopEverything() {
        downloadProcess?.cancel()
        compressor?.cancel()
        previewProcess?.cancel()
    }

    private func runDownload(request: DownloadRequest, info: MediaInfo) async {
        guard await tools.waitUntilReady() else {
            job = .failed(tools.setupProblem ?? "The download tools aren't ready.")
            return
        }
        let fileManager = FileManager.default
        let destination = Preferences.saveFolder
        let partial = AppSupportDirectory.partialDownloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A video EchoFetch compresses is downloaded into the partial folder first; only the
        // compressed copy reaches the save folder.
        let downloaded = request.compresses ? partial.appendingPathComponent("Downloaded", isDirectory: true) : destination
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: downloaded, withIntermediateDirectories: true)
        } catch {
            job = .failed("EchoFetch couldn't use the download folder: \(error.localizedDescription)")
            return
        }
        defer { try? fileManager.removeItem(at: partial) }

        let process = ToolProcess(
            executableURL: tools.paths.ytDLP,
            arguments: DownloadCommand.downloadArguments(for: request, destination: downloaded, temporaryDirectory: partial, tools: tools.paths)
        )
        downloadProcess = process
        let log = DownloadEventLog()
        let result: ToolProcessResult
        do {
            result = try await process.run { line in
                guard let event = DownloadEventParser.parse(line) else { return }
                log.record(event)
                Task { @MainActor [weak self] in
                    self?.apply(event)
                }
            }
            downloadProcess = nil
        } catch {
            downloadProcess = nil
            job = .failed(error.localizedDescription)
            return
        }

        if result.wasCancelled {
            job = .cancelled
            return
        }
        let files = log.files
        guard !files.isEmpty else {
            job = .failed(DownloadErrorExplainer.explain(errorLines: result.standardError, exitCode: result.exitCode))
            return
        }
        let failedDownloads = request.isPlaylist ? DownloadOutcome.failedItemCount(in: result.standardError) : 0
        let downloadProblem = failedDownloads > 0 ? DownloadErrorExplainer.explain(errorLines: result.standardError, exitCode: result.exitCode) : nil

        guard request.compresses else {
            finish(files: files, originalBytes: nil, failedCount: failedDownloads, problem: downloadProblem, request: request, info: info)
            return
        }
        await compress(
            files: files,
            from: downloaded,
            into: destination,
            work: partial.appendingPathComponent("Compressed", isDirectory: true),
            failedDownloads: failedDownloads,
            downloadProblem: downloadProblem,
            request: request,
            info: info
        )
    }

    /// Compresses each downloaded video into the save folder, keeping the folders yt-dlp made
    /// (a playlist's folder). A video that can't be compressed is counted like a failed download.
    private func compress(
        files: [String],
        from downloaded: URL,
        into destination: URL,
        work: URL,
        failedDownloads: Int,
        downloadProblem: String?,
        request: DownloadRequest,
        info: MediaInfo
    ) async {
        let fileManager = FileManager.default
        let compressor = VideoCompressor(tools: tools.paths)
        self.compressor = compressor
        defer { self.compressor = nil }

        var saved: [String] = []
        var originalBytes: Int64 = 0
        var failedCompressions = 0
        var compressionProblem: String?
        for (index, file) in files.enumerated() {
            updateCompression(Compression(quality: request.videoQuality, index: index + 1, count: files.count, fraction: nil))
            let input = URL(fileURLWithPath: file)
            let relative = (FileNames.relativePath(of: input, inside: downloaded) as NSString).deletingPathExtension + ".mp4"
            let output = work.appendingPathComponent(relative, isDirectory: false)
            let step = index + 1
            do {
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let result = try await compressor.compress(input: input, output: output, quality: request.videoQuality) { fraction in
                    Task { @MainActor [weak self] in
                        self?.updateCompressionFraction(fraction, step: step)
                    }
                }
                guard let result else {
                    job = .cancelled
                    return
                }
                let target = FileNames.available(destination.appendingPathComponent(relative, isDirectory: false)) {
                    fileManager.fileExists(atPath: $0)
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: result.output, to: target)
                saved.append(target.path)
                originalBytes += result.originalBytes
            } catch {
                if compressor.isCancelled {
                    job = .cancelled
                    return
                }
                failedCompressions += 1
                compressionProblem = error.localizedDescription
            }
            try? fileManager.removeItem(at: input)
        }

        guard !saved.isEmpty else {
            job = .failed(compressionProblem ?? CompressionError.failed("").localizedDescription)
            return
        }
        let failedCount = failedDownloads + failedCompressions
        finish(
            files: saved,
            originalBytes: originalBytes,
            failedCount: failedCount,
            problem: compressionProblem ?? downloadProblem,
            request: request,
            info: info
        )
    }

    private func apply(_ event: DownloadEvent) {
        guard case .running(var current) = job, current.compression == nil else { return }
        current.progress.apply(event)
        job = .running(current)
    }

    private func updateCompression(_ compression: Compression) {
        guard case .running(var current) = job else { return }
        current.compression = compression
        job = .running(current)
    }

    private func updateCompressionFraction(_ fraction: Double, step: Int) {
        guard case .running(var current) = job, var compression = current.compression, compression.index == step else { return }
        compression.fraction = fraction
        current.compression = compression
        job = .running(current)
    }

    private func finish(files: [String], originalBytes: Int64?, failedCount: Int, problem: String?, request: DownloadRequest, info: MediaInfo) {
        guard let location = DownloadOutcome.savedLocation(files: files, isPlaylist: request.isPlaylist) else { return }
        let uploader: String?
        let thumbnail: URL?
        let totalItems: Int
        switch info {
        case .single(let item):
            uploader = item.uploader
            thumbnail = item.thumbnailURL
            totalItems = 1
        case .playlist(let playlist):
            uploader = playlist.uploader
            thumbnail = playlist.displayThumbnailURL
            totalItems = playlist.entries.count
        }
        let record = DownloadRecord(
            title: info.title,
            uploader: uploader,
            sourceURL: request.link,
            thumbnailURL: thumbnail?.absoluteString,
            kind: request.kind,
            fileExtension: (files[0] as NSString).pathExtension.lowercased(),
            path: location.path,
            isFolder: location.isFolder,
            itemCount: files.count,
            byteCount: files.reduce(Int64(0)) { $0 + Self.fileSize($1) },
            createdAt: Date(),
            clip: request.effectiveClip,
            videoQuality: request.compresses ? request.videoQuality.rawValue : nil,
            originalByteCount: originalBytes
        )
        history.add(record)
        job = .finished(Finished(
            record: record,
            savedCount: files.count,
            totalItems: totalItems,
            failedCount: failedCount,
            problem: failedCount > 0 ? problem : nil
        ))
    }

    private static func fileSize(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
