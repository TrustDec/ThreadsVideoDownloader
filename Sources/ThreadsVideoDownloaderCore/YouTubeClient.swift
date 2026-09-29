import Foundation

public struct SubtitleTrack: Equatable {
    public let language: String
    public let title: String
    public let automatic: Bool

    public init(language: String, title: String, automatic: Bool) {
        self.language = language
        self.title = title
        self.automatic = automatic
    }
}

public struct DownloadProgress: Equatable {
    public var fraction: Double
    public var detail: String

    public init(fraction: Double, detail: String = "") {
        self.fraction = fraction
        self.detail = detail
    }
}

public struct YouTubeDownloadResult: Equatable {
    public let video: URL
    public let subtitles: [URL]

    public init(video: URL, subtitles: [URL]) {
        self.video = video
        self.subtitles = subtitles
    }
}

public struct YouTubeResolved: Equatable {
    public let term: String
    public let variants: [MediaVariant]
    public let subtitles: [SubtitleTrack]

    public init(term: String, variants: [MediaVariant], subtitles: [SubtitleTrack] = []) {
        self.term = term
        self.variants = variants
        self.subtitles = subtitles
    }
}

public enum YouTubeClientError: LocalizedError, Equatable {
    case missingExecutable
    case missingFFmpeg
    case needsLogin
    case noVideo
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "未找到 yt-dlp。请先安装：brew install yt-dlp ffmpeg"
        case .missingFFmpeg:
            return "这个清晰度需要 ffmpeg 合并音视频。请先安装：brew install ffmpeg"
        case .needsLogin:
            return "YouTube 要求确认登录。请先在 Safari 或 Chrome 打开并登录 YouTube，然后重试。"
        case .noVideo:
            return "这条 YouTube 视频没有可下载的公开画质。"
        case let .failed(message):
            return message.isEmpty ? "YouTube 下载失败。" : message
        }
    }
}

public enum YouTubeClient {
    private static let browserKey = "youtubeCookieBrowser"
    private static var sessionBrowser: String?
    private static let browsers = ["safari", "chrome", "firefox", "edge", "brave"]

    private static let processLock = NSLock()
    private static var runningProcess: Process?

    public static func cancel() {
        processLock.lock()
        runningProcess?.terminate()
        processLock.unlock()
    }

    public static func resolve(pageURL: URL) -> Result<YouTubeResolved, Error> {
        guard let executable = locateExecutable(named: "yt-dlp") else {
            return .failure(YouTubeClientError.missingExecutable)
        }

        var lastOutput = ""
        var sawPlayableCatalog = false
        for browser in attemptOrder() {
            let outcome = run(
                executable: executable,
                arguments: dumpArguments(pageURL: pageURL, browser: browser),
                onProgress: nil
            )
            lastOutput = outcome.stderrText
            guard outcome.status == 0 else { continue }
            do {
                let resolved = try parse(data: outcome.stdout, pageURL: pageURL)
                guard !resolved.variants.isEmpty else {
                    sawPlayableCatalog = true
                    continue
                }
                remember(browser)
                return .success(resolved)
            } catch YouTubeClientError.noVideo {
                sawPlayableCatalog = true
            } catch {
                continue
            }
        }

        if lastOutput.contains("Sign in to confirm") || lastOutput.contains("not a bot") {
            return .failure(YouTubeClientError.needsLogin)
        }
        if sawPlayableCatalog {
            return .failure(YouTubeClientError.noVideo)
        }
        return .failure(YouTubeClientError.failed(friendlyMessage(from: lastOutput)))
    }

