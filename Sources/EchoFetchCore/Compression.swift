import Foundation

/// How a downloaded video is saved.
public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    /// The site's own video, copied as it is.
    case original
    /// HEVC from the Mac's built-in encoder: fast, good quality, smaller.
    case appleHEVC = "apple-hevc"
    /// HEVC from x265: the smallest files at good quality, but slower.
    case x265

    public var isCompressed: Bool { self != .original }

    /// "Original", "Smaller (Apple HEVC)", "Smallest (x265)".
    public var title: String {
        switch self {
        case .original: "Original"
        case .appleHEVC: "Smaller (Apple HEVC)"
        case .x265: "Smallest (x265)"
        }
    }

    /// Reads a saved value; anything unknown is Original.
    public static func saved(_ rawValue: String?) -> VideoQuality {
        rawValue.flatMap(VideoQuality.init(rawValue:)) ?? .original
    }
}

/// What ffprobe says about a downloaded video.
public struct SourceVideo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double?
    public var duration: Double?
    /// Bits per second of the picture alone, measured or worked out from the file.
    public var videoBitrate: Double?
    /// "aac", "opus" and so on; nil when there's no sound.
    public var audioCodec: String?
    /// "h264", "vp9", "hevc"…
    public var videoCodec: String?
    /// The MP4 tag, such as "hvc1" or "avc1".
    public var videoTag: String?

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Double?,
        duration: Double?,
        videoBitrate: Double?,
        audioCodec: String?,
        videoCodec: String? = nil,
        videoTag: String? = nil
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.duration = duration
        self.videoBitrate = videoBitrate
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.videoTag = videoTag
    }
}

public enum CompressionError: LocalizedError, Equatable {
    case unreadable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "EchoFetch couldn't read the downloaded video to compress it."
        case .failed(let detail):
            detail.isEmpty
                ? "EchoFetch couldn't compress the video."
                : "EchoFetch couldn't compress the video: \(detail)"
        }
    }
}

/// Reads `ffprobe -show_format -show_streams -of json`.
public enum VideoProbe {
    public static func arguments(input: URL) -> [String] {
        ["-v", "error", "-show_format", "-show_streams", "-of", "json", input.path]
    }

    public static func parse(_ data: Data) throws -> SourceVideo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CompressionError.unreadable
        }
        let streams = (root["streams"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let format = root["format"] as? [String: Any] ?? [:]
        let video = streams.first { stream in
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            let isCover = (disposition["attached_pic"] as? NSNumber)?.intValue == 1
            return stream["codec_type"] as? String == "video" && !isCover
        }
        guard let video,
              let width = integer(video["width"]), width > 0,
              let height = integer(video["height"]), height > 0 else {
            throw CompressionError.unreadable
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let duration = positive(format["duration"]) ?? positive(video["duration"])
        let audioBitrate = audio.map { positive($0["bit_rate"]) ?? 128_000 } ?? 0
        var videoBitrate = positive(video["bit_rate"])
        if videoBitrate == nil, let total = positive(format["bit_rate"]) {
            videoBitrate = total - audioBitrate
        }
        if videoBitrate == nil, let size = positive(format["size"]), let duration {
            videoBitrate = size * 8 / duration - audioBitrate
        }
        if let measured = videoBitrate, measured <= 0 { videoBitrate = nil }
        return SourceVideo(
            width: width,
            height: height,
            framesPerSecond: frameRate(video["avg_frame_rate"] as? String) ?? frameRate(video["r_frame_rate"] as? String),
            duration: duration,
            videoBitrate: videoBitrate,
            audioCodec: (audio?["codec_name"] as? String)?.lowercased(),
            videoCodec: (video["codec_name"] as? String)?.lowercased(),
            videoTag: (video["codec_tag_string"] as? String)?.lowercased()
        )
    }

    /// "30000/1001" → 29.97. Nil for "0/0" and anything unreadable.
    static func frameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        guard let numerator = Double(parts.first ?? "") else { return nil }
        let denominator = parts.count > 1 ? Double(parts[1]) ?? 0 : 1
        guard denominator > 0 else { return nil }
        let rate = numerator / denominator
        return rate.isFinite && rate > 0 ? rate : nil
    }

    static func positive(_ value: Any?) -> Double? {
        let number: Double?
        if let text = value as? String {
            number = Double(text)
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    static func integer(_ value: Any?) -> Int? {
        positive(value).map { Int($0) }
    }
}

/// Builds the ffmpeg command that turns a downloaded video into a smaller HEVC MP4.
public enum CompressCommand {
    /// x265 settings: CRF 26 keeps good quality at a much smaller size; "medium" is x265's
    /// standard trade between time and size.
    public static let x265Quality = 26
    public static let x265Preset = "medium"

    /// Apple HEVC aims for 60% of the downloaded video's bit rate, kept between 0.035 and 0.1 bits
    /// per pixel per frame, and never more than 85% of the original.
    static let appleShare = 0.6
    static let appleMinimumBitsPerPixel = 0.035
    static let appleMaximumBitsPerPixel = 0.1
    static let appleNeverAbove = 0.85
    /// Used when the downloaded video's bit rate is unknown.
    static let appleDefaultBitsPerPixel = 0.06

    public static func arguments(input: URL, output: URL, quality: VideoQuality, source: SourceVideo) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-y", "-nostats",
            "-loglevel", "error",
            "-progress", "pipe:1",
            "-i", input.path,
            "-map", "0:v:0",
            "-map", "0:a:0?"
        ]
        switch quality {
        case .x265, .original:
            arguments += [
                "-c:v", "libx265",
                "-preset", x265Preset,
                "-crf", String(x265Quality),
                "-x265-params", "log-level=error"
            ]
        case .appleHEVC:
            arguments += [
                "-c:v", "hevc_videotoolbox",
                "-allow_sw", "1",
                "-b:v", "\(appleBitrate(for: source) / 1000)k"
            ]
        }
        // QuickTime only plays HEVC in MP4 when it's tagged hvc1.
        arguments += ["-tag:v", "hvc1"]
        if let codec = source.audioCodec, codec != "aac" {
            // Opus and other sounds become AAC, so QuickTime plays the file.
            arguments += ["-c:a", "aac", "-b:a", "192k"]
        } else {
            arguments += ["-c:a", "copy"]
        }
        arguments += ["-map_metadata", "0", "-movflags", "+faststart", "-f", "mp4", output.path]
        return arguments
    }

    /// Bits per second for Apple HEVC.
    public static func appleBitrate(for source: SourceVideo) -> Int {
        let rate = min(max(source.framesPerSecond ?? 30, 1), 120)
        let pixelsPerSecond = Double(source.width * source.height) * rate
        let lowest = pixelsPerSecond * appleMinimumBitsPerPixel
        let highest = pixelsPerSecond * appleMaximumBitsPerPixel
        var target: Double
        if let original = source.videoBitrate {
            target = min(max(original * appleShare, lowest), highest)
            target = min(target, original * appleNeverAbove)
        } else {
            target = pixelsPerSecond * appleDefaultBitsPerPixel
        }
        // Whole kilobits, at least 100 kbit/s.
        return max(100, Int((target / 1000).rounded())) * 1000
    }
}

