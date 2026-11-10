import Foundation

/// One finished download: a single file, or a playlist's folder.
public struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var uploader: String?
    public var sourceURL: String
    public var thumbnailURL: String?
    public var kind: DownloadKind
    /// "mp4", "m4a" or "mp3".
    public var fileExtension: String
    /// The saved file, or the playlist's folder.
    public var path: String
    public var isFolder: Bool
    public var itemCount: Int
    public var byteCount: Int64
    public var createdAt: Date
    /// The part that was saved, when it wasn't the whole video. Missing in records from before 0.4.0.
    public var clip: ClipRange?
    /// `VideoQuality`'s raw value for compressed videos ("apple-hevc", "x265"); nil for originals
    /// and audio. Kept as text so an unknown value never stops the history loading.
    public var videoQuality: String?
    /// The size yt-dlp downloaded before compressing.
    public var originalByteCount: Int64?

    public init(
        id: UUID = UUID(),
        title: String,
        uploader: String?,
        sourceURL: String,
        thumbnailURL: String?,
        kind: DownloadKind,
        fileExtension: String,
        path: String,
        isFolder: Bool,
        itemCount: Int,
        byteCount: Int64,
        createdAt: Date = Date(),
        clip: ClipRange? = nil,
        videoQuality: String? = nil,
        originalByteCount: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL
        self.kind = kind
        self.fileExtension = fileExtension
        self.path = path
        self.isFolder = isFolder
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.clip = clip
        self.videoQuality = videoQuality
        self.originalByteCount = originalByteCount
    }

    /// The compression used, when it's one this version knows.
    public var compression: VideoQuality? {
        videoQuality.flatMap(VideoQuality.init(rawValue:)).flatMap { $0.isCompressed ? $0 : nil }
    }
}

/// Keeps the download history as one JSON file in EchoFetch's Application Support folder.
/// Removing an entry never touches the downloaded file.
public struct DownloadHistoryStore: Sendable {
    public static let fileName = "history.json"
    public static let maximumRecords = 500

    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public static func standard() -> DownloadHistoryStore {
        DownloadHistoryStore(directory: AppSupportDirectory.url)
    }

    /// Newest first. An unreadable or missing file gives an empty history.
    public func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [] }
        return Self.sorted(records)
    }

    public func save(_ records: [DownloadRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Self.sorted(records)).write(to: fileURL, options: .atomic)
    }

    /// Adds a record at the top and keeps the newest `maximumRecords`.
    public static func adding(_ record: DownloadRecord, to records: [DownloadRecord]) -> [DownloadRecord] {
        sorted([record] + records.filter { $0.id != record.id })
    }

    static func sorted(_ records: [DownloadRecord]) -> [DownloadRecord] {
        Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(maximumRecords))
    }
}

/// ~/Library/Application Support/EchoFetch
public enum AppSupportDirectory {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("EchoFetch", isDirectory: true)
    }

    public static var tools: URL { url.appendingPathComponent("Tools", isDirectory: true) }

    /// ~/Library/Caches/EchoFetch/Partial: unfinished downloads, removed when each download ends.
    public static var partialDownloads: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent("EchoFetch/Partial", isDirectory: true)
    }
}
