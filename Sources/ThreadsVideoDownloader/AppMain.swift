import Cocoa
import Foundation
import ThreadsVideoDownloaderCore

private let threadsResolverEndpoint = URL(string: "https://postcopilot.ai/api/download-video")!
private let douyinSessionEndpoint = URL(string: "https://www.smdownloader.com/api/session")!
private let douyinExtractEndpoint = URL(string: "https://www.smdownloader.com/api/extract")!
private let xResolverUserAgent = "Mozilla/5.0"

private struct ResolvedVideo: Decodable {
    let url: String
}

private struct ResolverResponse: Decodable {
    let success: Bool?
    let term: String?
    let videoUrls: [String]?
    let videos: [ResolvedVideo]?
    let message: String?
}

private struct DouyinSessionResponse: Decodable {
    let token: String?
}

private struct DouyinMedia: Decodable {
    let type: String
    let url: String
    let filename: String?
}

private struct DouyinData: Decodable {
    let sourceUrl: String?
    let media: [DouyinMedia]
}

private struct DouyinResolverResponse: Decodable {
    let ok: Bool?
    let data: DouyinData?
    let error: String?
}

private struct FxTwitterFormat: Decodable {
    let url: String
    let bitrate: Int?
    let container: String?
    let width: Int?
    let height: Int?
}

private struct FxTwitterVideo: Decodable {
    let url: String
    let width: Int?
    let height: Int?
    let formats: [FxTwitterFormat]?
}

private struct FxTwitterMedia: Decodable {
    let videos: [FxTwitterVideo]?
}

private struct FxTwitterTweet: Decodable {
    let id: String?
    let media: FxTwitterMedia?
}

private struct FxTwitterResponse: Decodable {
    let code: Int?
    let message: String?
    let tweet: FxTwitterTweet?
}

private struct VxTwitterSize: Decodable {
    let width: Int?
    let height: Int?
}

private struct VxTwitterMedia: Decodable {
    let type: String
    let url: String
    let size: VxTwitterSize?
}

private struct VxTwitterResponse: Decodable {
    let tweetID: String?
    let mediaURLs: [String]?
    let mediaExtended: [VxTwitterMedia]?

    enum CodingKeys: String, CodingKey {
        case tweetID
        case mediaURLs
        case mediaExtended = "media_extended"
    }
}

private enum DownloaderError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noVideo(String)
    case invalidMediaURL
    case invalidPlatform
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "解析服务返回了无法识别的结果。"
        case let .httpError(code):
            return "解析服务请求失败（HTTP \(code)）。"
        case let .noVideo(message):
            return message.isEmpty ? "没有找到可下载的视频。" : message
        case .invalidMediaURL:
            return "解析到了无效的视频地址。"
        case .invalidPlatform:
            return "暂不支持这个网站的链接。"
        case .sessionUnavailable:
            return "抖音解析服务暂时无法建立会话，请稍后重试。"
        }
    }
}

private struct ResolveResult {
    var term: String?
    var variants: [MediaVariant]
    var subtitles: [SubtitleTrack] = []
}

private final class DropReceiver: NSView {
    var onDrop: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string, .URL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { $0.scheme?.lowercased() == "https" }) {
            onDrop?(url.absoluteString)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onDrop?(text)
            return true
        }
        return false
    }
}

