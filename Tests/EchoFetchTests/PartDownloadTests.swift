import Foundation
import XCTest
@testable import EchoFetchCore

/// Command lines, progress and saved records for parts and compressed videos (0.4.0).
final class PartDownloadTests: XCTestCase {
    private let tools = ToolPaths(directory: URL(fileURLWithPath: "/Users/me/Library/Application Support/EchoFetch/Tools", isDirectory: true))
    private let destination = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
    private let temporary = URL(fileURLWithPath: "/Users/me/Library/Caches/EchoFetch/Partial/job", isDirectory: true)

    private func arguments(_ request: DownloadRequest) -> [String] {
        DownloadCommand.downloadArguments(for: request, destination: destination, temporaryDirectory: temporary, tools: tools)
    }

    func testAPartOfAVideoIsDownloadedThroughFFmpegWithItsTimesInTheName() {
        let request = DownloadRequest(
            link: "https://www.youtube.com/watch?v=a", kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: false,
            clip: ClipRange(start: 90, end: 165.5)
        )
        XCTAssertEqual(Array(arguments(request).suffix(13)), [
            "--output", "%(title).160B (part 1.30-2.45.5).%(ext)s",
            "--no-playlist",
            "--download-sections", "*90-165.5",
            "--downloader-args", "ffmpeg:-progress pipe:1 -nostats",
            "--format", "bv*[vcodec^=avc1]+ba[ext=m4a]/bv*[vcodec^=avc1]+ba/b[ext=mp4]/bv*+ba/b",
            "--merge-output-format", "mp4",
            "--", "https://www.youtube.com/watch?v=a"
        ])
    }

    func testAPartOfTheAudioUsesTheSameSection() {
        let request = DownloadRequest(
            link: "https://x.com/v", kind: .audio, audioFormat: .m4a, isPlaylist: false, allowsAV1: true,
            clip: ClipRange(start: 0, end: 30), videoQuality: .x265
        )
        let result = arguments(request)
        XCTAssertEqual(Array(result.suffix(14)), [
            "--output", "%(title).160B (part 0.00-0.30).%(ext)s",
            "--no-playlist",
            "--download-sections", "*0-30",
            "--downloader-args", "ffmpeg:-progress pipe:1 -nostats",
            "--format", "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b", "--extract-audio", "--audio-format", "m4a",
            "--", "https://x.com/v"
        ])
        // Audio is never compressed as video.
        XCTAssertFalse(request.compresses)
    }

    func testPlaylistsIgnoreAPart() {
        let request = DownloadRequest(
            link: "https://www.youtube.com/playlist?list=PL1", kind: .video, audioFormat: .m4a, isPlaylist: true, allowsAV1: true,
            clip: ClipRange(start: 1, end: 2)
        )
        XCTAssertNil(request.effectiveClip)
        let result = arguments(request)
        XCTAssertFalse(result.contains("--download-sections"))
        XCTAssertTrue(result.contains(DownloadCommand.playlistOutputTemplate))
    }

    func testCompressedVideosDownloadTheBestPictureInAnyFastCodec() {
        let request = DownloadRequest(
            link: "https://www.youtube.com/watch?v=a", kind: .video, audioFormat: .mp3, isPlaylist: false, allowsAV1: true,
            videoQuality: .appleHEVC
        )
        XCTAssertTrue(request.compresses)
        XCTAssertEqual(Array(arguments(request).suffix(9)), [
            "--output", "%(title).180B.%(ext)s",
            "--no-playlist",
            "--format", "bv*[vcodec!^=?av01]+ba[ext=m4a]/bv*[vcodec!^=?av01]+ba/b[vcodec!^=?av01]/bv*+ba/b",
            "--merge-output-format", "mp4",
            "--", "https://www.youtube.com/watch?v=a"
        ])
    }

    func testOriginalQualityKeepsTodaysCommand() {
        let plain = DownloadRequest(link: "https://www.youtube.com/watch?v=a", kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true)
        let explicit = DownloadRequest(
            link: "https://www.youtube.com/watch?v=a", kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true,
            clip: nil, videoQuality: .original
        )
        XCTAssertEqual(arguments(plain), arguments(explicit))
        XCTAssertFalse(plain.compresses)
        XCTAssertFalse(arguments(plain).contains("--download-sections"))
    }

    func testFFmpegTimesBecomePartProgress() {
        XCTAssertEqual(DownloadEventParser.parse("out_time_us=1500000"), .partTime(1.5))
        XCTAssertNil(DownloadEventParser.parse("out_time=00:00:01.500000"))
        XCTAssertNil(DownloadEventParser.parse("progress=continue"))

        var state = DownloadProgressState(partLength: 3)
        state.apply(.item(index: nil, count: nil, title: "Talk"))
        state.apply(.partTime(-1.2))
        XCTAssertEqual(state.phase, .downloading)
        XCTAssertEqual(state.fraction, 0)
        state.apply(.partTime(1.5))
        XCTAssertEqual(state.fraction, 0.5)
        XCTAssertEqual(state.partLength, 3)
        state.apply(.progress(ProgressSample(status: "finished", downloadedBytes: nil, totalBytes: nil, speed: nil, eta: nil, isAudioOnly: false)))
        XCTAssertEqual(state.phase, .finishing)
        // A late ffmpeg line doesn't take the bar backwards.
        state.apply(.partTime(2.9))
        XCTAssertEqual(state.phase, .finishing)
        XCTAssertEqual(state.fraction, 1)

        var unknownLength = DownloadProgressState()
        unknownLength.apply(.partTime(1))
        XCTAssertEqual(unknownLength.phase, .downloading)
        XCTAssertNil(unknownLength.fraction)
    }

    func testRecordsFromEarlierVersionsStillLoad() throws {
        // A record exactly as EchoFetch 0.3.0 saved it.
        let json = """
        [{"byteCount": 1000, "createdAt": 800000000, "fileExtension": "mp4", "id": "6F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F",
          "isFolder": false, "itemCount": 1, "kind": "video", "path": "/Users/me/Downloads/Talk.mp4",
          "sourceURL": "https://youtu.be/a", "title": "Talk", "uploader": "Someone"}]
        """
        let records = try JSONDecoder().decode([DownloadRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].clip)
        XCTAssertNil(records[0].videoQuality)
        XCTAssertNil(records[0].originalByteCount)
        XCTAssertNil(records[0].compression)
    }

    func testNewRecordsKeepThePartAndCompression() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EchoFetchPartRecords-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadHistoryStore(directory: root)
        let record = DownloadRecord(
            title: "Talk", uploader: nil, sourceURL: "https://youtu.be/a", thumbnailURL: nil, kind: .video,
            fileExtension: "mp4", path: "/Users/me/Downloads/Talk (part 1.30-2.45).mp4", isFolder: false,
            itemCount: 1, byteCount: 4_000, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            clip: ClipRange(start: 90, end: 165), videoQuality: VideoQuality.x265.rawValue, originalByteCount: 9_000
        )
        try store.save([record])
        let loaded = store.load()
        XCTAssertEqual(loaded, [record])
        XCTAssertEqual(loaded.first?.compression, .x265)

        var unknown = record
        unknown.videoQuality = "something-newer"
        XCTAssertNil(unknown.compression)
        unknown.videoQuality = "original"
        XCTAssertNil(unknown.compression)
    }
}
