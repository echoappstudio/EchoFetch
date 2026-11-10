import Foundation

/// A stream EchoFetch's player can show while you choose a part: H.264 or HEVC with sound, as one
/// file or an HLS playlist.
public struct PreviewStream: Equatable, Sendable {
    public var url: URL
    /// Headers the site expects, such as its User-Agent.
    public var headers: [String: String]
    public var height: Int?
    public var isHLS: Bool

    public init(url: URL, headers: [String: String] = [:], height: Int? = nil, isHLS: Bool = false) {
        self.url = url
        self.headers = headers
        self.height = height
        self.isHLS = isHLS
    }
}

/// One video (or audio track) found at a link.
public struct MediaItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var uploader: String?
    public var duration: TimeInterval?
    public var thumbnailURL: URL?
    public var webpageURL: URL?
    /// The site's name as yt-dlp reports it, such as "Youtube" or "Vimeo".
    public var siteName: String?
    /// Live streams and premieres that haven't started can't be downloaded.
    public var isLiveOrUpcoming: Bool
    /// False for private, deleted or members-only entries in a playlist.
    public var isAvailable: Bool
    /// What the player shows while choosing a part. Nil when the site offers nothing it can play.
    public var previewStream: PreviewStream?

    public init(
        id: String,
        title: String,
        uploader: String? = nil,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        webpageURL: URL? = nil,
        siteName: String? = nil,
        isLiveOrUpcoming: Bool = false,
        isAvailable: Bool = true,
        previewStream: PreviewStream? = nil
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.webpageURL = webpageURL
        self.siteName = siteName
        self.isLiveOrUpcoming = isLiveOrUpcoming
        self.isAvailable = isAvailable
        self.previewStream = previewStream
    }
}

/// A playlist (or any link with several videos, such as a post with more than one clip).
public struct MediaPlaylist: Equatable, Sendable {
    public var id: String
    public var title: String
    public var uploader: String?
    public var thumbnailURL: URL?
    public var entries: [MediaItem]

    public init(id: String, title: String, uploader: String? = nil, thumbnailURL: URL? = nil, entries: [MediaItem]) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.entries = entries
    }

    public var availableCount: Int { entries.filter(\.isAvailable).count }
    public var unavailableCount: Int { entries.count - availableCount }
    /// The playlist's own picture, or the first video's.
    public var displayThumbnailURL: URL? { thumbnailURL ?? entries.first(where: { $0.thumbnailURL != nil })?.thumbnailURL }
}

public enum MediaInfo: Equatable, Sendable {
    case single(MediaItem)
    case playlist(MediaPlaylist)

    public var title: String {
        switch self {
        case .single(let item): item.title
        case .playlist(let playlist): playlist.title
        }
    }
}

public enum MediaInfoError: LocalizedError, Equatable {
    case unreadable
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable: "EchoFetch couldn't read what the download engine found at this link."
        case .empty: "There's nothing to download at this link."
        }
    }
}

/// Reads the JSON that `yt-dlp --dump-single-json --flat-playlist` prints.
public enum MediaInfoParser {
    static let unavailableTitles: Set<String> = ["[Private video]", "[Deleted video]", "[Unavailable video]"]
    static let unavailableStates: Set<String> = ["private", "needs_auth", "subscriber_only", "premium_only"]