    public static func download(
        pageURL: URL,
        formatSelector: String,
        destination: URL,
        subtitleLanguage: String? = nil,
        onProgress: @escaping (DownloadProgress) -> Void
    ) -> Result<YouTubeDownloadResult, Error> {
        guard let executable = locateExecutable(named: "yt-dlp") else {
            return .failure(YouTubeClientError.missingExecutable)
        }
        if formatSelector.contains("+"), locateExecutable(named: "ffmpeg") == nil {
            return .failure(YouTubeClientError.missingFFmpeg)
        }

        let outcome = run(
            executable: executable,
            arguments: downloadArguments(
                pageURL: pageURL,
                formatSelector: formatSelector,
                destination: destination,
                browser: rememberedBrowser(),
                subtitleLanguage: subtitleLanguage
            ),
            onProgress: onProgress
        )
        let fileManager = FileManager.default
        let succeeded = outcome.status == 0 && fileSize(at: destination) > 0
        guard succeeded else {
            try? fileManager.removeItem(at: destination)
            for suffix in [".part", ".ytdl"] {
                try? fileManager.removeItem(atPath: destination.path + suffix)
            }
            let output = outcome.stderrText
            if output.contains("Sign in to confirm") || output.contains("not a bot") {
                return .failure(YouTubeClientError.needsLogin)
            }
            if output.contains("ffmpeg") && (output.contains("not found") || output.contains("not installed")) {
                return .failure(YouTubeClientError.missingFFmpeg)
            }
            return .failure(YouTubeClientError.failed(friendlyMessage(from: output)))
        }
        onProgress(DownloadProgress(fraction: 1))
        let sidecars = subtitleLanguage.map { subtitleFiles(beside: destination, language: $0) } ?? []
        return .success(YouTubeDownloadResult(video: destination, subtitles: sidecars))
    }

    public static func parse(data: Data, pageURL: URL) throws -> YouTubeResolved {
        let dump: Dump
        do {
            dump = try JSONDecoder().decode(Dump.self, from: data)
        } catch {
            throw YouTubeClientError.failed("无法读取 yt-dlp 返回的视频信息。")
        }

        let candidates = (dump.formats ?? []).compactMap(Candidate.init(format:))
        let grouped = Dictionary(grouping: candidates, by: { "\($0.width)x\($0.height)" })
        let picked = grouped.values.compactMap { group in
            group.max { $0.rank < $1.rank }
        }
        let variants = picked
            .sorted { lhs, rhs in
                if lhs.width * lhs.height != rhs.width * rhs.height {
                    return lhs.width * lhs.height > rhs.width * rhs.height
                }
                return lhs.tbr > rhs.tbr
            }
            .map { candidate in
                MediaQuality.variant(
                    url: pageURL,
                    bitrate: candidate.tbr > 0 ? Int((candidate.tbr * 1000).rounded()) : nil,
                    width: candidate.width,
                    height: candidate.height,
                    formatSelector: candidate.formatSelector,
                    fileSize: candidate.fileSize
                )
            }
        guard !variants.isEmpty else {
            throw YouTubeClientError.noVideo
        }
        let term = dump.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? SocialInput.youtubeVideoID(from: pageURL)
            ?? "video"
        return YouTubeResolved(term: term, variants: variants, subtitles: subtitleTracks(from: dump))
    }

    private static func dumpArguments(pageURL: URL, browser: String?) -> [String] {
        var arguments = ["-J", "--no-warnings", "--no-playlist", "--no-progress"]
        if let browser {
            arguments += ["--cookies-from-browser", browser]
        }
        arguments.append(pageURL.absoluteString)
        return arguments
    }

    private static func downloadArguments(
        pageURL: URL,
        formatSelector: String,
        destination: URL,
        browser: String?,
        subtitleLanguage: String?
    ) -> [String] {
        var arguments = [
            "--no-warnings",
            "--no-playlist",
            "--newline",
            "--progress",
            "--merge-output-format", "mp4",
            "-f", formatSelector,
            "-o", destination.path
        ]
        if let subtitleLanguage, !subtitleLanguage.isEmpty {
            arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", subtitleLanguage]
            if locateExecutable(named: "ffmpeg") != nil {
                arguments += ["--convert-subs", "srt"]
            }
        }
        if let browser {
            arguments += ["--cookies-from-browser", browser]
        }
        arguments.append(pageURL.absoluteString)
        return arguments
    }

