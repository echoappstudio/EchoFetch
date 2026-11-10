import Foundation
import XCTest
@testable import EchoFetchCore

/// Real parts and real compression with the bundled yt-dlp, ffmpeg and ffprobe, against the sample
/// video CI serves (4 seconds, 640 × 360, H.264 and AAC). Skipped where those aren't set up.
final class PartPipelineTests: XCTestCase {
    private func setting() throws -> (tools: ToolPaths, media: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["ECHOFETCH_TOOLS_DIRECTORY"], !directory.isEmpty,
              let media = environment["ECHOFETCH_TEST_MEDIA_URL"], !media.isEmpty else {
            throw XCTSkip("Set ECHOFETCH_TOOLS_DIRECTORY and ECHOFETCH_TEST_MEDIA_URL to run the real part and compression tests.")
        }
        return (ToolPaths(directory: URL(fileURLWithPath: directory, isDirectory: true)), media)
    }

    private func makeFolders() throws -> (root: URL, destination: URL, partial: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EchoFetchParts-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Downloads", isDirectory: true)
        let partial = root.appendingPathComponent("Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        return (root, destination, partial)
    }

    /// Runs yt-dlp for `request` and returns the saved file and the events it printed.
    private func download(_ request: DownloadRequest, tools: ToolPaths, into folders: (root: URL, destination: URL, partial: URL)) async throws -> (file: String, events: [DownloadEvent]) {
        let log = DownloadEventLog()
        let events = EventBox()
        let result = try await ToolProcess(
            executableURL: tools.ytDLP,
            arguments: DownloadCommand.downloadArguments(for: request, destination: folders.destination, temporaryDirectory: folders.partial, tools: tools)
        ).run { line in
            guard let event = DownloadEventParser.parse(line) else { return }
            log.record(event)
            events.add(event)
        }
        XCTAssertEqual(result.exitCode, 0, result.standardError.joined(separator: "\n"))
        XCTAssertEqual(log.files.count, 1)
        return (try XCTUnwrap(log.files.first), events.all)
    }

    private func probe(_ path: String, tools: ToolPaths) async throws -> SourceVideo {
        let result = try await ToolProcess(executableURL: tools.ffprobe, arguments: VideoProbe.arguments(input: URL(fileURLWithPath: path)))
            .run(collectOutput: true)
        XCTAssertEqual(result.exitCode, 0, result.standardError.joined(separator: "\n"))
        return try VideoProbe.parse(Data(result.standardOutput.joined(separator: "\n").utf8))
    }

    private func audioDuration(_ path: String, tools: ToolPaths) async throws -> Double {
        let result = try await ToolProcess(
            executableURL: tools.ffprobe,
            arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path]
        ).run(collectOutput: true)
        XCTAssertEqual(result.exitCode, 0, result.standardError.joined(separator: "\n"))
        return try XCTUnwrap(Double(result.standardOutput.joined().trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testPreviewOffersTheSampleToThePlayer() async throws {
        let (tools, media) = try setting()
        let result = try await ToolProcess(
            executableURL: tools.ytDLP,
            arguments: DownloadCommand.previewArguments(link: media, wholePlaylist: false, tools: tools)
        ).run(collectOutput: true)
        XCTAssertEqual(result.exitCode, 0, result.standardError.joined(separator: "\n"))
        guard case .single(let item) = try MediaInfoParser.parse(Data(result.standardOutput.joined(separator: "\n").utf8)) else {
            return XCTFail("expected a single video")
        }
        XCTAssertEqual(item.previewStream?.url.absoluteString, media)
    }

    func testAPartOfTheVideoIsJustThatStretch() async throws {
        let (tools, media) = try setting()
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let clip = ClipRange(start: 1, end: 3.5)
        let request = DownloadRequest(link: media, kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true, clip: clip)
        let (file, events) = try await download(request, tools: tools, into: folders)
        XCTAssertEqual((file as NSString).lastPathComponent, "sample (part 0.01-0.03.5).mp4")
        let video = try await probe(file, tools: tools)
        XCTAssertEqual(video.width, 640)
        XCTAssertEqual(try XCTUnwrap(video.duration), 2.5, accuracy: 0.4)
        XCTAssertTrue(events.contains { if case .partTime = $0 { return true } else { return false } }, "ffmpeg's progress lines should reach EchoFetch")
    }

    func testAPartOfTheAudio() async throws {
        let (tools, media) = try setting()
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let request = DownloadRequest(
            link: media, kind: .audio, audioFormat: .m4a, isPlaylist: false, allowsAV1: true,
            clip: ClipRange(start: 0.5, end: 2.5)
        )
        let (file, _) = try await download(request, tools: tools, into: folders)
        XCTAssertEqual((file as NSString).lastPathComponent, "sample (part 0.00.5-0.02.5).m4a")
        let seconds = try await audioDuration(file, tools: tools)
        XCTAssertEqual(seconds, 2, accuracy: 0.3)
    }

    func testCompressesTheDownloadToHEVCBothWays() async throws {
        let (tools, media) = try setting()
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let request = DownloadRequest(link: media, kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true, videoQuality: .x265)
        let (file, _) = try await download(request, tools: tools, into: folders)
        XCTAssertEqual((file as NSString).pathExtension, "mp4")

        for quality in [VideoQuality.x265, .appleHEVC] {
            let output = folders.root.appendingPathComponent("Compressed-\(quality.rawValue).mp4")
            let progress = FractionBox()
            let result = try await VideoCompressor(tools: tools).compress(
                input: URL(fileURLWithPath: file),
                output: output,
                quality: quality
            ) { progress.add($0) }
            let compressed = try XCTUnwrap(result, quality.rawValue)
            XCTAssertEqual(compressed.output, output)
            XCTAssertGreaterThan(compressed.compressedBytes, 0, quality.rawValue)
            XCTAssertGreaterThan(compressed.originalBytes, 0, quality.rawValue)
            let video = try await probe(output.path, tools: tools)
            XCTAssertEqual(video.videoCodec, "hevc", quality.rawValue)
            XCTAssertEqual(video.videoTag, "hvc1", quality.rawValue)
            XCTAssertEqual(video.audioCodec, "aac", quality.rawValue)
            XCTAssertEqual(video.width, 640, quality.rawValue)
            XCTAssertEqual(try XCTUnwrap(video.duration), 4, accuracy: 0.3, quality.rawValue)
            XCTAssertFalse(progress.all.isEmpty, "\(quality.rawValue): no progress was reported")
            XCTAssertTrue(progress.all.allSatisfy { (0...1).contains($0) }, quality.rawValue)
        }
    }

    func testCompressingAPartKeepsItsLength() async throws {
        let (tools, media) = try setting()
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let request = DownloadRequest(
            link: media, kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true,
            clip: ClipRange(start: 1, end: 3), videoQuality: .x265
        )
        let (file, _) = try await download(request, tools: tools, into: folders)
        let output = folders.root.appendingPathComponent("part.mp4")
        let result = try await VideoCompressor(tools: tools).compress(input: URL(fileURLWithPath: file), output: output, quality: .x265)
        XCTAssertNotNil(result)
        let video = try await probe(output.path, tools: tools)
        XCTAssertEqual(video.videoCodec, "hevc")
        XCTAssertEqual(try XCTUnwrap(video.duration), 2, accuracy: 0.3)
    }

    func testACancelledCompressionLeavesNothing() async throws {
        let (tools, media) = try setting()
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let request = DownloadRequest(link: media, kind: .video, audioFormat: .m4a, isPlaylist: false, allowsAV1: true, videoQuality: .x265)
        let (file, _) = try await download(request, tools: tools, into: folders)
        let output = folders.root.appendingPathComponent("cancelled.mp4")
        let compressor = VideoCompressor(tools: tools)
        compressor.cancel()
        let result = try await compressor.compress(input: URL(fileURLWithPath: file), output: output, quality: .x265)
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}

final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var all: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
