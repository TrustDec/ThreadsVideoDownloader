import AVFoundation
import XCTest
@testable import ThreadsVideoDownloaderCore

final class ThreadsVideoDownloaderCoreTests: XCTestCase {
    func testAcceptsThreadsShareAndPostLinks() {
        XCTAssertNotNil(SocialInput.validatedURL("https://www.threads.com/share/BBd0VIsOZn/"))
        XCTAssertNotNil(SocialInput.validatedURL("https://threads.net/@user/post/ABC123"))
        XCTAssertEqual(SocialInput.platform(for: URL(string: "https://www.threads.com/share/ABC123")!), .threads)
    }

    func testAcceptsDouyinShareAndVideoLinks() {
        XCTAssertNotNil(SocialInput.validatedURL("https://v.douyin.com/Hk_dx8CV7Js"))
        XCTAssertNotNil(SocialInput.validatedURL("https://www.douyin.com/video/7678685061026357669"))
        XCTAssertEqual(SocialInput.platform(for: URL(string: "https://v.douyin.com/Hk_dx8CV7Js")!), .douyin)
    }

    func testAcceptsXStatusLinks() {
        let share = URL(string: "https://x.com/jeremyjudkins_/status/2096370988728369381?s=46")!
        let twitter = URL(string: "https://twitter.com/jeremyjudkins_/status/2096370988728369381")!
        let shortStatus = URL(string: "https://x.com/i/status/2096370988728369381")!
        let webStatus = URL(string: "https://twitter.com/i/web/status/2096370988728369381")!
        XCTAssertNotNil(SocialInput.validatedURL(share.absoluteString))
        XCTAssertNotNil(SocialInput.validatedURL(twitter.absoluteString))
        XCTAssertNotNil(SocialInput.validatedURL(shortStatus.absoluteString))
        XCTAssertNotNil(SocialInput.validatedURL(webStatus.absoluteString))
        XCTAssertEqual(SocialInput.platform(for: share), .x)
        XCTAssertEqual(SocialInput.xStatusID(from: share), "2096370988728369381")
        XCTAssertEqual(SocialInput.xStatusID(from: webStatus), "2096370988728369381")
    }

    func testRejectsUnsupportedAndNonHttpsLinks() {
        XCTAssertNil(SocialInput.validatedURL("https://example.com/video.mp4"))
        XCTAssertNil(SocialInput.validatedURL("http://www.threads.com/share/ABC123"))
        XCTAssertNil(SocialInput.validatedURL("https://x.com/jeremyjudkins_"))
        XCTAssertNil(SocialInput.validatedURL("https://www.youtube.com/@channel"))
        XCTAssertNil(SocialInput.validatedURL("not a url"))
    }

    func testAcceptsYouTubeLinks() {
        let watch = URL(string: "https://www.youtube.com/watch?v=QW_jlUn4gA8")!
        XCTAssertEqual(SocialInput.platform(for: watch), .youtube)
        XCTAssertEqual(SocialInput.youtubeVideoID(from: watch), "QW_jlUn4gA8")
        XCTAssertNotNil(SocialInput.validatedURL(watch.absoluteString))
        XCTAssertEqual(SocialInput.youtubeVideoID(from: URL(string: "https://youtu.be/QW_jlUn4gA8")!), "QW_jlUn4gA8")
        XCTAssertEqual(SocialInput.youtubeVideoID(from: URL(string: "https://www.youtube.com/shorts/QW_jlUn4gA8")!), "QW_jlUn4gA8")
        XCTAssertEqual(SocialInput.youtubeVideoID(from: URL(string: "https://www.youtube.com/embed/QW_jlUn4gA8")!), "QW_jlUn4gA8")
        XCTAssertEqual(SocialInput.youtubeVideoID(from: URL(string: "https://m.youtube.com/watch?v=QW_jlUn4gA8&t=12s")!), "QW_jlUn4gA8")
        XCTAssertEqual(SocialInput.youtubeVideoID(from: URL(string: "https://music.youtube.com/watch?v=QW_jlUn4gA8")!), "QW_jlUn4gA8")
        XCTAssertNil(SocialInput.validatedURL("https://www.youtube.com/playlist?list=PL123"))
    }