    private static func subtitleTracks(from dump: Dump) -> [SubtitleTrack] {
        var tracks: [String: SubtitleTrack] = [:]
        for (code, captions) in dump.subtitles ?? [:] {
            guard !captions.isEmpty else { continue }
            tracks[code] = SubtitleTrack(language: code, title: subtitleTitle(code, automatic: false), automatic: false)
        }
        for (code, captions) in dump.automaticCaptions ?? [:] {
            guard tracks[code] == nil, !captions.isEmpty else { continue }
            tracks[code] = SubtitleTrack(language: code, title: subtitleTitle(code, automatic: true), automatic: true)
        }
        return tracks.values.sorted { lhs, rhs in
            let left = subtitleRank(lhs)
            let right = subtitleRank(rhs)
            if left != right { return left < right }
            return lhs.language < rhs.language
        }
    }

    private static func subtitleTitle(_ code: String, automatic: Bool) -> String {
        let name: String
        switch code.lowercased() {
        case "zh-hans", "zh-cn":
            name = "简体中文"
        case "zh-hant", "zh-tw", "zh-hk":
            name = "繁体中文"
        case "zh":
            name = "中文"
        case "en", "en-us", "en-gb", "en-orig":
            name = "英语"
        case "ja":
            name = "日语"
        case "ko":
            name = "韩语"
        default:
            name = Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
        }
        return automatic ? "\(name)（自动生成）" : name
    }

    private static func subtitleRank(_ track: SubtitleTrack) -> Int {
        switch track.language.lowercased() {
        case "zh-hans", "zh-cn":
            return 0
        case "zh-hant", "zh-tw", "zh-hk":
            return 1
        case "zh":
            return 2
        case "en", "en-us", "en-gb", "en-orig":
            return 3
        case "ja":
            return 4
        case "ko":
            return 5
        default:
            return 10
        }
    }

    static func subtitleFiles(beside destination: URL, language: String) -> [URL] {
        let folder = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent + "."
        let wanted = language.lowercased()
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let matches = contents.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(stem) else { return false }
            let ext = url.pathExtension.lowercased()
            guard ext == "srt" || ext == "vtt" || ext == "ass" else { return false }
            let languagePart = String(name.dropFirst(stem.count).dropLast(ext.count + 1)).lowercased()
            return languagePart == wanted || languagePart.hasPrefix(wanted + "-") || languagePart.hasPrefix(wanted + ".")
        }
        let srt = matches.filter { $0.pathExtension.lowercased() == "srt" }
        return (srt.isEmpty ? matches : srt).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func attemptOrder() -> [String?] {
        var ordered = browsers
        let preferred = sessionBrowser ?? UserDefaults.standard.string(forKey: browserKey)
        if let preferred, preferred != "none", !preferred.isEmpty {
            ordered.removeAll { $0 == preferred }
            ordered.insert(preferred, at: 0)
        }
        return ordered.map(Optional.some) + [nil]
    }

    private static func remember(_ browser: String?) {
        let value = browser ?? "none"
        sessionBrowser = value
        UserDefaults.standard.set(value, forKey: browserKey)
    }

    private static func rememberedBrowser() -> String? {
        let value = sessionBrowser ?? UserDefaults.standard.string(forKey: browserKey)
        guard let value, value != "none", !value.isEmpty else { return nil }
        return value
    }

