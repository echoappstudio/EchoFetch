import Foundation
import XCTest
@testable import EchoFetchCore

final class PreviewStreamTests: XCTestCase {
    private func stream(_ json: String) throws -> PreviewStream? {
        guard case .single(let item) = try MediaInfoParser.parse(Data(json.utf8)) else {
            XCTFail("expected a single video")
            return nil
        }
        return item.previewStream
    }

    func testPicksAPlayableStreamNear720p() throws {
        let json = """
        {"id": "a", "title": "Talk", "http_headers": {"User-Agent": "Shared"}, "formats": [
          {"format_id": "sb0", "url": "https://i.ytimg.com/sb/a/storyboard.jpg", "protocol": "mhtml", "ext": "mhtml", "vcodec": "none", "acodec": "none"},
          {"format_id": "140", "url": "https://rr.example/140", "protocol": "https", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2"},
          {"format_id": "18", "url": "https://rr.example/18", "protocol": "https", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "height": 360},
          {"format_id": "95", "url": "https://hls.example/95/index.m3u8", "protocol": "m3u8_native", "ext": "mp4", "vcodec": "avc1.4D401F", "acodec": "mp4a.40.2", "height": 720,
           "http_headers": {"User-Agent": "Format", "Referer": "https://www.youtube.com/"}},
          {"format_id": "96", "url": "https://hls.example/96/index.m3u8", "protocol": "m3u8_native", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "height": 1080},
          {"format_id": "313", "url": "https://rr.example/313", "protocol": "https", "ext": "webm", "vcodec": "vp9", "acodec": "none", "height": 2160},
          {"format_id": "401", "url": "https://hls.example/401/index.m3u8", "protocol": "m3u8_native", "ext": "mp4", "vcodec": "av01.0.12M.08", "acodec": "mp4a.40.2", "height": 720}
        ]}
        """
        XCTAssertEqual(try stream(json), PreviewStream(
            url: try XCTUnwrap(URL(string: "https://hls.example/95/index.m3u8")),
            headers: ["User-Agent": "Format", "Referer": "https://www.youtube.com/"],
            height: 720,
            isHLS: true
        ))
    }

    func testPrefersHLSAtTheSameHeightAndSmallerOverLarger() throws {
        let sameHeight = """
        {"id": "a", "title": "T", "formats": [
          {"url": "https://a/hls.m3u8", "protocol": "m3u8", "vcodec": "avc1", "acodec": "mp4a", "height": 480},
          {"url": "https://a/file.mp4", "protocol": "https", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 480}
        ]}
        """
        XCTAssertEqual(try stream(sameHeight)?.isHLS, true)

        let aboveOnly = """
        {"id": "a", "title": "T", "formats": [
          {"url": "https://a/2160.mp4", "protocol": "https", "ext": "mp4", "vcodec": "hvc1.2.4.L153", "acodec": "mp4a", "height": 2160},
          {"url": "https://a/1080.mp4", "protocol": "https", "ext": "mp4", "vcodec": "hev1.1.6.L120", "acodec": "mp4a", "height": 1080}
        ]}
        """
        XCTAssertEqual(try stream(aboveOnly)?.height, 1080)
    }

    func testUsesADirectMP4WhenCodecsAreUnknown() throws {
        let direct = """
        {"id": "sample", "title": "sample", "url": "http://127.0.0.1:8765/sample.mp4", "ext": "mp4", "protocol": "http",
         "http_headers": {"User-Agent": "Shared"},
         "formats": [{"format_id": "mp4", "url": "http://127.0.0.1:8765/sample.mp4", "protocol": "http", "ext": "mp4"}]}
        """
        XCTAssertEqual(try stream(direct), PreviewStream(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/sample.mp4")),
            headers: ["User-Agent": "Shared"],
            height: nil,
            isHLS: false
        ))

        // With no format list at all, the video's own URL is used.
        let bare = #"{"id": "b", "title": "B", "url": "https://cdn.example/b.mov", "ext": "mov"}"#
        XCTAssertEqual(try stream(bare)?.url.absoluteString, "https://cdn.example/b.mov")
    }

    func testOffersNothingThePlayerCantShow() throws {
        let unplayable = """
        {"id": "a", "title": "T", "url": "https://www.example.com/watch/a", "formats": [
          {"url": "https://a/vp9.webm", "protocol": "https", "ext": "webm", "vcodec": "vp9", "acodec": "opus", "height": 720},
          {"url": "https://a/video-only.mp4", "protocol": "https", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 720},
          {"url": "https://a/dash.mpd", "protocol": "http_dash_segments", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 720},
          {"url": "https://a/drm.m3u8", "protocol": "m3u8_native", "vcodec": "avc1", "acodec": "mp4a", "height": 720, "has_drm": true},
          {"url": "rtmp://a/live", "protocol": "rtmp", "vcodec": "avc1", "acodec": "mp4a", "height": 720},
          {"url": "https://a/opus.mp4", "protocol": "https", "ext": "mp4", "vcodec": "avc1", "acodec": "opus", "height": 720},
          {"url": "https://a/unknown.webm", "protocol": "https", "ext": "webm"}
        ]}
        """
        XCTAssertNil(try stream(unplayable))
        XCTAssertNil(try stream(#"{"id": "a", "title": "No formats"}"#))
    }

    func testPlaylistEntriesHaveNoPreview() throws {
        let json = """
        {"_type": "playlist", "id": "PL1", "title": "Mix", "entries": [
          {"_type": "url", "id": "a1", "title": "Song", "url": "https://www.youtube.com/watch?v=a1"}
        ]}
        """
        guard case .playlist(let playlist) = try MediaInfoParser.parse(Data(json.utf8)) else { return XCTFail("expected a playlist") }
        XCTAssertNil(playlist.entries[0].previewStream)
    }
}
