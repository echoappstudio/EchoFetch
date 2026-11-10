import AppKit
import EchoFetchCore
import SwiftUI

struct SettingsView: View {
    @Environment(EchoFetchRuntime.self) private var runtime
    @AppStorage(Preferences.saveFolderKey) private var saveFolderPath = ""
    @AppStorage(Preferences.audioFormatKey) private var audioFormat = AudioFormat.m4a.rawValue
    @AppStorage(Preferences.fillInCopiedLinksKey) private var fillInCopiedLinks = true
    @AppStorage(Preferences.videoQualityKey) private var videoQuality = VideoQuality.original.rawValue

    private var tools: ToolsController { runtime.tools }
    private var updates: UpdateController { runtime.updates }

    private var saveFolder: URL {
        saveFolderPath.isEmpty ? Preferences.defaultSaveFolder : URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.largeTitle.weight(.semibold))
                    Text("Choose where downloads go and keep EchoFetch and its download engine current.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                saveFolderSettings
                formatSettings
                linkSettings
                engineSettings
                updateSettings

                Label("EchoFetch has no accounts or tracking. It only connects to the sites you download from, and to GitHub to update its download engine and to check for new versions of EchoFetch.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 580)
    }

    // MARK: Save folder

    private var saveFolderSettings: some View {
        GroupBox("Save folder") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(saveFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([saveFolder])
                    }
                    Button("Choose…", action: chooseFolder)
                }
                Text("Videos and audio are saved here. Each playlist gets its own folder inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !saveFolderPath.isEmpty {
                    Button("Use the Downloads Folder") { saveFolderPath = "" }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where EchoFetch saves downloads."
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path == Preferences.defaultSaveFolder.path ? "" : url.path
        }
    }

    // MARK: Formats

    private var formatSettings: some View {
        GroupBox("Formats") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Audio format", selection: $audioFormat) {
                    Text("M4A (original quality, recommended)").tag(AudioFormat.m4a.rawValue)
                    Text("MP3 (plays everywhere)").tag(AudioFormat.mp3.rawValue)
                }
                .fixedSize()
                Text("M4A keeps YouTube's own audio exactly as it is, with nothing re-encoded. MP3 is converted at high quality for older players and car stereos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("Video quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                .fixedSize()
                Label(videoNote, systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Smaller and Smallest download the best quality, then compress it to HEVC, which QuickTime plays. Apple HEVC uses your Mac's video encoder and is fast. x265 makes the smallest files at good quality but takes longer. Only the compressed copy is kept. The Download tab has the same choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var videoNote: String {
        VideoSupport.playsAV1
            ? "Original video is saved as MP4 in the best quality QuickTime plays on this Mac, up to 4K and 8K (AV1 or H.264)."
            : "Original video is saved as MP4 in the best quality QuickTime plays on this Mac (H.264, up to 1080p on YouTube)."
    }

    // MARK: Links

    private var linkSettings: some View {
        GroupBox("Links") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Fill in copied links automatically", isOn: $fillInCopiedLinks)
                Text("When you switch to EchoFetch with a link on the clipboard, it's put in the link box and looked up. A link you typed yourself is never replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Engine

    private var engineSettings: some View {
        GroupBox("Download engine") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engineTitle)
                            .font(.headline)
                        Text(lastCheckText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") {
                        Task { await tools.checkForEngineUpdate() }
                    }
                    .disabled(tools.setupState != .ready || tools.engineCheck == .checking || runtime.downloads.isDownloading)
                }

                engineStatus

                Text("EchoFetch looks for a new engine once a day when it opens, and installs it on its own. YouTube changes often, so if downloads start failing, check here first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(includedTools)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let message) = tools.setupState {
                    HStack(alignment: .firstTextBaseline) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") {
                            Task { await tools.prepare() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Updates

    private var updateSettings: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }
                ))
                Text("EchoFetch looks for a new version when it starts and then every hour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updates.automaticallyInstalls },
                    set: { updates.setAutomaticallyInstalls($0) }
                ))
                .disabled(!updates.automaticallyChecks)
                Text("EchoFetch installs a new version and reopens by itself, once nothing is downloading. Your save folder, history and settings stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text(lastUpdateCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var lastUpdateCheckText: String {
        guard let date = updates.lastCheckDate else { return "Not checked for updates yet." }
        return "Last checked for updates \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch tools.engineCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for a newer engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("The engine is up to date.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .updated(let version):
            Label {
                Text("Updated to yt-dlp \(version).")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineTitle: String {
        "yt-dlp \(tools.engineVersion ?? "—")"
    }

    private var includedTools: String {
        let ffmpeg = tools.version(of: "ffmpeg") ?? "—"
        let deno = tools.version(of: "deno") ?? "—"
        return "Also included: ffmpeg \(ffmpeg) for joining video and audio, saving parts, compressing to HEVC and converting to MP3, and Deno \(deno), which YouTube needs."
    }

    private var lastCheckText: String {
        guard let lastCheck = tools.lastEngineCheck else { return "Not checked for updates yet" }
        let calendar = Calendar.current
        let time = lastCheck.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(lastCheck) { return "Last checked today at \(time)" }
        if calendar.isDateInYesterday(lastCheck) { return "Last checked yesterday at \(time)" }
        return "Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))"
    }
}