    static func locateExecutable(named name: String) -> String? {
        let fileManager = FileManager.default
        let fixed = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let found = fixed.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // Finder 启动的 App 不会带上 Homebrew 的 PATH，yt-dlp 合并时也要能找到 ffmpeg。
    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin"
        let current = environment["PATH"] ?? "/usr/bin:/bin"
        let parts = current.split(separator: ":").map(String.init)
        if !parts.contains("/opt/homebrew/bin") {
            environment["PATH"] = prefix + ":" + current
        }
        return environment
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func friendlyMessage(from output: String) -> String {
        let lowered = output.lowercased()
        if lowered.contains("sign in to confirm") || lowered.contains("not a bot") {
            return YouTubeClientError.needsLogin.errorDescription ?? "YouTube 下载失败。"
        }
        if lowered.contains("private video") || lowered.contains("video unavailable") {
            return "视频不可用，可能是私密、已删除或有地区限制。"
        }
        if lowered.contains("cookie") {
            return "无法读取浏览器里的 YouTube 登录状态。请确认已在 Safari 或 Chrome 登录 YouTube。"
        }
        if lowered.contains("ffmpeg") && (lowered.contains("not found") || lowered.contains("not installed")) {
            return YouTubeClientError.missingFFmpeg.errorDescription ?? "YouTube 下载失败。"
        }
        if let line = output.split(separator: "\n").last(where: { $0.contains("ERROR:") }) {
            let text = line.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                return String(text.prefix(300))
            }
        }
        return "YouTube 下载失败。"
    }

    private static func run(
        executable: String,
        arguments: [String],
        onProgress: ((DownloadProgress) -> Void)?
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = childEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        let progress = ProgressTap()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        let stdoutOnce = Once()
        let stderrOnce = Once()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutOnce.run {
                    handle.readabilityHandler = nil
                    group.leave()
                }
                return
            }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrOnce.run {
                    handle.readabilityHandler = nil
                    group.leave()
                }
                return
            }
            collector.appendStderr(data)
            if let value = progress.consume(data) {
                onProgress?(value)
            }
        }

        processLock.lock()
        runningProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            if runningProcess === process {
                runningProcess = nil
            }
            processLock.unlock()
        }

        do {
            try process.run()
        } catch {
            stdoutOnce.run { group.leave() }
            stderrOnce.run { group.leave() }
            let message = error.localizedDescription
            return CommandResult(status: 1, stdout: Data(), stderrText: message)
        }

        process.waitUntilExit()
        if group.wait(timeout: .now() + 10) == .timedOut {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutOnce.run { group.leave() }
            stderrOnce.run { group.leave() }
        }
        return CommandResult(
            status: process.terminationStatus,
            stdout: collector.stdout,
            stderrText: collector.stderrText
        )
    }
}

private struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderrText: String
}

private struct Dump: Decodable {
    let id: String?
    let formats: [Format]?
    let subtitles: [String: [Caption]]?
    let automaticCaptions: [String: [Caption]]?

    enum CodingKeys: String, CodingKey {
        case id
        case formats
        case subtitles
        case automaticCaptions = "automatic_captions"
    }
}

private struct Caption: Decodable {
    let ext: String?
}

private struct Format: Decodable {
    let formatID: String
    let ext: String?
    let width: Int?
    let height: Int?
    let vcodec: String?
    let acodec: String?
    let tbr: Double?
    let filesize: Double?
    let filesizeApprox: Double?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext
        case width
        case height
        case vcodec
        case acodec
        case tbr
        case filesize
        case filesizeApprox = "filesize_approx"
    }
}

private struct Candidate {
    var formatID: String
    var ext: String
    var width: Int
    var height: Int
    var vcodec: String
    var hasAudio: Bool
    var tbr: Double
    var fileSize: Int?

    init?(format: Format) {
        guard let width = format.width, let height = format.height, width >= 16, height >= 16 else { return nil }
        guard let vcodec = format.vcodec, vcodec != "none" else { return nil }
        let ext = format.ext?.lowercased() ?? ""
        guard ext != "mhtml" else { return nil }
        let acodec = format.acodec ?? "none"
        self.formatID = format.formatID
        self.ext = ext
        self.width = width
        self.height = height
        self.vcodec = vcodec
        self.hasAudio = !acodec.isEmpty && acodec != "none"
        self.tbr = format.tbr ?? 0
        let bytes = format.filesize ?? format.filesizeApprox ?? 0
        self.fileSize = bytes > 0 ? Int(bytes.rounded()) : nil
    }

    var rank: Double {
        var score = tbr
        if hasAudio { score += 1_000_000_000 }
        if ext == "mp4" { score += 100_000_000 }
        if vcodec.hasPrefix("avc1") { score += 10_000_000 }
        return score
    }

