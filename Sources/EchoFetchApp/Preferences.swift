import CoreMedia
import EchoFetchCore
import Foundation
import VideoToolbox

/// Settings stored in UserDefaults. The Settings tab edits the same keys with @AppStorage.
enum Preferences {
    static let saveFolderKey = "EchoFetch.saveFolderPath"
    static let audioFormatKey = "EchoFetch.audioFormat"
    static let fillInCopiedLinksKey = "EchoFetch.fillInCopiedLinks"
    static let lastEngineCheckKey = "EchoFetch.lastEngineCheck"
    static let videoQualityKey = "EchoFetch.videoQuality"

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The chosen folder, or Downloads when none has been chosen.
    static var saveFolder: URL {
        let path = UserDefaults.standard.string(forKey: saveFolderKey) ?? ""
        return path.isEmpty ? defaultSaveFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    static var audioFormat: AudioFormat {
        AudioFormat(rawValue: UserDefaults.standard.string(forKey: audioFormatKey) ?? "") ?? .m4a
    }

    /// Original until a compressed choice is made; the last choice is remembered.
    static var videoQuality: VideoQuality {
        VideoQuality.saved(UserDefaults.standard.string(forKey: videoQualityKey))
    }

    static var fillInCopiedLinks: Bool {
        UserDefaults.standard.object(forKey: fillInCopiedLinksKey) as? Bool ?? true
    }

    static var lastEngineCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastEngineCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastEngineCheckKey) }
    }

    /// "Downloads", or the chosen folder's name.
    static func folderDisplayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }
}

enum VideoSupport {
    /// M3 and later decode AV1 in hardware, so QuickTime plays YouTube's 4K and 8K AV1 video.
    /// Older Macs get H.264, which tops out at 1080p on YouTube.
    static let playsAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}