    func testFileNameIsSafeAndStable() {
        XCTAssertEqual(DownloadFileNaming.baseName(platform: .threads, term: "DckK7UWkz6m", index: 0), "threads_DckK7UWkz6m.mp4")
        XCTAssertEqual(DownloadFileNaming.baseName(platform: .douyin, term: "a/b?c", index: 1), "douyin_a_b_c_2.mp4")
        XCTAssertEqual(DownloadFileNaming.baseName(platform: .x, term: "2096370988728369381", index: 0), "x_2096370988728369381.mp4")
        XCTAssertEqual(
            DownloadFileNaming.baseName(platform: .x, term: "2096370988728369381", index: 0, resolution: "1920x1080"),
            "x_2096370988728369381_1920x1080.mp4"
        )
        XCTAssertEqual(
            DownloadFileNaming.baseName(platform: .youtube, term: "QW_jlUn4gA8", index: 0, resolution: "640x360"),
            "youtube_QW_jlUn4gA8_640x360.mp4"
        )
    }

    func testYouTubeFormatSelectionPrefersPlayableMP4() throws {
        let json = """
        {"id":"QW_jlUn4gA8","formats":[
          {"format_id":"18","ext":"mp4","width":640,"height":360,"vcodec":"avc1.42001E","acodec":"mp4a.40.2","tbr":424.395},
          {"format_id":"134","ext":"mp4","width":640,"height":360,"vcodec":"avc1.4d401e","acodec":"none","tbr":900},
          {"format_id":"299","ext":"mp4","width":1920,"height":1080,"vcodec":"avc1.64002a","acodec":"none","tbr":2559.4},
          {"format_id":"303","ext":"webm","width":1920,"height":1080,"vcodec":"vp9","acodec":"none","tbr":8000},
          {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","tbr":129},
          {"format_id":"sb0","ext":"mhtml","width":320,"height":180,"vcodec":"none","acodec":"none","tbr":0}
        ]}
        """.data(using: .utf8)!
        let page = URL(string: "https://www.youtube.com/watch?v=QW_jlUn4gA8")!
        let resolved = try YouTubeClient.parse(data: json, pageURL: page)
        XCTAssertEqual(resolved.term, "QW_jlUn4gA8")
        XCTAssertEqual(resolved.variants.map(\.resolutionToken), ["1920x1080", "640x360"])
        let hd = try XCTUnwrap(resolved.variants.first { $0.height == 1080 })
        XCTAssertEqual(hd.formatSelector, "299+bestaudio[ext=m4a]/299+bestaudio")
        let sd = try XCTUnwrap(resolved.variants.first { $0.height == 360 })
        XCTAssertEqual(sd.formatSelector, "18")
        XCTAssertEqual(sd.bitrate, 424395)
    }

    func testYouTubeProgressKeepsSubPercentAndSpeed() {
        let line = "[download]   0.8% of    3.51GiB at    2.10MiB/s ETA 28:16"
        let update = YouTubeProgressParser.update(from: line, fraction: 0)
        XCTAssertEqual(update?.fraction ?? 0, 0.008, accuracy: 0.0001)
        XCTAssertEqual(update?.detail, "0.8% · 29 MB / 3.5 GB · 2.1 MB/s · 剩余 28:16")
    }

    func testYouTubeSubtitlesPreferManualChinese() throws {
        let json = """
        {"id":"QW_jlUn4gA8","formats":[
          {"format_id":"18","ext":"mp4","width":640,"height":360,"vcodec":"avc1","acodec":"mp4a.40.2","tbr":400}
        ],"subtitles":{"en":[{"ext":"vtt"}],"zh-Hans":[{"ext":"vtt"}]},
        "automatic_captions":{"en":[{"ext":"vtt"}],"ja":[{"ext":"json3"}]}}
        """.data(using: .utf8)!
        let page = URL(string: "https://www.youtube.com/watch?v=QW_jlUn4gA8")!
        let resolved = try YouTubeClient.parse(data: json, pageURL: page)
        XCTAssertEqual(resolved.subtitles.map(\.title), ["简体中文", "英语", "日语（自动生成）"])
        XCTAssertEqual(resolved.subtitles.map(\.automatic), [false, false, true])
        XCTAssertEqual(resolved.subtitles.map(\.language), ["zh-Hans", "en", "ja"])
    }

