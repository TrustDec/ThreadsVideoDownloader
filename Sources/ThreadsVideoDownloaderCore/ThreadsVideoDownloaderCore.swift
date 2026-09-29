import Foundation

public enum SocialPlatform: String {
    case threads
    case douyin
    case x
    case youtube

    public var displayName: String {
        switch self {
        case .threads: return "Threads"
        case .douyin: return "抖音"
        case .x: return "X"
        case .youtube: return "YouTube"
        }
    }
}

public enum SocialInput {
    private static let hostsByPlatform: [SocialPlatform: Set<String>] = [
        .threads: ["threads.com", "www.threads.com", "threads.net", "www.threads.net"],
        .douyin: ["douyin.com", "www.douyin.com", "v.douyin.com"],
        .x: ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"],
        .youtube: [
            "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
            "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"
        ]
    ]

    public static func platform(for url: URL) -> SocialPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        return hostsByPlatform.first { $0.value.contains(host) }?.key
    }

    public static func xStatusID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("status") == .orderedSame }),
              index + 1 < parts.count else {
            return nil
        }
        let identifier = parts[index + 1]
        guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else {
            return nil
        }
        return identifier
    }

    public static func youtubeVideoID(from url: URL) -> String? {
        guard platform(for: url) == .youtube else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" || host == "www.youtu.be" {
            guard let candidate = url.path.split(separator: "/").first else { return nil }
            let identifier = String(candidate)
            return isYouTubeVideoID(identifier) ? identifier : nil
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "v" })?.value,
           isYouTubeVideoID(value) {
            return value
        }
        let parts = url.path.split(separator: "/").map(String.init)
        let markers: Set<String> = ["shorts", "embed", "live", "v"]
        guard let index = parts.firstIndex(where: { markers.contains($0) }),
              index + 1 < parts.count else {
            return nil
        }
        let identifier = parts[index + 1]
        return isYouTubeVideoID(identifier) ? identifier : nil
    }

    public static func validatedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let platform = platform(for: url),
              !url.path.isEmpty else {
            return nil
        }
        if platform == .x {
            return xStatusID(from: url) == nil ? nil : url
        }
        if platform == .youtube {
            return youtubeVideoID(from: url) == nil ? nil : url
        }
        return url
    }

    private static func isYouTubeVideoID(_ value: String) -> Bool {
        guard value.count == 11 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public struct MediaVariant: Equatable {
    public let url: URL
    public let width: Int?
    public let height: Int?
    public let bitrate: Int?
    public let videoIndex: Int
    public let formatSelector: String?
    public let fileSize: Int?

    public init(
        url: URL,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int? = nil,
        videoIndex: Int = 0,
        formatSelector: String? = nil,
        fileSize: Int? = nil
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.videoIndex = videoIndex
        self.formatSelector = formatSelector
        self.fileSize = fileSize
    }

    public var pixelCount: Int {
        (width ?? 0) * (height ?? 0)
    }

    public var resolutionToken: String? {
        guard let width, let height else { return nil }
        return "\(width)x\(height)"
    }
}

public struct MediaQualityOption: Equatable {
    public let width: Int?
    public let height: Int?
    public let bitrate: Int?
    public let fileSize: Int?

    public init(width: Int?, height: Int?, bitrate: Int?, fileSize: Int? = nil) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.fileSize = fileSize
    }

    public var key: String {
        if let width, let height {
            return "\(width)x\(height)"
        }
        return "unknown"
    }

    public var pixelCount: Int {
        (width ?? 0) * (height ?? 0)
    }

    public var displayLabel: String {
        MediaQuality.optionLabel(self)
    }
}

public enum MediaQuality {
    public static func resolution(from url: URL) -> (width: Int, height: Int)? {
        let pattern = #"(\d{2,5})[xX](\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = url.absoluteString
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches.reversed() {
            guard let widthRange = Range(match.range(at: 1), in: text),
                  let heightRange = Range(match.range(at: 2), in: text),
                  let width = Int(text[widthRange]),
                  let height = Int(text[heightRange]),
                  width >= 16, height >= 16, width <= 7680, height <= 4320 else {
                continue
            }
            return (width, height)
        }
        return nil
    }

