import Foundation

/// One progress report for the file being downloaded right now.
public struct ProgressSample: Equatable, Sendable {
    /// "downloading", "finished" or "error".
    public var status: String
    public var downloadedBytes: Double?
    /// The exact size when known, otherwise yt-dlp's estimate.
    public var totalBytes: Double?
    public var speed: Double?
    public var eta: Double?
    /// True while the audio half of a video is downloading.
    public var isAudioOnly: Bool

    public init(status: String, downloadedBytes: Double?, totalBytes: Double?, speed: Double?, eta: Double?, isAudioOnly: Bool) {
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
        self.isAudioOnly = isAudioOnly
    }

    public var fraction: Double? {
        guard let downloadedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(max(downloadedBytes / totalBytes, 0), 1)
    }
}

public enum DownloadEvent: Equatable, Sendable {
    case progress(ProgressSample)
    /// A video is about to download. `index` and `count` are set for playlists.
    case item(index: Int?, count: Int?, title: String)
    /// A finished file, at its final location.
    case file(String)
    /// How far ffmpeg has got, in seconds, while it downloads a part.
    case partTime(Double)
}

/// Reads the marked lines that `DownloadCommand.downloadArguments` asks yt-dlp to print.
public enum DownloadEventParser {
    public static func parse(_ line: String) -> DownloadEvent? {
        if line.hasPrefix(DownloadCommand.progressMarker) {
            let fields = line.dropFirst(DownloadCommand.progressMarker.count)
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 7 else { return nil }
            return .progress(ProgressSample(
                status: fields[0],
                downloadedBytes: number(fields[1]),
                totalBytes: number(fields[2]) ?? number(fields[3]),
                speed: number(fields[4]),
                eta: number(fields[5]),
                isAudioOnly: fields[6] == "none"
            ))
        }
        if line.hasPrefix(DownloadCommand.itemMarker) {
            let fields = line.dropFirst(DownloadCommand.itemMarker.count)
                .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 3 else { return nil }
            let title = fields[2] == "NA" ? "" : fields[2]
            return .item(index: Int(fields[0]), count: Int(fields[1]), title: title)
        }
        if let seconds = FFmpegProgress.seconds(fromLine: line) {
            return .partTime(seconds)
        }
        if line.hasPrefix(DownloadCommand.fileMarker) {
            let path = String(line.dropFirst(DownloadCommand.fileMarker.count))
            guard path.hasPrefix("/") else { return nil }
            return .file(path)
        }
        return nil
    }

    static func number(_ field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed != "NA", let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

/// What the Download tab shows while a download runs.
public struct DownloadProgressState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case starting
        case downloading
        /// Merging video and audio, converting audio, or moving the file into place.
        case finishing
    }

    public var phase: Phase = .starting
    public var fraction: Double?
    public var isAudioPart = false
    public var speed: Double?
    public var eta: Double?
    public var itemIndex: Int?
    public var itemCount: Int?
    public var itemTitle: String?
    public var savedFiles: [String] = []
    /// The length of the part being downloaded, which ffmpeg's progress is measured against.
    public var partLength: Double?

    public init(partLength: Double? = nil) {
        self.partLength = partLength
    }

    public mutating func apply(_ event: DownloadEvent) {
        switch event {
        case .item(let index, let count, let title):
            itemIndex = index ?? itemIndex
            itemCount = count ?? itemCount
            itemTitle = title.isEmpty ? nil : title
            phase = .starting
            fraction = nil
            speed = nil
            eta = nil
            isAudioPart = false
        case .progress(let sample):
            switch sample.status {
            case "downloading":
                phase = .downloading
                fraction = sample.fraction
                speed = sample.speed
                eta = sample.eta
                isAudioPart = sample.isAudioOnly
            case "finished":
                phase = .finishing
                fraction = 1
                speed = nil
                eta = nil
            default:
                break
            }
        case .partTime(let seconds):
            guard phase != .finishing else { return }
            phase = .downloading
            fraction = FFmpegProgress.fraction(seconds: seconds, of: partLength)
            speed = nil
            eta = nil
        case .file(let path):
            if !savedFiles.contains(path) { savedFiles.append(path) }
            phase = .finishing
            fraction = 1
            speed = nil
            eta = nil
        }
    }

    /// How far through the whole playlist, counting the current video's progress. Nil for a
    /// single video.
    public var playlistFraction: Double? {
        guard let itemCount, itemCount > 1 else { return nil }
        let index = min(max(itemIndex ?? 1, 1), itemCount)
        let current: Double = phase == .finishing ? 1 : (fraction ?? 0)
        return min(max((Double(index - 1) + current) / Double(itemCount), 0), 1)
    }
}

/// Collects finished files from yt-dlp's output as it arrives (on a background thread), so the
/// result doesn't depend on when the interface catches up.
public final class DownloadEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFiles: [String] = []

    public init() {}

    public func record(_ event: DownloadEvent) {
        guard case .file(let path) = event else { return }
        lock.lock()
        if !storedFiles.contains(path) { storedFiles.append(path) }
        lock.unlock()
    }

    public var files: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedFiles
    }
}

public enum DownloadOutcome {
    /// Each video yt-dlp couldn't download is reported on its own "ERROR:" line.
    public static func failedItemCount(in errorLines: [String]) -> Int {
        errorLines.filter { $0.hasPrefix("ERROR:") }.count
    }

    /// Where the result lives: the file for a single video, the playlist's folder for a playlist.
    public static func savedLocation(files: [String], isPlaylist: Bool) -> (path: String, isFolder: Bool)? {
        guard let first = files.first else { return nil }
        if isPlaylist {
            return ((first as NSString).deletingLastPathComponent, true)
        }
        return (first, false)
    }
}
