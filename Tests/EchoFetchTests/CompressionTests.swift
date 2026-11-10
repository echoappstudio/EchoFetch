import Foundation
import XCTest
@testable import EchoFetchCore

final class CompressionTests: XCTestCase {
    func testVideoQualityChoices() {
        XCTAssertEqual(VideoQuality.allCases, [.original, .appleHEVC, .x265])
        XCTAssertEqual(VideoQuality.allCases.map(\.rawValue), ["original", "apple-hevc", "x265"])
        XCTAssertEqual(VideoQuality.allCases.map(\.title), ["Original", "Smaller (Apple HEVC)", "Smallest (x265)"])
        XCTAssertFalse(VideoQuality.original.isCompressed)
        XCTAssertTrue(VideoQuality.appleHEVC.isCompressed)
        XCTAssertTrue(VideoQuality.x265.isCompressed)
        XCTAssertEqual(VideoQuality.saved(nil), .original)
        XCTAssertEqual(VideoQuality.saved("x265"), .x265)
        XCTAssertEqual(VideoQuality.saved("apple-hevc"), .appleHEVC)
        XCTAssertEqual(VideoQuality.saved("av1-someday"), .original)
    }

    func testReadsAnMP4Probe() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "h264", "codec_tag_string": "avc1", "codec_type": "video", "width": 1920, "height": 1080,
           "avg_frame_rate": "30000/1001", "r_frame_rate": "30000/1001", "bit_rate": "4000000", "disposition": {"attached_pic": 0}},
          {"index": 1, "codec_name": "aac", "codec_type": "audio", "bit_rate": "129000"}],
         "format": {"duration": "12.500000", "bit_rate": "4200000", "size": "6562500"}}
        """
        let source = try VideoProbe.parse(Data(json.utf8))
        XCTAssertEqual(source.width, 1920)
        XCTAssertEqual(source.height, 1080)
        XCTAssertEqual(try XCTUnwrap(source.framesPerSecond), 29.97, accuracy: 0.001)
        XCTAssertEqual(source.duration, 12.5)
        XCTAssertEqual(source.videoBitrate, 4_000_000)
        XCTAssertEqual(source.audioCodec, "aac")
        XCTAssertEqual(source.videoCodec, "h264")
        XCTAssertEqual(source.videoTag, "avc1")
    }

    func testWorksOutTheVideoBitrateWhenTheStreamDoesntSay() throws {
        // A cover picture comes first and is skipped; the format's total minus the sound is used.
        let fromTotal = """
        {"streams": [
          {"codec_name": "mjpeg", "codec_type": "video", "width": 600, "height": 600, "disposition": {"attached_pic": 1}},
          {"codec_name": "vp9", "codec_type": "video", "width": 3840, "height": 2160, "avg_frame_rate": "0/0", "r_frame_rate": "60/1"},
          {"codec_name": "opus", "codec_type": "audio"}],
         "format": {"duration": "10", "bit_rate": "20128000"}}
        """
        let vp9 = try VideoProbe.parse(Data(fromTotal.utf8))
        XCTAssertEqual(vp9.width, 3840)
        XCTAssertEqual(vp9.framesPerSecond, 60)
        XCTAssertEqual(vp9.videoBitrate, 20_000_000)
        XCTAssertEqual(vp9.audioCodec, "opus")
        XCTAssertEqual(vp9.videoCodec, "vp9")

        // No bit rates at all: worked out from the size. No sound.
        let fromSize = #"{"streams": [{"codec_type": "video", "width": 640, "height": 360}], "format": {"duration": "4", "size": "1000000"}}"#
        let silent = try VideoProbe.parse(Data(fromSize.utf8))
        XCTAssertEqual(silent.videoBitrate, 2_000_000)
        XCTAssertNil(silent.audioCodec)
        XCTAssertNil(silent.framesPerSecond)
    }

    func testRejectsAProbeWithoutVideo() {
        XCTAssertThrowsError(try VideoProbe.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try VideoProbe.parse(Data(#"{"streams": [{"codec_type": "audio"}], "format": {}}"#.utf8)))
        XCTAssertThrowsError(try VideoProbe.parse(Data(#"{"streams": [{"codec_type": "video", "width": 0, "height": 0}]}"#.utf8)))
    }

    func testReadsFrameRates() {
        XCTAssertEqual(try XCTUnwrap(VideoProbe.frameRate("30000/1001")), 29.97003, accuracy: 0.00001)
        XCTAssertEqual(VideoProbe.frameRate("25/1"), 25)
        XCTAssertEqual(VideoProbe.frameRate("24"), 24)
        XCTAssertNil(VideoProbe.frameRate("0/0"))
        XCTAssertNil(VideoProbe.frameRate(nil))
        XCTAssertNil(VideoProbe.frameRate("abc"))
    }

    func testAppleBitrateFollowsTheOriginalWithinLimits() {
        func bitrate(_ width: Int, _ height: Int, _ fps: Double?, _ original: Double?) -> Int {
            CompressCommand.appleBitrate(for: SourceVideo(width: width, height: height, framesPerSecond: fps, duration: 10, videoBitrate: original, audioCodec: "aac"))
        }
        // 60% of the original.
        XCTAssertEqual(bitrate(1920, 1080, 30, 4_000_000), 2_400_000)
        XCTAssertEqual(bitrate(3840, 2160, 60, 40_000_000), 24_000_000)
        // Raised to the lower limit, but never above 85% of an already small original.
        XCTAssertEqual(bitrate(1920, 1080, 30, 2_000_000), 1_700_000)
        // Lowered to the upper limit (0.1 bits per pixel per frame).
        XCTAssertEqual(bitrate(1280, 720, 30000.0 / 1001.0, 20_000_000), 2_762_000)
        // Unknown original: 0.06 bits per pixel per frame at 30 frames a second.
        XCTAssertEqual(bitrate(640, 360, nil, nil), 415_000)
        // Never below 100 kbit/s.
        XCTAssertEqual(bitrate(256, 144, 30, 50_000), 100_000)
    }

    func testX265Command() {
        let source = SourceVideo(width: 1920, height: 1080, framesPerSecond: 30, duration: 60, videoBitrate: 4_000_000, audioCodec: "aac")
        XCTAssertEqual(
            CompressCommand.arguments(
                input: URL(fileURLWithPath: "/tmp/job/Downloaded/Talk.mp4"),
                output: URL(fileURLWithPath: "/tmp/job/Compressed/Talk.mp4"),
                quality: .x265,
                source: source
            ),
            [
                "-hide_banner", "-nostdin", "-y", "-nostats", "-loglevel", "error", "-progress", "pipe:1",
                "-i", "/tmp/job/Downloaded/Talk.mp4",
                "-map", "0:v:0", "-map", "0:a:0?",
                "-c:v", "libx265", "-preset", "medium", "-crf", "26", "-x265-params", "log-level=error",
                "-tag:v", "hvc1",
                "-c:a", "copy",
                "-map_metadata", "0", "-movflags", "+faststart", "-f", "mp4", "/tmp/job/Compressed/Talk.mp4"
            ]
        )
    }

    func testAppleCommandConvertsNonAACSound() {
        let source = SourceVideo(width: 1920, height: 1080, framesPerSecond: 30, duration: 60, videoBitrate: 4_000_000, audioCodec: "opus")
        let arguments = CompressCommand.arguments(
            input: URL(fileURLWithPath: "/tmp/in.mp4"),
            output: URL(fileURLWithPath: "/tmp/out.mp4"),
            quality: .appleHEVC,
            source: source
        )
        XCTAssertEqual(Array(arguments[14...]), [
            "-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-b:v", "2400k",
            "-tag:v", "hvc1",
            "-c:a", "aac", "-b:a", "192k",
            "-map_metadata", "0", "-movflags", "+faststart", "-f", "mp4", "/tmp/out.mp4"
        ])
    }

    func testReadsFFmpegProgressLines() {
        XCTAssertEqual(FFmpegProgress.seconds(fromLine: "out_time_us=2743084"), 2.743084)
        XCTAssertEqual(FFmpegProgress.seconds(fromLine: "out_time_us=-1575828"), -1.575828)
        XCTAssertNil(FFmpegProgress.seconds(fromLine: "out_time_us=N/A"))
        XCTAssertNil(FFmpegProgress.seconds(fromLine: "out_time=00:00:02.743084"))
        XCTAssertNil(FFmpegProgress.seconds(fromLine: "progress=end"))
        XCTAssertEqual(try XCTUnwrap(FFmpegProgress.fraction(seconds: 2.743084, of: 2.75)), 0.997485, accuracy: 0.000001)
        XCTAssertEqual(FFmpegProgress.fraction(seconds: -1.5, of: 2.75), 0)
        XCTAssertEqual(FFmpegProgress.fraction(seconds: 9, of: 2.75), 1)
        XCTAssertNil(FFmpegProgress.fraction(seconds: 1, of: nil))
        XCTAssertNil(FFmpegProgress.fraction(seconds: 1, of: 0))
    }

    func testFindsAFreeFileName() {
        let taken: Set<String> = ["/Users/me/Downloads/Talk.mp4", "/Users/me/Downloads/Talk 2.mp4"]
        let exists: (String) -> Bool = { taken.contains($0) }
        XCTAssertEqual(
            FileNames.available(URL(fileURLWithPath: "/Users/me/Downloads/Talk.mp4"), exists: exists).path,
            "/Users/me/Downloads/Talk 3.mp4"
        )
        XCTAssertEqual(
            FileNames.available(URL(fileURLWithPath: "/Users/me/Downloads/Other.mp4"), exists: exists).path,
            "/Users/me/Downloads/Other.mp4"
        )
    }

    func testRelativePathsKeepThePlaylistFolder() {
        let folder = URL(fileURLWithPath: "/tmp/job/Downloaded", isDirectory: true)
        XCTAssertEqual(
            FileNames.relativePath(of: URL(fileURLWithPath: "/tmp/job/Downloaded/Mix/001 - Song.mp4"), inside: folder),
            "Mix/001 - Song.mp4"
        )
        XCTAssertEqual(FileNames.relativePath(of: URL(fileURLWithPath: "/tmp/job/Downloaded/Talk.mp4"), inside: folder), "Talk.mp4")
        XCTAssertEqual(FileNames.relativePath(of: URL(fileURLWithPath: "/elsewhere/Talk.mp4"), inside: folder), "Talk.mp4")
    }
}