    var formatSelector: String {
        if hasAudio { return formatID }
        return "\(formatID)+bestaudio[ext=m4a]/\(formatID)+bestaudio"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func appendStdout(_ data: Data) {
        lock.lock()
        stdoutData.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    var stdout: Data {
        lock.lock()
        defer { lock.unlock() }
        return stdoutData
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

enum YouTubeProgressParser {
    private static let downloadLine = try? NSRegularExpression(
        pattern: #"\[download\]\s+([0-9]+(?:\.[0-9]+)?)%\s+of\s+~?\s*([0-9]+(?:\.[0-9]+)?)([KMGT]?i?B)\s+at\s+(?:Unknown B/s|([0-9]+(?:\.[0-9]+)?)([KMGT]?i?B)/s)\s+ETA\s+(\S+)"#
    )

    static func update(from text: String, fraction: Double) -> DownloadProgress? {
        if let line = lastDownloadLine(in: text), let parsed = parseDownloadLine(line) {
            return parsed
        }
        if text.contains("Sleeping") {
            return DownloadProgress(fraction: fraction, detail: "正在等待 YouTube 开始传输")
        }
        if text.contains("Downloading webpage") || text.contains("Solving JS") || text.contains("Extracting URL") {
            return DownloadProgress(fraction: fraction, detail: "正在连接 YouTube")
        }
        return nil
    }

    private static func lastDownloadLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map(String.init).last { $0.contains("[download]") && $0.contains("%") }
    }

    private static func parseDownloadLine(_ line: String) -> DownloadProgress? {
        guard let downloadLine else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = downloadLine.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else {
            return nil
        }
        let fraction = min(max(percent / 100, 0), 1)
        let total = number(in: line, match: match, valueIndex: 2, unitIndex: 3)
        let speed = number(in: line, match: match, valueIndex: 4, unitIndex: 5)
        let eta: String? = {
            guard let etaRange = Range(match.range(at: 6), in: line) else { return nil }
            let text = String(line[etaRange])
            if text.contains("-") || text.caseInsensitiveCompare("Unknown") == .orderedSame { return nil }
            return text
        }()
        var parts: [String] = []
        if percent < 10 {
            parts.append(String(format: "%.1f%%", percent))
        } else {
            parts.append("\(Int(percent.rounded()))%")
        }
        if let total, total > 0 {
            parts.append("\(MediaQuality.byteLabel(total * percent / 100)) / \(MediaQuality.byteLabel(total))")
        }
        if let speed, speed > 0 {
            parts.append("\(MediaQuality.byteLabel(speed))/s")
        }
        if let eta {
            parts.append("剩余 \(eta)")
        }
        return DownloadProgress(fraction: fraction, detail: parts.joined(separator: " · "))
    }

    private static func number(in line: String, match: NSTextCheckingResult, valueIndex: Int, unitIndex: Int) -> Double? {
        guard match.range(at: valueIndex).location != NSNotFound,
              match.range(at: unitIndex).location != NSNotFound,
              let valueRange = Range(match.range(at: valueIndex), in: line),
              let unitRange = Range(match.range(at: unitIndex), in: line),
              let value = Double(line[valueRange]) else {
            return nil
        }
        switch line[unitRange].lowercased() {
        case "b":
            return value
        case "kib", "kb":
            return value * 1024
        case "mib", "mb":
            return value * 1_048_576
        case "gib", "gb":
            return value * 1_073_741_824
        case "tib", "tb":
            return value * 1_099_511_627_776
        default:
            return value
        }
    }
}

private final class ProgressTap: @unchecked Sendable {
    private var pending = ""
    private var fraction = 0.0

    func consume(_ data: Data) -> DownloadProgress? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        pending += text
        if pending.count > 12_000 {
            pending = String(pending.suffix(4000))
        }
        guard let update = YouTubeProgressParser.update(from: pending, fraction: fraction) else { return nil }
        fraction = update.fraction
        return update
    }
}