    public static func variant(
        url: URL,
        bitrate: Int? = nil,
        videoIndex: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        formatSelector: String? = nil,
        fileSize: Int? = nil
    ) -> MediaVariant {
        let parsed = resolution(from: url)
        return MediaVariant(
            url: url,
            width: width ?? parsed?.width,
            height: height ?? parsed?.height,
            bitrate: bitrate,
            videoIndex: videoIndex,
            formatSelector: formatSelector,
            fileSize: fileSize
        )
    }

    public static func uniqueOptions(from variants: [MediaVariant]) -> [MediaQualityOption] {
        var best: [String: MediaQualityOption] = [:]
        for variant in variants {
            let option = MediaQualityOption(
                width: variant.width,
                height: variant.height,
                bitrate: variant.bitrate,
                fileSize: variant.fileSize
            )
            if let existing = best[option.key] {
                let existingBitrate = existing.bitrate ?? 0
                let nextBitrate = option.bitrate ?? 0
                if nextBitrate > existingBitrate {
                    best[option.key] = option
                }
            } else {
                best[option.key] = option
            }
        }
        return best.values.sorted { lhs, rhs in
            if lhs.pixelCount != rhs.pixelCount {
                return lhs.pixelCount > rhs.pixelCount
            }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }
    }

    public static func matchedVariants(from variants: [MediaVariant], option: MediaQualityOption) -> [MediaVariant] {
        let groups = Dictionary(grouping: variants, by: \.videoIndex)
        return groups.keys.sorted().compactMap { index in
            let group = groups[index] ?? []
            if let exact = group.first(where: { qualityKey(for: $0) == option.key }) {
                return exact
            }
            guard option.pixelCount > 0 else {
                return group.max { $0.pixelCount < $1.pixelCount }
            }
            return group.min { lhs, rhs in
                abs(lhs.pixelCount - option.pixelCount) < abs(rhs.pixelCount - option.pixelCount)
            }
        }
    }

    public static func optionLabel(_ option: MediaQualityOption) -> String {
        var parts: [String] = []
        if let width = option.width, let height = option.height {
            parts.append("\(width)×\(height)")
        } else {
            parts.append("未知分辨率")
        }
        if let fileSize = option.fileSize, fileSize > 0 {
            parts.append(byteLabel(fileSize))
        }
        if let bitrate = option.bitrate, bitrate > 0 {
            parts.append(bitrateLabel(bitrate))
        }
        return parts.joined(separator: " · ")
    }

    public static func byteLabel(_ bytes: Int) -> String {
        byteLabel(Double(bytes))
    }

    public static func byteLabel(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        }
        if bytes >= 1_048_576 {
            let mb = bytes / 1_048_576
            return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", bytes / 1024)
        }
        return String(format: "%.0f B", bytes)
    }

    public static func bitrateLabel(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            let mbps = Double(bitrate) / 1_000_000
            return String(format: mbps >= 10 ? "%.0f Mbps" : "%.1f Mbps", mbps)
        }
        if bitrate >= 1000 {
            return "\(bitrate / 1000) Kbps"
        }
        return "\(bitrate) bps"
    }

    private static func qualityKey(for variant: MediaVariant) -> String {
        variant.resolutionToken ?? "unknown"
    }
}

public enum DownloadFileNaming {
    public static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "video" : String(result.prefix(80))
    }

    public static func baseName(platform: SocialPlatform, term: String?, index: Int, resolution: String? = nil) -> String {
        let identifier = safeComponent(term ?? "download")
        let quality = resolution.flatMap { token -> String? in
            let cleaned = safeComponent(token)
            return cleaned.isEmpty ? nil : cleaned
        }
        var stem = "\(platform.rawValue)_\(identifier)"
        if let quality {
            stem += "_\(quality)"
        }
        return index == 0 ? "\(stem).mp4" : "\(stem)_\(index + 1).mp4"
    }
}
