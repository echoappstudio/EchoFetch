import Foundation

/// A part of a video, in seconds from its start.
public struct ClipRange: Codable, Equatable, Sendable {
    /// The shortest part EchoFetch saves.
    public static let minimumLength: Double = 0.5

    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { max(0, end - start) }

    /// True when the part is long enough and, if the video's length is known, inside it.
    public func isValid(videoLength: Double?) -> Bool {
        guard start.isFinite, end.isFinite, start >= 0, length >= Self.minimumLength else { return false }
        if let videoLength, videoLength > 0 {
            return start < videoLength && end <= videoLength + 0.05
        }
        return true
    }

    /// True when the part is the whole video, so downloading it whole gives the same result.
    public func coversWholeVideo(videoLength: Double?) -> Bool {
        guard let videoLength, videoLength > 0 else { return false }
        return start <= 0.05 && end >= videoLength - 0.05
    }

    /// yt-dlp's `--download-sections` value: "*90-165.5".
    public var sectionArgument: String {
        "*\(ClipTime.plainSeconds(start))-\(ClipTime.plainSeconds(end))"
    }

    /// Added to the file name: "part 1.30-2.45".
    public var fileLabel: String {
        "part \(ClipTime.fileText(start))-\(ClipTime.fileText(end))"
    }

    /// "1:30 – 2:45".
    public var displayText: String {
        "\(ClipTime.text(start)) – \(ClipTime.text(end))"
    }
}

/// Reading and writing the times a person types and sees: "1:30", "1:02:03.5", "95".
public enum ClipTime {
    /// Reads "95", "95.5", "1:35", "1:35.5" or "1:02:03.5". Nil for anything else.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                  part.filter({ $0 == "." }).count <= 1,
                  let value = Double(part), value.isFinite else { return nil }
            // Minutes and seconds after a colon stay below 60.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// "0:05", "1:30", "1:30.5", "1:02:03". Tenths only when the time has them.
    public static func text(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        var result = hours > 0 ? "\(hours):\(pad(minutes)):\(pad(secs))" : "\(minutes):\(pad(secs))"
        if fraction > 0 { result += ".\(fraction)" }
        return result
    }

    /// Like `text`, but with dots instead of colons, for file names: "1.30", "1.02.03.5".
    public static func fileText(_ seconds: Double) -> String {
        text(seconds).replacingOccurrences(of: ":", with: ".")
    }

    /// Seconds with at most three decimals and no trailing zeros: "90", "165.5", "0.25".
    public static func plainSeconds(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let whole = millis / 1000
        let rest = millis % 1000
        guard rest > 0 else { return String(whole) }
        var decimals = String(rest)
        while decimals.count < 3 { decimals = "0" + decimals }
        while decimals.hasSuffix("0") { decimals.removeLast() }
        return "\(whole).\(decimals)"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