    func testParsesResolutionFromMediaURL() {
        let url = URL(string: "https://video.twimg.com/amplify_video/1/vid/avc1/1280x720/file.mp4")!
        XCTAssertEqual(MediaQuality.resolution(from: url)?.width, 1280)
        XCTAssertEqual(MediaQuality.resolution(from: url)?.height, 720)
    }

    func testListsQualitiesHighestFirstAndMatchesClosest() {
        let high = MediaQuality.variant(
            url: URL(string: "https://video.twimg.com/amplify_video/1/vid/avc1/1920x1080/a.mp4")!,
            bitrate: 10_368_000
        )
        let mid = MediaQuality.variant(
            url: URL(string: "https://video.twimg.com/amplify_video/1/vid/avc1/1280x720/b.mp4")!,
            bitrate: 2_176_000
        )
        let low = MediaQuality.variant(
            url: URL(string: "https://video.twimg.com/amplify_video/1/vid/avc1/640x360/c.mp4")!,
            bitrate: 832_000
        )
        let options = MediaQuality.uniqueOptions(from: [low, high, mid])
        XCTAssertEqual(options.map(\.key), ["1920x1080", "1280x720", "640x360"])
        XCTAssertEqual(options.first?.displayLabel, "1920×1080 · 10 Mbps")

        let secondVideoLow = MediaQuality.variant(
            url: URL(string: "https://video.twimg.com/amplify_video/2/vid/avc1/640x360/d.mp4")!,
            bitrate: 832_000,
            videoIndex: 1
        )
        let matched = MediaQuality.matchedVariants(
            from: [high, mid, low, secondVideoLow],
            option: options[1]
        )
        XCTAssertEqual(matched.map(\.resolutionToken), ["1280x720", "640x360"])
    }

    func testLiveYouTubeDownloadWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YOUTUBE_LIVE_TEST"] == "1")
        let page = URL(string: "https://www.youtube.com/watch?v=QW_jlUn4gA8")!
        let resolved = try YouTubeClient.resolve(pageURL: page).get()
        XCTAssertEqual(resolved.term, "QW_jlUn4gA8")
        let subtitle = try XCTUnwrap(
            resolved.subtitles.first { $0.language.caseInsensitiveCompare("zh-Hans") == .orderedSame }
                ?? resolved.subtitles.first
        )

        let progressive = try XCTUnwrap(resolved.variants.first { $0.formatSelector?.contains("+") == false })
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let savedName = DownloadFileNaming.baseName(
            platform: .youtube,
            term: resolved.term,
            index: 0,
            resolution: progressive.resolutionToken
        )
        let saved = downloads.appendingPathComponent(savedName)
        if FileManager.default.fileExists(atPath: saved.path) {
            try FileManager.default.removeItem(at: saved)
        }
        for oldSubtitle in YouTubeClient.subtitleFiles(beside: saved, language: subtitle.language) {
            try FileManager.default.removeItem(at: oldSubtitle)
        }
        let savedResult = YouTubeClient.download(
            pageURL: page,
            formatSelector: try XCTUnwrap(progressive.formatSelector),
            destination: saved,
            subtitleLanguage: subtitle.language,
            onProgress: { _ in }
        )
        let savedDownload = try savedResult.get()
        try await assertPlayableVideo(savedDownload.video, minimumSeconds: 800)
        let subtitleFile = try XCTUnwrap(savedDownload.subtitles.first)
        let subtitleText = try String(contentsOf: subtitleFile, encoding: .utf8)
        XCTAssertTrue(subtitleText.contains("-->"))
        print("saved \(savedDownload.video.path)")
        print("subtitle \(subtitleFile.path)")

        let merging = try XCTUnwrap(
            resolved.variants
                .filter { ($0.formatSelector?.contains("+") == true) && ($0.height ?? 0) > 0 }
                .min { ($0.height ?? 0) < ($1.height ?? 0) }
        )
        let merged = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-merge-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: merged) }
        let mergedResult = YouTubeClient.download(
            pageURL: page,
            formatSelector: try XCTUnwrap(merging.formatSelector),
            destination: merged,
            onProgress: { _ in }
        )
        try await assertPlayableVideo(try mergedResult.get().video, minimumSeconds: 800)
    }

    private func assertPlayableVideo(_ url: URL, minimumSeconds: Double) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(video.isEmpty)
        XCTAssertFalse(audio.isEmpty)
        XCTAssertGreaterThan(duration.seconds, minimumSeconds)
    }
}
