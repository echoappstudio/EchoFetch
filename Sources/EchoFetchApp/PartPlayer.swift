import AVFoundation
import EchoFetchCore
import Foundation
import Observation
import WebKit

/// The player in the Choose Part window. It plays the video's preview stream when the site offers
/// one EchoFetch can play, and otherwise the site's own page with its own player, whose time is read
/// from the page's video element.
@MainActor
@Observable
final class PartPlayer {
    enum Mode: Equatable {
        case stream
        case website
        /// Nothing to show: times can still be typed.
        case unavailable
    }

    private(set) var mode: Mode = .unavailable
    /// The playhead, in seconds.
    private(set) var currentTime: Double = 0
    /// The video's length, from the site or, once known, from the player.
    private(set) var length: Double?
    private(set) var isPlaying = false
    /// Why the website player is showing, or that its time can't be read.
    private(set) var note: String?

    let player = AVPlayer()
    private(set) var webView: WKWebView?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var stopAt: Double?
    @ObservationIgnored private var streamStarted = Date()
    @ObservationIgnored private var webMisses = 0
    @ObservationIgnored private var webCallRunning = false

    private let stream: PreviewStream?
    private let pageURL: URL?

    /// How long the preview stream may take to start before the website player takes over.
    private static let streamTimeout: TimeInterval = 20

    init(item: MediaItem) {
        stream = item.previewStream
        pageURL = item.webpageURL
        length = item.duration
    }

    var hasWebsite: Bool { pageURL != nil }

    func start() {
        if let stream {
            showStream(stream)
        } else if pageURL != nil {
            showWebsite(note: "This site doesn't offer a preview EchoFetch can play, so this is the site's own player. Play to where you want the part to start or end, then use Set to Current Time.")
        } else {
            mode = .unavailable
            note = "EchoFetch can't show this video. Type the start and end instead."
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.tick()
                let interval = model.mode == .website ? 250 : 100
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
    }

    /// Switches to the site's own player (the Use Website Player button, or a stream that won't play).
    func switchToWebsite() {
        showWebsite(note: "This is the site's own player. Play to where you want the part to start or end, then use Set to Current Time.")
    }

    /// Jumps to `seconds` (dragging a handle or the playhead).
    func seek(to seconds: Double) {
        let target = max(0, seconds)
        stopAt = nil
        currentTime = target
        switch mode {
        case .stream:
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case .website:
            Task { await callPage(seekTo: target, command: nil) }
        case .unavailable:
            break
        }
    }

    /// Plays from `start` and pauses at `end`.
    func playPart(from start: Double, to end: Double) {
        let from = max(0, start)
        currentTime = from
        stopAt = end
        switch mode {
        case .stream:
            player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        case .website:
            Task { await callPage(seekTo: from, command: "play") }
        case .unavailable:
            break
        }
    }

    func pause() {
        stopAt = nil
        switch mode {
        case .stream:
            player.pause()
        case .website:
            Task { await callPage(seekTo: nil, command: "pause") }
        case .unavailable:
            break
        }
    }

    /// The playhead right now (the website player is asked again, so the time isn't a moment old).
    func freshTime() async -> Double {
        if mode == .website {
            await callPage(seekTo: nil, command: nil)
        }
        return currentTime
    }

    // MARK: Stream

    private func showStream(_ stream: PreviewStream) {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        streamStarted = Date()
        mode = .stream
        note = nil
    }

    private func tickStream() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            showWebsiteAfterStreamProblem()
            return
        case .unknown:
            if Date().timeIntervalSince(streamStarted) > Self.streamTimeout {
                showWebsiteAfterStreamProblem()
            }
            return
        case .readyToPlay:
            break
        @unknown default:
            break
        }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { length = duration }
        let now = player.currentTime().seconds
        if now.isFinite { currentTime = max(0, now) }
        isPlaying = player.rate != 0
        if let stopAt, isPlaying, currentTime >= stopAt {
            player.pause()
            self.stopAt = nil
            isPlaying = false
        }
    }

    private func showWebsiteAfterStreamProblem() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if pageURL != nil {
            showWebsite(note: "The preview didn't play, so this is the site's own player. Play to where you want the part to start or end, then use Set to Current Time.")
        } else {
            mode = .unavailable
            note = "The preview didn't play. Type the start and end instead."
        }
    }

    // MARK: Website

    private func showWebsite(note: String) {
        guard let pageURL else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            // Sites treat a plain web view as an old browser; this makes it read like Safari.
            configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.load(URLRequest(url: pageURL))
            webView = view
        }
        webMisses = 0
        mode = .website
        self.note = note
    }

    private func tickWebsite() async {
        await callPage(seekTo: nil, command: nil)
        if let stopAt, isPlaying, currentTime >= stopAt {
            self.stopAt = nil
            await callPage(seekTo: nil, command: "pause")
        }
    }

    /// Reads (and optionally moves, plays or pauses) the biggest video on the page.
    private func callPage(seekTo: Double?, command: String?) async {
        guard let webView, !webCallRunning || seekTo != nil || command != nil else { return }
        webCallRunning = true
        defer { webCallRunning = false }
        let arguments: [String: Any] = [
            "seekTo": seekTo.map { NSNumber(value: $0) } ?? NSNull(),
            "command": command ?? ""
        ]
        let value = try? await webView.callAsyncJavaScript(
            Self.pageScript,
            arguments: arguments,
            in: nil,
            contentWorld: .defaultClient
        )
        guard let numbers = value as? [NSNumber], numbers.count == 3 else {
            webMisses += 1
            if webMisses == 40 {
                note = "EchoFetch can't read this player's time. Type the start and end instead."
            }
            return
        }
        if webMisses >= 40 {
            note = "This is the site's own player. Play to where you want the part to start or end, then use Set to Current Time."
        }
        webMisses = 0
        let time = numbers[0].doubleValue
        let duration = numbers[1].doubleValue
        if time.isFinite { currentTime = max(0, time) }
        if duration.isFinite, duration > 0 { length = duration }
        isPlaying = numbers[2].intValue == 0
    }

    /// Finds the biggest video element. Returns [time, duration or -1, paused 1/0], or null.
    private static let pageScript = """
        const videos = Array.from(document.querySelectorAll('video'));
        if (videos.length === 0) { return null; }
        videos.sort((a, b) => (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight));
        const video = videos[0];
        if (seekTo !== null) { video.currentTime = seekTo; }
        if (command === 'play') { video.play(); }
        if (command === 'pause') { video.pause(); }
        return [video.currentTime, isFinite(video.duration) ? video.duration : -1, video.paused ? 1 : 0];
        """

    // MARK: Polling

    private func tick() async {
        switch mode {
        case .stream:
            tickStream()
        case .website:
            await tickWebsite()
        case .unavailable:
            break
        }
    }
}