/// Reads the `key=value` lines ffmpeg prints with `-progress pipe:1`.
public enum FFmpegProgress {
    public static let timeKey = "out_time_us="

    /// The position written so far, in seconds (negative while ffmpeg reads up to a part's start).
    public static func seconds(fromLine line: String) -> Double? {
        guard line.hasPrefix(timeKey) else { return nil }
        let value = line.dropFirst(timeKey.count).trimmingCharacters(in: .whitespaces)
        guard let microseconds = Double(value), microseconds.isFinite else { return nil }
        return microseconds / 1_000_000
    }

    /// How far through, from 0 to 1.
    public static func fraction(seconds: Double, of total: Double?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(max(seconds / total, 0), 1)
    }
}

public enum FileNames {
    /// The URL itself when nothing is there, otherwise "Name 2.mp4", "Name 3.mp4"…
    public static func available(_ url: URL, exists: (String) -> Bool) -> URL {
        guard exists(url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(name, isDirectory: false)
            if !exists(candidate.path) { return candidate }
            number += 1
        }
    }

    /// `file`'s path inside `folder` ("Playlist/001 - Video.mp4"), or just its name when it isn't inside.
    public static func relativePath(of file: URL, inside folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return file.lastPathComponent
    }
}

public struct CompressionResult: Equatable, Sendable {
    public let output: URL
    public let originalBytes: Int64
    public let compressedBytes: Int64

    public init(output: URL, originalBytes: Int64, compressedBytes: Int64) {
        self.output = output
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
    }
}

/// Compresses one downloaded video with the bundled ffprobe and ffmpeg. One file at a time; `cancel()`
/// stops the running tool.
public final class VideoCompressor: @unchecked Sendable {
    private let tools: ToolPaths
    private let lock = NSLock()
    private var current: ToolProcess?
    private var cancelled = false

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = current
        lock.unlock()
        running?.cancel()
    }

    /// Writes `output` (an MP4) from `input`. Returns nil when cancelled. `onProgress` gets 0…1
    /// on a background thread.
    public func compress(
        input: URL,
        output: URL,
        quality: VideoQuality,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> CompressionResult? {
        guard let probeProcess = start(ToolProcess(executableURL: tools.ffprobe, arguments: VideoProbe.arguments(input: input))) else {
            return nil
        }
        let probe = try await probeProcess.run(collectOutput: true)
        guard !probe.wasCancelled, !isCancelled else { return nil }
        guard probe.exitCode == 0 else { throw CompressionError.unreadable }
        let source = try VideoProbe.parse(Data(probe.standardOutput.joined(separator: "\n").utf8))

        try? FileManager.default.removeItem(at: output)
        let arguments = CompressCommand.arguments(input: input, output: output, quality: quality, source: source)
        guard let encodeProcess = start(ToolProcess(executableURL: tools.ffmpeg, arguments: arguments)) else {
            return nil
        }
        let total = source.duration
        let result = try await encodeProcess.run { line in
            guard let seconds = FFmpegProgress.seconds(fromLine: line),
                  let fraction = FFmpegProgress.fraction(seconds: seconds, of: total) else { return }
            onProgress(fraction)
        }
        if result.wasCancelled || isCancelled {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            let detail = result.standardError.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            throw CompressionError.failed(detail)
        }
        return CompressionResult(output: output, originalBytes: Self.size(of: input), compressedBytes: Self.size(of: output))
    }

    /// Remembers the process so `cancel()` can reach it; nil when already cancelled.
    private func start(_ process: ToolProcess) -> ToolProcess? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        current = process
        return process
    }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