    public static func parse(_ data: Data) throws -> MediaInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MediaInfoError.unreadable
        }
        let type = string(root["_type"]) ?? "video"
        if type == "playlist" || type == "multi_video" {
            let entries = (root["entries"] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .map { item(from: $0, fallbackSite: string(root["extractor_key"])) }
            guard !entries.isEmpty else { throw MediaInfoError.empty }
            let id = string(root["id"]) ?? ""
            let title = string(root["title"]) ?? string(root["id"]) ?? "Playlist"
            return .playlist(MediaPlaylist(
                id: id,
                title: title,
                uploader: string(root["uploader"]) ?? string(root["channel"]),
                thumbnailURL: thumbnail(from: root),
                entries: entries
            ))
        }
        var single = item(from: root, fallbackSite: nil)
        single.previewStream = previewStream(from: root)
        return .single(single)
    }

    static func item(from dictionary: [String: Any], fallbackSite: String?) -> MediaItem {
        let id = string(dictionary["id"]) ?? ""
        let title = string(dictionary["title"]) ?? string(dictionary["fulltitle"]) ?? id
        let liveStatus = string(dictionary["live_status"]) ?? ""
        let isLive = (dictionary["is_live"] as? Bool) == true || liveStatus == "is_live" || liveStatus == "is_upcoming"
        let availability = string(dictionary["availability"]) ?? ""
        let isAvailable = !title.isEmpty && !unavailableTitles.contains(title) && !unavailableStates.contains(availability)
        let webpage = string(dictionary["webpage_url"]) ?? string(dictionary["url"])
        return MediaItem(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            uploader: string(dictionary["uploader"]) ?? string(dictionary["channel"]),
            duration: number(dictionary["duration"]),
            thumbnailURL: thumbnail(from: dictionary),
            webpageURL: webpage.flatMap(URL.init(string:)),
            siteName: string(dictionary["extractor_key"]) ?? string(dictionary["ie_key"]) ?? fallbackSite,
            isLiveOrUpcoming: isLive,
            isAvailable: isAvailable
        )
    }

    /// The best stream for the player: H.264 or HEVC with sound, around 720p, HLS before a single
    /// file of the same height. A direct link to an MP4 (codecs unknown) is used when nothing better is
    /// listed. VP9 and AV1 are skipped: the player can't count on them.
    static func previewStream(from dictionary: [String: Any]) -> PreviewStream? {
        var formats = (dictionary["formats"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        if formats.isEmpty, dictionary["url"] != nil { formats = [dictionary] }
        let sharedHeaders = headers(dictionary["http_headers"])

        struct Candidate {
            let stream: PreviewStream
            let knownCodecs: Bool
        }
        let candidates = formats.compactMap { format -> Candidate? in
            guard let text = string(format["url"]), let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
            let streamProtocol = (string(format["protocol"]) ?? scheme).lowercased()
            let isHLS = streamProtocol == "m3u8" || streamProtocol == "m3u8_native"
            guard isHLS || streamProtocol == "https" || streamProtocol == "http" else { return nil }
            if (format["has_drm"] as? NSNumber)?.boolValue == true { return nil }
            let video = string(format["vcodec"])?.lowercased()
            let audio = string(format["acodec"])?.lowercased()
            if video == "none" || audio == "none" { return nil }
            let playableVideo = ["avc1", "avc3", "h264", "hvc1", "hev1", "h265"]
            if let video, !playableVideo.contains(where: { video.hasPrefix($0) }) { return nil }
            if let audio, !["mp4a", "aac", "mp3", "ac-3", "ec-3"].contains(where: { audio.hasPrefix($0) }) { return nil }
            let ext = (string(format["ext"]) ?? url.pathExtension).lowercased()
            if !isHLS, !["mp4", "m4v", "mov"].contains(ext) { return nil }
            let height = number(format["height"]).map { Int($0) }
            let formatHeaders = headers(format["http_headers"])
            return Candidate(
                stream: PreviewStream(url: url, headers: formatHeaders.isEmpty ? sharedHeaders : formatHeaders, height: height, isHLS: isHLS),
                knownCodecs: video != nil
            )
        }
        let best = candidates.max { lhs, rhs in
            previewRank(lhs.stream, knownCodecs: lhs.knownCodecs)
                .lexicographicallyPrecedes(previewRank(rhs.stream, knownCodecs: rhs.knownCodecs))
        }
        return best?.stream
    }

    /// Higher is better: known codecs, then 720p or just under, then HLS.
    static func previewRank(_ stream: PreviewStream, knownCodecs: Bool) -> [Int] {
        let height = stream.height ?? 0
        let fits = height > 0 && height <= 720
        // Under 720: taller is better. Over 720: closer to 720 is better. Unknown heights come last.
        let closeness = height == 0 ? -100_000 : (fits ? height : 720 - height)
        return [knownCodecs ? 1 : 0, closeness, stream.isHLS ? 1 : 0]
    }

    static func headers(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let text = value as? String { result[key] = text }
        }
        return result
    }

    /// The "thumbnail" field, otherwise the widest entry in "thumbnails" (the last one when no
    /// widths are given, since yt-dlp lists the best last).
    static func thumbnail(from dictionary: [String: Any]) -> URL? {
        if let direct = string(dictionary["thumbnail"]), let url = URL(string: direct) { return url }
        let thumbnails = (dictionary["thumbnails"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let candidates = thumbnails.compactMap { entry -> (url: URL, width: Double)? in
            guard let text = string(entry["url"]), let url = URL(string: text) else { return nil }
            return (url, number(entry["width"]) ?? 0)
        }
        guard let widest = candidates.max(by: { $0.width < $1.width }), widest.width > 0 else {
            return candidates.last?.url
        }
        return widest.url
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