private final class MediaResolver {
    func resolve(inputURL: URL, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        guard let platform = SocialInput.platform(for: inputURL) else {
            completion(.failure(DownloaderError.invalidPlatform))
            return
        }

        switch platform {
        case .douyin:
            resolveDouyin(inputURL: inputURL, completion: completion)
            return
        case .x:
            resolveX(inputURL: inputURL, completion: completion)
            return
        case .youtube:
            DispatchQueue.global(qos: .userInitiated).async {
                let result = YouTubeClient.resolve(pageURL: inputURL)
                DispatchQueue.main.async {
                    completion(result.map {
                        ResolveResult(term: $0.term, variants: $0.variants, subtitles: $0.subtitles)
                    })
                }
            }
            return
        case .threads:
            break
        }

        var request = URLRequest(url: threadsResolverEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://postcopilot.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://postcopilot.ai/download", forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": inputURL.absoluteString])

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    completion(.failure(DownloaderError.httpError(httpResponse.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                do {
                    let payload = try JSONDecoder().decode(ResolverResponse.self, from: data)
                    let rawURLs = payload.videoUrls ?? payload.videos?.map(\.url) ?? []
                    let variants = rawURLs.enumerated().compactMap { index, raw -> MediaVariant? in
                        guard let url = URL(string: raw) else { return nil }
                        return MediaQuality.variant(url: url, videoIndex: index)
                    }
                    guard payload.success != false, !variants.isEmpty else {
                        completion(.failure(DownloaderError.noVideo(payload.message ?? "")))
                        return
                    }
                    completion(.success(ResolveResult(term: payload.term, variants: variants)))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private func resolveX(inputURL: URL, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        guard let statusID = SocialInput.xStatusID(from: inputURL) else {
            completion(.failure(DownloaderError.invalidPlatform))
            return
        }
        fetchFxTwitter(statusID: statusID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(value):
                completion(.success(value))
            case let .failure(error as DownloaderError):
                if case .noVideo = error {
                    completion(.failure(error))
                } else {
                    self.fetchVxTwitter(statusID: statusID, completion: completion)
                }
            case .failure:
                self.fetchVxTwitter(statusID: statusID, completion: completion)
            }
        }
    }

    private func fetchFxTwitter(statusID: String, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        guard let endpoint = URL(string: "https://api.fxtwitter.com/status/\(statusID)") else {
            completion(.failure(DownloaderError.invalidMediaURL))
            return
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(xResolverUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    completion(.failure(DownloaderError.httpError(httpResponse.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                do {
                    let payload = try JSONDecoder().decode(FxTwitterResponse.self, from: data)
                    let variants = Self.xVideoVariants(from: payload)
                    guard payload.code == 200, !variants.isEmpty else {
                        completion(.failure(DownloaderError.noVideo(payload.message ?? "这条帖子没有可下载的公开视频。")))
                        return
                    }
                    completion(.success(ResolveResult(term: payload.tweet?.id ?? statusID, variants: variants)))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private func fetchVxTwitter(statusID: String, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        guard let endpoint = URL(string: "https://api.vxtwitter.com/status/\(statusID)") else {
            completion(.failure(DownloaderError.invalidMediaURL))
            return
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(xResolverUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    completion(.failure(DownloaderError.httpError(httpResponse.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                do {
                    let payload = try JSONDecoder().decode(VxTwitterResponse.self, from: data)
                    let variants = Self.xVideoVariants(from: payload)
                    guard !variants.isEmpty else {
                        completion(.failure(DownloaderError.noVideo("这条帖子没有可下载的公开视频。")))
                        return
                    }
                    completion(.success(ResolveResult(term: payload.tweetID ?? statusID, variants: variants)))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private static func isMP4(_ url: String, container: String?) -> Bool {
        let lowered = url.lowercased()
        if lowered.contains(".m3u8") {
            return false
        }
        let kind = container?.lowercased() ?? ""
        return kind == "mp4" || lowered.contains(".mp4")
    }

    private static func xVideoVariants(from payload: FxTwitterResponse) -> [MediaVariant] {
        let videos = payload.tweet?.media?.videos ?? []
        var variants: [MediaVariant] = []
        var seen = Set<String>()
        for (index, video) in videos.enumerated() {
            let formats = (video.formats ?? []).filter { isMP4($0.url, container: $0.container) }
            if formats.isEmpty {
                if let url = URL(string: video.url), seen.insert(url.absoluteString).inserted {
                    variants.append(
                        MediaQuality.variant(url: url, videoIndex: index, width: video.width, height: video.height)
                    )
                }
                continue
            }
            for format in formats {
                guard let url = URL(string: format.url), seen.insert(url.absoluteString).inserted else { continue }
                variants.append(
                    MediaQuality.variant(
                        url: url,
                        bitrate: format.bitrate,
                        videoIndex: index,
                        width: format.width,
                        height: format.height
                    )
                )
            }
        }
        return variants
    }

    private static func xVideoVariants(from payload: VxTwitterResponse) -> [MediaVariant] {
        let extended = payload.mediaExtended?.enumerated().compactMap { index, item -> MediaVariant? in
            guard item.type == "video", let url = URL(string: item.url) else { return nil }
            return MediaQuality.variant(
                url: url,
                videoIndex: index,
                width: item.size?.width,
                height: item.size?.height
            )
        } ?? []
        if !extended.isEmpty {
            return extended
        }
        return payload.mediaURLs?.enumerated().compactMap { index, raw -> MediaVariant? in
            guard raw.contains(".mp4"), let url = URL(string: raw) else { return nil }
            return MediaQuality.variant(url: url, videoIndex: index)
        } ?? []
    }

    private func resolveDouyin(inputURL: URL, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        var components = URLComponents(url: douyinSessionEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fresh", value: UUID().uuidString)]
        var sessionRequest = URLRequest(url: components?.url ?? douyinSessionEndpoint)
        sessionRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        sessionRequest.setValue("https://www.smdownloader.com", forHTTPHeaderField: "Origin")
        sessionRequest.setValue("https://www.smdownloader.com/platforms/douyin/douyin-video-downloader", forHTTPHeaderField: "Referer")

        URLSession.shared.dataTask(with: sessionRequest) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let data,
                      let session = try? JSONDecoder().decode(DouyinSessionResponse.self, from: data),
                      let token = session.token,
                      !token.isEmpty else {
                    completion(.failure(DownloaderError.sessionUnavailable))
                    return
                }
                self.resolveDouyinMedia(inputURL: inputURL, token: token, completion: completion)
            }
        }.resume()
    }

    private func resolveDouyinMedia(inputURL: URL, token: String, completion: @escaping (Result<ResolveResult, Error>) -> Void) {
        var request = URLRequest(url: douyinExtractEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-sd-session")
        request.setValue("https://www.smdownloader.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.smdownloader.com/platforms/douyin/douyin-video-downloader", forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": inputURL.absoluteString])

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    completion(.failure(DownloaderError.httpError(httpResponse.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(DownloaderError.invalidResponse))
                    return
                }
                do {
                    let payload = try JSONDecoder().decode(DouyinResolverResponse.self, from: data)
                    let videoMedia = payload.data?.media.filter { $0.type == "video" } ?? []
                    let variants = videoMedia.enumerated().compactMap { index, item -> MediaVariant? in
                        guard let url = URL(string: item.url) else { return nil }
                        return MediaQuality.variant(url: url, videoIndex: index)
                    }
                    guard payload.ok == true, !variants.isEmpty else {
                        completion(.failure(DownloaderError.noVideo(payload.error ?? "")))
                        return
                    }
                    let term = Self.douyinTerm(data: payload.data, firstMedia: videoMedia.first)
                    completion(.success(ResolveResult(term: term, variants: variants)))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private static func douyinTerm(data: DouyinData?, firstMedia: DouyinMedia?) -> String? {
        if let sourceURL = data?.sourceUrl, let url = URL(string: sourceURL), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return firstMedia?.filename?.replacingOccurrences(of: "douyin-", with: "").replacingOccurrences(of: "-video-HD.mp4", with: "")
    }
}

private final class MediaDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void
    private let completionHandler: (Result<URL, Error>) -> Void
    private var didFinish = false
    private var session: URLSession?

    init(progressHandler: @escaping (Double) -> Void, completionHandler: @escaping (Result<URL, Error>) -> Void) {
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
    }

    func start(url: URL, headers: [String: String] = [:]) {
        let configuration = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        session?.downloadTask(with: request).resume()
    }

    func cancel() {
        didFinish = true
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progressHandler(min(max(value, 0), 1)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !didFinish else { return }
        didFinish = true
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            DispatchQueue.main.async { self.completionHandler(.failure(DownloaderError.httpError(response.statusCode))) }
            return
        }
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threads-video-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: location, to: copyURL)
            DispatchQueue.main.async { self.completionHandler(.success(copyURL)) }
        } catch {
            DispatchQueue.main.async { self.completionHandler(.failure(error)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !didFinish else { return }
        didFinish = true
        DispatchQueue.main.async { self.completionHandler(.failure(error)) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let folderDefaultsKey = "downloadFolder"
    private let resolver = MediaResolver()
    private var currentDownloadDelegate: MediaDownloadDelegate?
    private var operationID = 0
    private var pendingVariants: [MediaVariant] = []
    private var pendingTerm: String?
    private var pendingSubtitle: SubtitleTrack?
    private var downloadedSubtitles: [URL] = []
    private var pendingPlatform: SocialPlatform = .threads
    private var pendingIndex = 0
    private var downloadedFiles: [URL] = []
    private var history: [URL] = []
    private var resolvedVariants: [MediaVariant] = []
    private var resolvedSubtitles: [SubtitleTrack] = []
    private var qualityOptions: [MediaQualityOption] = []
    private var resolvedURLString = ""
    private var isResolved = false

    private var window: NSWindow!
    private var urlField: NSTextField!
    private var folderLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var percentLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var downloadButton: NSButton!
    private var pasteButton: NSButton!
    private var cancelButton: NSButton!
    private var chooseFolderButton: NSButton!
    private var openFolderButton: NSButton!
    private var revealButton: NSButton!
    private var qualityPopup: NSPopUpButton!
    private var subtitlePopup: NSPopUpButton!
    private var historyTable: NSTableView!
    private var selectedFolder: URL

    override init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let saved = UserDefaults.standard.string(forKey: folderDefaultsKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory), isDirectory.boolValue {
                selectedFolder = URL(fileURLWithPath: saved, isDirectory: true)
            } else {
                selectedFolder = downloads
            }
        } else {
            selectedFolder = downloads
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildWindow()
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于视频下载器", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出视频下载器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "视频下载器"
        window.minSize = NSSize(width: 700, height: 500)
        window.center()

        let content = DropReceiver(frame: frame)
        content.onDrop = { [weak self] text in self?.acceptLink(text, resolve: true) }
        window.contentView = content

        let hint = NSTextField(labelWithString: "支持 Threads、抖音、X、YouTube。可粘贴或拖入链接，解析后在这里选清晰度和字幕。")
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        add(hint, to: content)

        urlField = NSTextField()
        urlField.placeholderString = "粘贴或拖入 https 视频链接"
        urlField.focusRingType = .default
        urlField.delegate = self
        urlField.cell?.sendsActionOnEndEditing = false
        add(urlField, to: content)

        pasteButton = NSButton(title: "粘贴", target: self, action: #selector(pasteLink))
        pasteButton.bezelStyle = .rounded
        add(pasteButton, to: content)

        downloadButton = NSButton(title: "解析链接", target: self, action: #selector(primaryAction))
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        add(downloadButton, to: content)

        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelWork))
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        add(cancelButton, to: content)

        chooseFolderButton = NSButton(title: "选择目录…", target: self, action: #selector(chooseFolder))
        chooseFolderButton.bezelStyle = .rounded
        add(chooseFolderButton, to: content)

        openFolderButton = NSButton(title: "打开目录", target: self, action: #selector(openFolder))
        openFolderButton.bezelStyle = .rounded
        add(openFolderButton, to: content)

        revealButton = NSButton(title: "显示文件", target: self, action: #selector(revealSelection))
        revealButton.bezelStyle = .rounded
        add(revealButton, to: content)

        let buttonRow = NSStackView(views: [downloadButton, cancelButton, chooseFolderButton, openFolderButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.detachesHiddenViews = true
        add(buttonRow, to: content)

        folderLabel = NSTextField(labelWithString: "保存到：\(selectedFolder.path)")
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        add(folderLabel, to: content)

        let qualityLabel = NSTextField(labelWithString: "清晰度")
        add(qualityLabel, to: content)
        qualityPopup = NSPopUpButton()
        qualityPopup.addItem(withTitle: "先解析链接")
        qualityPopup.isEnabled = false
        add(qualityPopup, to: content)

        let subtitleLabel = NSTextField(labelWithString: "字幕")
        add(subtitleLabel, to: content)
        subtitlePopup = NSPopUpButton()
        subtitlePopup.addItem(withTitle: "无字幕")
        subtitlePopup.isEnabled = false
        add(subtitlePopup, to: content)

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        add(progress, to: content)

        percentLabel = NSTextField(labelWithString: "")
        percentLabel.alignment = .right
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        add(percentLabel, to: content)

        statusLabel = NSTextField(wrappingLabelWithString: "准备就绪。粘贴链接后点「解析链接」，选好清晰度再下载。")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        add(statusLabel, to: content)

        let historyLabel = NSTextField(labelWithString: "本次下载")
        historyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        add(historyLabel, to: content)

        historyTable = NSTableView()
        historyTable.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "文件"
        column.minWidth = 240
        column.width = 760
        column.resizingMask = .autoresizingMask
        historyTable.addTableColumn(column)
        historyTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.target = self
        historyTable.doubleAction = #selector(revealSelection)
        historyTable.rowHeight = 22
        historyTable.usesAlternatingRowBackgroundColors = true
        let historyScroll = NSScrollView()
        historyScroll.hasVerticalScroller = true
        historyScroll.borderType = .bezelBorder
        historyScroll.documentView = historyTable
        add(historyScroll, to: content)

        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            urlField.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            urlField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            urlField.heightAnchor.constraint(equalToConstant: 28),

            pasteButton.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            pasteButton.leadingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: 8),
            pasteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            pasteButton.widthAnchor.constraint(equalToConstant: 72),

            buttonRow.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            folderLabel.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 10),
            folderLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            folderLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            qualityLabel.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),
            qualityLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            qualityPopup.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 10),
            qualityPopup.leadingAnchor.constraint(equalTo: qualityLabel.trailingAnchor, constant: 8),

            subtitleLabel.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: qualityPopup.trailingAnchor, constant: 16),
            subtitlePopup.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),
            subtitlePopup.leadingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor, constant: 8),
            subtitlePopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            subtitlePopup.widthAnchor.constraint(equalTo: qualityPopup.widthAnchor),

            progress.topAnchor.constraint(equalTo: qualityPopup.bottomAnchor, constant: 14),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            progress.heightAnchor.constraint(equalToConstant: 14),

            percentLabel.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
            percentLabel.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            percentLabel.widthAnchor.constraint(equalToConstant: 52),

            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),

            historyLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            historyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            historyScroll.topAnchor.constraint(equalTo: historyLabel.bottomAnchor, constant: 6),
            historyScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            historyScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            historyScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(urlField)
    }

    private func add(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        if urlField.stringValue != resolvedURLString {
            clearResolvedOptions()
        }
    }

    @objc private func pasteLink() {
        acceptLink(NSPasteboard.general.string(forType: .string) ?? "", resolve: true)
    }

    @objc private func primaryAction() {
        if isResolved {
            startTransfer()
        } else {
            startResolve()
        }
    }

    @objc private func cancelWork() {
        operationID += 1
        currentDownloadDelegate?.cancel()
        currentDownloadDelegate = nil
        YouTubeClient.cancel()
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        setProgress(0)
        setBusy(false)
        statusLabel.stringValue = "已取消。可以改清晰度或字幕后再下载。"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        UserDefaults.standard.set(url.path, forKey: folderDefaultsKey)
        folderLabel.stringValue = "保存到：\(url.path)"
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(selectedFolder)
    }

    @objc private func revealSelection() {
        let row = historyTable.selectedRow
        if history.indices.contains(row) {
            NSWorkspace.shared.activateFileViewerSelecting([history[row]])
        } else if let last = history.last {
            NSWorkspace.shared.activateFileViewerSelecting([last])
        } else {
            NSWorkspace.shared.open(selectedFolder)
        }
    }

    private func acceptLink(_ raw: String, resolve: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).map(String.init).first { $0.contains("http") } ?? trimmed
        urlField.stringValue = line
        clearResolvedOptions()
        if resolve, SocialInput.validatedURL(line) != nil {
            startResolve()
        }
    }

    private func startResolve() {
        guard let inputURL = SocialInput.validatedURL(urlField.stringValue),
              let platform = SocialInput.platform(for: inputURL) else {
            showError("请输入有效的 Threads、抖音、X 或 YouTube HTTPS 链接。")
            return
        }

        pendingPlatform = platform
        let operation = beginOperation()
        setBusy(true)
        statusLabel.stringValue = "正在解析\(platform.displayName)视频链接…"
        statusLabel.textColor = .secondaryLabelColor
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        percentLabel.stringValue = ""

        resolver.resolve(inputURL: inputURL) { [weak self] result in
            guard let self, self.operationID == operation else { return }
            self.progress.stopAnimation(nil)
            self.progress.isIndeterminate = false
            self.setProgress(0)
            self.setBusy(false)
            switch result {
            case let .failure(error):
                self.showError(error.localizedDescription)
            case let .success(value):
                self.applyResolved(value)
            }
        }
    }

    private func startTransfer() {
        guard isResolved, qualityPopup.indexOfSelectedItem < qualityOptions.count else { return }
        let option = qualityOptions[qualityPopup.indexOfSelectedItem]
        pendingVariants = MediaQuality.matchedVariants(from: resolvedVariants, option: option)
        let subtitleIndex = subtitlePopup.indexOfSelectedItem
        pendingSubtitle = subtitleIndex > 0 && subtitleIndex <= resolvedSubtitles.count
            ? resolvedSubtitles[subtitleIndex - 1]
            : nil
        pendingIndex = 0
        downloadedFiles = []
        downloadedSubtitles = []
        _ = beginOperation()
        setBusy(true)
        let quality = option.displayLabel
        if let subtitle = pendingSubtitle {
            statusLabel.stringValue = "开始下载 \(quality)，字幕：\(subtitle.title)"
        } else {
            statusLabel.stringValue = "开始下载 \(quality)"
        }
        statusLabel.textColor = .secondaryLabelColor
        downloadNext()
    }

    private func downloadNext() {
        let operation = operationID
        guard pendingIndex < pendingVariants.count else {
            setProgress(1)
            setBusy(false)
            history.append(contentsOf: downloadedFiles)
            history.append(contentsOf: downloadedSubtitles)
            historyTable.reloadData()
            if let last = history.indices.last {
                historyTable.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
                historyTable.scrollRowToVisible(last)
            }
            let count = downloadedFiles.count
            if downloadedSubtitles.isEmpty {
                var message = "下载完成：\(count) 个视频。双击下方列表可在访达中显示。"
                if pendingSubtitle != nil {
                    message = "视频已保存，所选字幕没有下载到。"
                }
                statusLabel.stringValue = message
            } else {
                statusLabel.stringValue = "下载完成：\(count) 个视频、\(downloadedSubtitles.count) 个字幕。双击下方列表可在访达中显示。"
            }
            return
        }

        let index = pendingIndex
        let variant = pendingVariants[index]
        let sourceURL = variant.url
        let destination = uniqueDestination(
            folder: selectedFolder,
            fileName: DownloadFileNaming.baseName(
                platform: pendingPlatform,
                term: pendingTerm,
                index: index,
                resolution: variant.resolutionToken
            )
        )
        setProgress(0)
        let quality = variant.resolutionToken.map { $0.replacingOccurrences(of: "x", with: "×") } ?? "未知分辨率"
        statusLabel.stringValue = "正在下载 \(quality)（第 \(index + 1)/\(pendingVariants.count) 个）…"

        if pendingPlatform == .youtube {
            downloadYouTube(variant: variant, destination: destination, operation: operation)
            return
        }

        let delegate = MediaDownloadDelegate(
            progressHandler: { [weak self] value in
                guard let self, self.operationID == operation else { return }
                self.setProgress(value)
            },
            completionHandler: { [weak self] result in
                guard let self, self.operationID == operation else { return }
                switch result {
                case let .failure(error):
                    self.showError(error.localizedDescription)
                    self.setBusy(false)
                case let .success(tempURL):
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        self.downloadedFiles.append(destination)
                        self.pendingIndex += 1
                        self.downloadNext()
                    } catch {
                        self.showError("保存文件失败：\(error.localizedDescription)")
                        self.setBusy(false)
                    }
                }
            }
        )
        var headers: [String: String] = [:]
        if pendingPlatform == .x {
            headers["Referer"] = "https://x.com/"
            headers["User-Agent"] = xResolverUserAgent
        }
        currentDownloadDelegate = delegate
        delegate.start(url: sourceURL, headers: headers)
    }

    private func downloadYouTube(variant: MediaVariant, destination: URL, operation: Int) {
        guard let selector = variant.formatSelector else {
            showError("没有可用的 YouTube 清晰度。")
            setBusy(false)
            return
        }
        let pageURL = variant.url
        let subtitleLanguage = pendingSubtitle?.language
        let quality = variant.resolutionToken?.replacingOccurrences(of: "x", with: "×") ?? "所选清晰度"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = YouTubeClient.download(
                pageURL: pageURL,
                formatSelector: selector,
                destination: destination,
                subtitleLanguage: subtitleLanguage,
                onProgress: { update in
                    DispatchQueue.main.async {
                        guard let self, self.operationID == operation else { return }
                        self.setProgress(update.fraction)
                        if !update.detail.isEmpty {
                            self.statusLabel.stringValue = "正在下载 \(quality) · \(update.detail)"
                        }
                    }
                }
            )
            DispatchQueue.main.async {
                guard let self, self.operationID == operation else { return }
                switch result {
                case let .failure(error):
                    self.showError(error.localizedDescription)
                    self.setBusy(false)
                case let .success(download):
                    self.downloadedFiles.append(download.video)
                    self.downloadedSubtitles.append(contentsOf: download.subtitles)
                    self.pendingIndex += 1
                    self.downloadNext()
                }
            }
        }
    }

    private func applyResolved(_ value: ResolveResult) {
        pendingTerm = value.term
        resolvedVariants = value.variants
        resolvedSubtitles = value.subtitles
        qualityOptions = MediaQuality.uniqueOptions(from: value.variants)
        qualityPopup.removeAllItems()
        if qualityOptions.isEmpty {
            qualityPopup.addItem(withTitle: "没有可下载的清晰度")
            qualityPopup.isEnabled = false
            isResolved = false
        } else {
            for option in qualityOptions {
                qualityPopup.addItem(withTitle: option.displayLabel)
            }
            qualityPopup.selectItem(at: preferredQualityIndex())
            qualityPopup.isEnabled = true
            isResolved = true
        }
        subtitlePopup.removeAllItems()
        subtitlePopup.addItem(withTitle: value.subtitles.isEmpty ? "无字幕" : "不下载字幕")
        for track in value.subtitles {
            subtitlePopup.addItem(withTitle: track.title)
        }
        subtitlePopup.selectItem(at: preferredSubtitleIndex(in: value.subtitles))
        subtitlePopup.isEnabled = !value.subtitles.isEmpty
        resolvedURLString = urlField.stringValue
        downloadButton.title = isResolved ? "开始下载" : "解析链接"
        if isResolved {
            let subtitleNote = value.subtitles.isEmpty ? "" : "，\(value.subtitles.count) 种字幕"
            let selected = qualityOptions[qualityPopup.indexOfSelectedItem].displayLabel
            statusLabel.stringValue = "已解析 \(qualityOptions.count) 档清晰度\(subtitleNote)。当前 \(selected)，选好后点「开始下载」。"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func clearResolvedOptions() {
        guard isResolved || qualityPopup.numberOfItems != 1 || qualityPopup.itemTitle(at: 0) != "先解析链接" else { return }
        isResolved = false
        resolvedURLString = ""
        resolvedVariants = []
        resolvedSubtitles = []
        qualityOptions = []
        qualityPopup.removeAllItems()
        qualityPopup.addItem(withTitle: "先解析链接")
        qualityPopup.isEnabled = false
        subtitlePopup.removeAllItems()
        subtitlePopup.addItem(withTitle: "无字幕")
        subtitlePopup.isEnabled = false
        downloadButton.title = "解析链接"
    }

    private func beginOperation() -> Int {
        operationID += 1
        return operationID
    }

    private func preferredQualityIndex() -> Int {
        if let index = qualityOptions.firstIndex(where: { $0.height == 1080 }) {
            return index
        }
        if let index = qualityOptions.firstIndex(where: { $0.height == 720 }) {
            return index
        }
        return 0
    }

    private func setProgress(_ value: Double) {
        let fraction = min(max(value, 0), 1)
        progress.doubleValue = fraction
        let percent = fraction * 100
        if percent > 0, percent < 10 {
            percentLabel.stringValue = String(format: "%.1f%%", percent)
        } else {
            percentLabel.stringValue = "\(Int(percent.rounded()))%"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { history.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.lineBreakMode = .byTruncatingMiddle
        cell.stringValue = history[row].lastPathComponent
        cell.toolTip = history[row].path
        return cell
    }

    private func preferredSubtitleIndex(in tracks: [SubtitleTrack]) -> Int {
        let codes = tracks.map { $0.language.lowercased() }
        if let index = codes.firstIndex(where: { $0 == "zh-hans" || $0 == "zh-cn" }) {
            return index + 1
        }
        if let index = codes.firstIndex(where: { $0 == "zh" || $0 == "zh-hant" || $0 == "zh-tw" || $0 == "zh-hk" }) {
            return index + 1
        }
        if let index = codes.firstIndex(where: { $0 == "en" || $0.hasPrefix("en-") }) {
            return index + 1
        }
        return tracks.isEmpty ? 0 : 1
    }

    private func uniqueDestination(folder: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            candidate = folder.appendingPathComponent("\(base)_\(suffix).mp4")
            suffix += 1
        }
        return candidate
    }

    private func setBusy(_ busy: Bool) {
        urlField.isEnabled = !busy
        pasteButton.isEnabled = !busy
        downloadButton.isEnabled = !busy
        chooseFolderButton.isEnabled = !busy
        openFolderButton.isEnabled = !busy
        revealButton.isEnabled = !busy
        qualityPopup.isEnabled = !busy && isResolved
        subtitlePopup.isEnabled = !busy && !resolvedSubtitles.isEmpty
        cancelButton.isHidden = !busy
        cancelButton.keyEquivalent = busy ? "\u{1b}" : ""
    }

    private func showError(_ message: String) {
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        setProgress(0)
        statusLabel.stringValue = "失败：\(message)"
        statusLabel.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.statusLabel.textColor = .secondaryLabelColor
        }
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
