import AVKit
import EchoFetchCore
import SwiftUI
import WebKit

/// The Choose Part window: watch the video, drag the start and end (or type them), and use the part.
struct PartSheet: View {
    let item: MediaItem
    let onChoose: (ClipRange?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: PartPlayer
    @State private var start: Double
    @State private var end: Double
    @State private var startText: String
    @State private var endText: String
    @State private var problem: String?

    init(item: MediaItem, initialClip: ClipRange?, onChoose: @escaping (ClipRange?) -> Void) {
        self.item = item
        self.onChoose = onChoose
        let startValue = initialClip?.start ?? 0
        let endValue = initialClip?.end ?? item.duration ?? 0
        _player = State(initialValue: PartPlayer(item: item))
        _start = State(initialValue: startValue)
        _end = State(initialValue: endValue)
        _startText = State(initialValue: ClipTime.text(startValue))
        _endText = State(initialValue: endValue > 0 ? ClipTime.text(endValue) : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            playerArea
            if let note = player.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let length = player.length, length > 0 {
                PartRangeBar(
                    length: length,
                    start: $start,
                    end: $end,
                    playhead: player.currentTime,
                    onSeek: { player.seek(to: $0) }
                )
            }
            timeRow
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttonRow
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 560, idealHeight: 700)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: start) { _, value in startText = ClipTime.text(value) }
        .onChange(of: end) { _, value in endText = ClipTime.text(value) }
        .onChange(of: player.length) { _, length in
            // The whole video until a part is chosen, once its length is known.
            if let length, length > 0, end <= 0 { end = length }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a Part")
                    .font(.title2.weight(.semibold))
                Text(item.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if player.mode == .stream, player.hasWebsite {
                Button("Use Website Player") { player.switchToWebsite() }
                    .help("Show the site's own player instead, for example if the preview looks wrong.")
            }
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        switch player.mode {
        case .stream:
            VideoPlayer(player: player.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 280)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .website:
            if let webView = player.webView {
                WebPlayerView(webView: webView)
                    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case .unavailable:
            ThumbnailView(url: item.thumbnailURL, width: 320)
                .frame(maxWidth: .infinity)
        }
    }

    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            timeField("Start", text: $startText, apply: { applyStartText() }) {
                Task {
                    let now = await player.freshTime()
                    start = clampedStart(now)
                }
            }
            timeField("End", text: $endText, apply: { applyEndText() }) {
                Task {
                    let now = await player.freshTime()
                    end = clampedEnd(now)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Length \(ClipTime.text(max(0, end - start)))")
                    .monospacedDigit()
                Text("Now \(ClipTime.text(player.currentTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func timeField(_ title: String, text: Binding<String>, apply: @escaping () -> Void, setToCurrent: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(title, text: text, prompt: Text("0:00"))
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 96)
                    .onSubmit(apply)
                Button("Set to Current Time", action: setToCurrent)
                    .disabled(player.mode == .unavailable)
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 10) {
            if player.mode != .unavailable {
                if player.isPlaying {
                    Button("Pause") { player.pause() }
                } else {
                    Button("Play Part") { player.playPart(from: start, to: end) }
                        .disabled(end <= start)
                }
            }
            Spacer()
            Button("Whole Video") {
                onChoose(nil)
                dismiss()
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Use This Part", action: usePart)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    // MARK: Times

    private func clampedStart(_ value: Double) -> Double {
        min(max(0, value), max(0, end - ClipRange.minimumLength))
    }

    private func clampedEnd(_ value: Double) -> Double {
        let upper = player.length ?? .greatestFiniteMagnitude
        return min(max(value, start + ClipRange.minimumLength), upper)
    }

    private func applyStartText() {
        guard let value = ClipTime.parse(startText) else {
            problem = "Type the start as minutes and seconds, like 1:30."
            return
        }
        problem = nil
        start = min(max(0, value), player.length ?? value)
        startText = ClipTime.text(start)
        player.seek(to: start)
    }

    private func applyEndText() {
        guard let value = ClipTime.parse(endText) else {
            problem = "Type the end as minutes and seconds, like 2:45."
            return
        }
        problem = nil
        end = min(max(0, value), player.length ?? value)
        endText = ClipTime.text(end)
        player.seek(to: end)
    }

    private func usePart() {
        guard let typedStart = ClipTime.parse(startText), let typedEnd = ClipTime.parse(endText) else {
            problem = "Type the start and end as minutes and seconds, like 1:30 and 2:45."
            return
        }
        // A time typed without pressing Return still counts.
        let clip = ClipRange(start: typedStart, end: typedEnd)
        let length = player.length
        guard clip.end > clip.start, clip.length >= ClipRange.minimumLength else {
            problem = "The end needs to be at least half a second after the start."
            return
        }
        guard clip.isValid(videoLength: length) else {
            let total = length.map { " (\(ClipTime.text($0)))" } ?? ""
            problem = "The part needs to fit inside the video\(total)."
            return
        }
        onChoose(clip.coversWholeVideo(videoLength: length) ? nil : clip)
        dismiss()
    }
}

/// A timeline with the chosen part highlighted, a handle at each end and the playhead. Click or drag
/// on it to move the playhead.
struct PartRangeBar: View {
    let length: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let onSeek: (Double) -> Void

    private let inset: CGFloat = 8
    private let barY: CGFloat = 18

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(geometry.size.width - inset * 2, 1)
                let startX = x(for: start, width: width)
                let endX = x(for: end, width: width)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: width, height: 8)
                        .position(x: inset + width / 2, y: barY)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: max(endX - startX, 1), height: 8)
                        .position(x: (startX + endX) / 2, y: barY)
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: 28)
                        .position(x: x(for: playhead, width: width), y: barY)
                    handle
                        .position(x: startX, y: barY)
                        .gesture(handleDrag(width: width, isStart: true))
                        .help("Start of the part")
                    handle
                        .position(x: endX, y: barY)
                        .gesture(handleDrag(width: width, isStart: false))
                        .help("End of the part")
                }
                .coordinateSpace(name: "partBar")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("partBar"))
                        .onChanged { value in onSeek(time(at: value.location.x, width: width)) }
                )
            }
            .frame(height: 36)
            HStack {
                Text("0:00")
                Spacer()
                Text(ClipTime.text(length))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, inset)
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.9), lineWidth: 1))
            .frame(width: 10, height: 30)
            .contentShape(Rectangle().inset(by: -6))
    }

    private func handleDrag(width: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("partBar"))
            .onChanged { value in
                let moved = time(at: value.location.x, width: width)
                if isStart {
                    start = min(max(0, moved), max(0, end - ClipRange.minimumLength))
                    onSeek(start)
                } else {
                    end = max(min(length, moved), start + ClipRange.minimumLength)
                    onSeek(end)
                }
            }
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        guard length > 0 else { return inset }
        let fraction = min(max(seconds / length, 0), 1)
        return inset + CGFloat(fraction) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double((x - inset) / width), 0), 1)
        return fraction * length
    }
}

/// Shows the PartPlayer's web view.
struct WebPlayerView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
