import AppKit
import EchoFetchCore
import SwiftUI

struct HistoryView: View {
    @Environment(EchoFetchRuntime.self) private var runtime
    @State private var showingClearConfirmation = false

    private var history: HistoryController { runtime.history }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History")
                        .font(.largeTitle.weight(.semibold))
                    Text("Everything you've downloaded with EchoFetch.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if history.records.isEmpty {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: Text("Videos and audio you download appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    GroupBox("Downloads") {
                        VStack(spacing: 0) {
                            ForEach(history.records) { record in
                                HistoryRow(record: record) {
                                    history.remove(record)
                                }
                                if record.id != history.records.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    HStack {
                        Button("Clear History…", role: .destructive) {
                            showingClearConfirmation = true
                        }
                        Spacer()
                        Text(history.records.count == 1 ? "1 download" : "\(history.records.count) downloads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = history.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Label("Removing something from History doesn't delete the file.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Clear your download history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This empties the list in EchoFetch. The downloaded files stay where they are.")
        }
        .frame(minWidth: 760, minHeight: 580)
    }
}

private struct HistoryRow: View {
    let record: DownloadRecord
    let onRemove: () -> Void

    private var url: URL {
        URL(fileURLWithPath: record.path, isDirectory: record.isFolder)
    }

    private var exists: Bool {
        FileManager.default.fileExists(atPath: record.path)
    }

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: record.thumbnailURL.flatMap(URL.init(string:)), width: 96)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !exists {
                    Text(record.isFolder ? "Folder moved or deleted" : "File moved or deleted")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!exists)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from History (the file is kept)")
        }
        .padding(.vertical, 7)
    }

    private var detailLine: String {
        var parts: [String] = []
        if record.isFolder {
            parts.append("Playlist")
            parts.append(record.itemCount == 1 ? "1 file" : "\(record.itemCount) files")
        }
        parts.append(record.kind == .video ? "Video" : "Audio")
        if let clip = record.clip { parts.append("Part \(clip.displayText)") }
        parts.append(record.fileExtension.uppercased())
        if let quality = record.compression { parts.append(quality == .x265 ? "x265" : "Apple HEVC") }
        parts.append(DisplayFormat.bytes(record.byteCount))
        parts.append(record.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
