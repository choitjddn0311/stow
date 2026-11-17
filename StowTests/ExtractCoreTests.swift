import Foundation
import Testing
@testable import Stow

struct YouTubeURLTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=abc123",
        "https://youtube.com/watch?v=abc123&list=PL1",
        "http://m.youtube.com/watch?v=abc123",
        "https://music.youtube.com/watch?v=abc123",
        "https://youtu.be/abc123",
        "youtu.be/abc123",
        "  https://www.youtube.com/shorts/abc123\n",
        "https://WWW.YOUTUBE.COM/watch?v=abc123",
        "youtube.com/watch?v=abc123&redirect=https://x",  // 쿼리 안의 "://"는 스킴이 아니다
        "https://youtu.be/playlist",  // youtu.be는 영상 ID만 온다
    ])
    func acceptsYouTubeURLs(_ input: String) throws {
        let url = try YouTubeURL.parse(input)
        #expect(url.scheme == "https" || url.scheme == "http")
    }

    @Test(arguments: [
        "",
        "abc",
        "https://www.youtube.com/",
        "https://example.com/watch?v=abc123",
        "https://notyoutube.com/watch?v=abc123",
        "https://youtube.com.evil.com/watch?v=abc123",
        "ftp://youtube.com/watch?v=abc123",
        "file:///Users/me/youtube.com/a",
    ])
    func rejectsOtherInput(_ input: String) {
        #expect(throws: EngineError.invalidURL) { try YouTubeURL.parse(input) }
    }

    /// 재생목록 주소는 받는다(영상을 골라 대기열에 넣는다).
    @Test func acceptsPlaylistURL() throws {
        let url = try YouTubeURL.parse("https://www.youtube.com/playlist?list=PL123")
        #expect(url.path == "/playlist")
    }

    /// 채널 주소는 yt-dlp를 실행하기 전에 거부한다.
    @Test(arguments: [
        "https://www.youtube.com/@channel",
        "https://www.youtube.com/@channel/videos",
        "https://www.youtube.com/channel/UC123",
        "https://www.youtube.com/c/name",
        "https://www.youtube.com/user/name",
    ])
    func rejectsChannelPages(_ input: String) {
        #expect(throws: EngineError.channelNotSupported) { try YouTubeURL.parse(input) }
    }
}

struct ProgressParserTests {
    @Test func parsesDownloadProgress() {
        #expect(
            ProgressParser.parse("[stow:download] downloading 261120 529244 NA 256731519.09 3")
                == .progress(.downloading(fraction: 261120.0 / 529244.0, bytesPerSecond: 256731519.09, secondsRemaining: 3))
        )
    }

    @Test func usesEstimatedTotalWhenExactIsMissing() {
        #expect(
            ProgressParser.parse("[stow:download] downloading 50 NA 200 NA NA")
                == .progress(.downloading(fraction: 0.25, bytesPerSecond: nil, secondsRemaining: nil))
        )
    }

    @Test func unknownTotalHasNoFraction() {
        #expect(
            ProgressParser.parse("[stow:download] downloading 1024 NA NA NA NA")
                == .progress(.downloading(fraction: nil, bytesPerSecond: nil, secondsRemaining: nil))
        )
    }

    @Test func finishedDownloadIsComplete() {
        #expect(
            ProgressParser.parse("[stow:download] finished 529244 529244 NA 327260832.4 NA")
                == .progress(.downloading(fraction: 1, bytesPerSecond: 327260832.4, secondsRemaining: nil))
        )
    }

    @Test func parsesPostprocessorStarts() {
        #expect(ProgressParser.parse("[stow:postprocess] started ExtractAudio") == .progress(.converting))
        #expect(ProgressParser.parse("[stow:postprocess] started Metadata") == .progress(.embeddingMetadata))
        #expect(ProgressParser.parse("[stow:postprocess] finished ExtractAudio") == nil)
        #expect(ProgressParser.parse("[stow:postprocess] started MoveFiles") == nil)
    }

    @Test func parsesOutputFileWithSpaces() {
        #expect(
            ProgressParser.parse("[stow:file] /tmp/work dir/abc 123.mp3") == .outputFile("/tmp/work dir/abc 123.mp3")
        )
    }

    @Test(arguments: [
        "[download] 12.3% of 3.00MiB",
        "WARNING: something",
        "[stow:download] downloading 1 2",
        "[stow:file] ",
        "",
    ])
    func ignoresOtherLines(_ line: String) {
        #expect(ProgressParser.parse(line) == nil)
    }
}

struct YtDlpErrorMapperTests {
    @Test(arguments: [
        ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video", EngineError.privateVideo),
        ("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", .ageRestricted),
        ("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser", .blockedByYouTube),
        ("ERROR: [youtube] abc: Join this channel to get access to members-only content like this video", .loginRequired),
        ("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader", .videoUnavailable),
        ("ERROR: [youtube] abc: The uploader has not made this video available in your country", .videoUnavailable),
        ("ERROR: [youtube] abc: This live event will begin in 3 hours.", .liveNotSupported),
        ("ERROR: Unsupported URL: https://www.youtube.com/about", .unsupportedURL),
        ("ERROR: [youtube] abc: Requested format is not available. Use --list-formats", .noAudioFormat),
        ("ERROR: [youtube] abc: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>", .network),
        ("ERROR: unable to write data: [Errno 28] No space left on device", .diskFull),
        ("ERROR: unable to open for writing: [Errno 13] Permission denied: '/x.part'", .permissionDenied),
        ("ERROR: Postprocessing: audio conversion failed: Error opening output files", .conversionFailed),
        ("ERROR: [youtube] abc: Unable to download webpage: HTTP Error 429: Too Many Requests", .blockedByYouTube),
        ("ERROR: unable to download video data: HTTP Error 403: Forbidden", .blockedByYouTube),
        ("ERROR: [youtube] abc: Video unavailable. This content isn’t available, try again later.", .blockedByYouTube),
    ])
    func mapsKnownErrors(_ line: String, _ expected: EngineError) {
        #expect(YtDlpErrorMapper.map(stderr: ["WARNING: ignore me", line]) == expected)
    }

    @Test func keepsUnknownMessage() {
        let error = YtDlpErrorMapper.map(stderr: ["ERROR: something new happened"])
        #expect(error == .unknown("ERROR: something new happened"))
        #expect(error.localizedDescription.contains("알 수 없는 오류"))
    }

    /// `ERROR:` 줄이 없으면 경고·진행률 줄로 분류하지 않고, 남은 마지막 줄을 원문으로 남긴다.
    @Test func ignoresWarningsWhenNoErrorLine() {
        let error = YtDlpErrorMapper.map(stderr: [
            "[stow:postprocess] started ExtractAudio",
            "WARNING: ffmpeg timed out",
            "Traceback (most recent call last):",
            "KeyboardInterrupt",
        ])
        #expect(error == .unknown("Traceback (most recent call last):\nKeyboardInterrupt"))
    }
}

struct VideoMetadataTests {
    @Test func decodesYtDlpJSON() throws {
        let json = """
        {"id": "abc123", "title": "제목: 테스트", "duration": 212.5, "thumbnail": "https://i.ytimg.com/vi/abc123/maxresdefault.jpg",
         "uploader": "채널", "webpage_url": "https://www.youtube.com/watch?v=abc123", "live_status": "not_live",
         "formats": [{"format_id": "251"}], "_type": "video"}
        """
        let metadata = try JSONDecoder().decode(VideoMetadata.self, from: Data(json.utf8))
        #expect(metadata == VideoMetadata(
            id: "abc123", title: "제목: 테스트", duration: 212.5,
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/abc123/maxresdefault.jpg"),
            uploader: "채널", webpageURL: URL(string: "https://www.youtube.com/watch?v=abc123"),
            liveStatus: "not_live"
        ))
    }

    @Test func toleratesMissingOptionalFields() throws {
        let metadata = try JSONDecoder().decode(VideoMetadata.self, from: Data(#"{"id": "x", "channel": "c"}"#.utf8))
        #expect(metadata.title == "x")
        #expect(metadata.duration == nil)
        #expect(metadata.uploader == "c")
    }

    @Test func decodesVideoAsFetchedMedia() throws {
        let json = #"{"id": "abc", "title": "영상", "_type": "video"}"#
        let media = try JSONDecoder().decode(FetchedMedia.self, from: Data(json.utf8))
        guard case .video(let metadata) = media else { Issue.record("영상으로 해석되지 않음"); return }
        #expect(metadata.title == "영상")
    }

    /// `yt-dlp -J --flat-playlist` 형식. 잘못된 항목(ID 없음·이상한 ID)은 빼고 나머지는 살린다.
    @Test func decodesPlaylistEntries() throws {
        let json = """
        {"id": "PL1", "title": "내 목록", "_type": "playlist", "entries": [
          {"_type": "url", "id": "dQw4w9WgXcQ", "title": "첫 곡", "duration": 212.0, "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
          {"_type": "url", "id": "abc_DEF-123", "title": "[Private video]", "duration": null},
          {"_type": "url", "title": "ID 없음"},
          {"_type": "url", "id": "../evil", "title": "이상한 ID"},
          {"_type": "url", "id": "zzz"},
          {"_type": "url", "id": "dQw4w9WgXcQ", "title": "중복"},
          {"_type": "url", "ie_key": "YoutubeTab", "id": "PLxxxxxxxxx", "title": "하위 재생목록"},
          {"_type": "playlist", "id": "UCxxxxxxxxx", "title": "채널 탭"},
          {"_type": "url", "ie_key": "Youtube", "id": "zzzzzzzzzzz"}
        ], "playlist_count": 900}
        """
        let media = try JSONDecoder().decode(FetchedMedia.self, from: Data(json.utf8))
        guard case .playlist(let playlist) = media else { Issue.record("재생목록으로 해석되지 않음"); return }
        #expect(playlist.title == "내 목록")
        // ID 11자만, 중복 제거, 하위 재생목록·채널 탭(ie_key·_type) 제외
        #expect(playlist.entries.map(\.id) == ["dQw4w9WgXcQ", "abc_DEF-123", "zzzzzzzzzzz"])
        #expect(playlist.entries[0].title == "첫 곡")
        #expect(playlist.totalCount == 900)
        #expect(playlist.isTruncated)
        #expect(playlist.entries[0].duration == 212)
        #expect(playlist.entries[0].url == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(playlist.entries[1].isUnavailable)
        #expect(!playlist.entries[0].isUnavailable)
        #expect(playlist.entries[2].title == "제목 없음")
    }

    @Test func rejectsUnknownMediaType() {
        let json = #"{"id": "x", "_type": "multi_video"}"#
        #expect(throws: EngineError.unsupportedURL) {
            try JSONDecoder().decode(FetchedMedia.self, from: Data(json.utf8))
        }
    }
}

struct YtDlpArgumentsTests {
    private let engine = try! EngineLocator.bundled()

    @Test func metadataArgumentsEndWithURLAfterSeparator() {
        let url = URL(string: "https://youtu.be/abc")!
        let arguments = YtDlpArguments(engine: engine).metadata(for: url)
        #expect(arguments.contains("--ignore-config"))
        #expect(arguments.contains("--no-playlist"))
        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.suffix(2) == ["--", "https://youtu.be/abc"])
        #expect(arguments.contains("deno:" + engine.deno.path))
    }

    @Test func mp3UsesConstantBitrate() {
        let arguments = YtDlpArguments(engine: engine)
            .extract(URL(string: "https://youtu.be/abc")!, format: .mp3(.kbps320), workDirectory: URL(filePath: "/tmp/w"))
        #expect(arguments.containsPair(["--audio-format", "mp3"]))
        #expect(arguments.containsPair(["--audio-quality", "320K"]))
        #expect(arguments.containsPair(["--paths", "home:/tmp/w"]))
        #expect(arguments.contains("--embed-metadata"))
    }

    @Test(arguments: [OutputFormat.wav, .flac])
    func losslessFormatsHaveNoQuality(_ format: OutputFormat) {
        let arguments = YtDlpArguments(engine: engine)
            .extract(URL(string: "https://youtu.be/abc")!, format: format, workDirectory: URL(filePath: "/tmp/w"))
        #expect(arguments.containsPair(["--audio-format", format.fileExtension ?? ""]))
        #expect(!arguments.contains("--audio-quality"))
    }

    @Test func mp4PicksH264AndMergesWithoutAudioExtraction() {
        let arguments = YtDlpArguments(engine: engine)
            .extract(URL(string: "https://youtu.be/abc")!, format: .video(.mp4, .p720), workDirectory: URL(filePath: "/tmp/w"))
        #expect(arguments.containsPair(["--format", "bv[vcodec^=avc1][protocol!*=m3u8]+ba[ext=m4a][protocol!*=m3u8]/b[ext=mp4][protocol!*=m3u8]"]))
        #expect(arguments.containsPair(["--format-sort", "res:720"]))
        #expect(arguments.containsPair(["--merge-output-format", "mp4"]))
        #expect(!arguments.contains("--extract-audio"))
        #expect(!arguments.contains("--audio-format"))
        #expect(arguments.contains("--embed-metadata"))
    }

    @Test func bestQualityHasNoResolutionLimitAndFlexibleContainer() {
        let arguments = YtDlpArguments(engine: engine)
            .extract(URL(string: "https://youtu.be/abc")!, format: .video(.best, .best), workDirectory: URL(filePath: "/tmp/w"))
        #expect(arguments.containsPair(["--format", "bv[protocol!*=m3u8]+ba[protocol!*=m3u8]/b[protocol!*=m3u8]"]))
        #expect(!arguments.contains("--format-sort"))
        #expect(arguments.containsPair(["--merge-output-format", "mp4/webm/mkv"]))
        #expect(!arguments.contains("--extract-audio"))
    }

    @Test func bestQualityWithResolutionSortsByIt() {
        let arguments = YtDlpArguments(engine: engine)
            .extract(URL(string: "https://youtu.be/abc")!, format: .video(.best, .p1440), workDirectory: URL(filePath: "/tmp/w"))
        #expect(arguments.containsPair(["--format-sort", "res:1440"]))
    }

    @Test func videoFormatErrors() {
        let missing = ["ERROR: [youtube] abc: Requested format is not available. Use --list-formats"]
        #expect(YtDlpErrorMapper.map(stderr: missing, video: true) == .noVideoFormat)
        #expect(YtDlpErrorMapper.map(stderr: missing) == .noAudioFormat)
        // 형식이 하나도 없는 영상은 포맷을 바꿔도 안 되므로 영상 포맷 문구가 아니다.
        #expect(YtDlpErrorMapper.map(stderr: ["ERROR: [youtube] abc: No video formats found!"], video: true) == .noAudioFormat)
    }

    @Test func fileExtensions() {
        #expect(OutputFormat.video(.mp4, .p1080).fileExtension == "mp4")
        #expect(OutputFormat.video(.best, .best).fileExtension == nil)  // 결과 파일 확장자를 쓴다
        #expect(OutputFormat.flac.fileExtension == "flac")
    }
}

struct VideoProgressTests {
    @Test(arguments: [
        ("avc1.640028 none", DownloadPart.video),
        ("none mp4a.40.2", DownloadPart.audio),
        ("avc1.42001E mp4a.40.2", DownloadPart.combined),
    ])
    func downloadPartFromCodecs(_ codecs: String, _ part: DownloadPart) {
        #expect(
            ProgressParser.parse("[stow:download] downloading 50 100 NA NA NA \(codecs)")
                == .progress(.downloading(fraction: 0.5, bytesPerSecond: nil, secondsRemaining: nil, part: part))
        )
    }

    @Test func mergerIsMerging() {
        #expect(ProgressParser.parse("[stow:postprocess] started Merger") == .progress(.merging))
    }

    @Test func progressTextNamesThePart() {
        let video = OutputFormat.video(.mp4, .p1080)
        #expect(ProgressText.text(for: .downloading(fraction: 0.42, bytesPerSecond: nil, secondsRemaining: 8, part: .video), format: video)
            == "영상 받는 중 42% · 약 8초 남음")
        #expect(ProgressText.text(for: .downloading(fraction: 0.5, bytesPerSecond: nil, secondsRemaining: nil, part: .audio), format: video)
            == "오디오 받는 중 50%")
        #expect(ProgressText.text(for: .merging, format: video) == "영상과 오디오를 합치는 중…")
        // 오디오 추출은 지금처럼 "다운로드 중"
        #expect(ProgressText.text(for: .downloading(fraction: 0.5, bytesPerSecond: nil, secondsRemaining: nil, part: .audio), format: .mp3(.kbps320))
            == "다운로드 중 50%")
    }

    @Test func displayNamesAndActions() {
        #expect(OutputFormat.video(.mp4, .p1080).displayName == "MP4 1080p")
        #expect(OutputFormat.video(.best, .best).displayName == "최고 화질")
        #expect(OutputFormat.video(.best, .p1440).displayName == "최고 화질 1440p")
        #expect(OutputFormat.video(.mp4, .p720).actionTitle == "MP4로 받기")
        #expect(OutputFormat.video(.best, .best).actionTitle == "최고 화질로 받기")
        #expect(OutputFormat.flac.actionTitle == "FLAC으로 추출")
        #expect(OutputFormat.mp3(.kbps192).actionTitle == "MP3로 추출")
    }
}

struct FileNamingTests {
    @Test(arguments: [
        ("평범한 제목", "평범한 제목"),
        ("AC/DC: Live", "AC-DC- Live"),
        ("  앞뒤   공백\n줄바꿈\t탭  ", "앞뒤 공백 줄바꿈 탭"),
        ("...숨김 파일", "숨김 파일"),
        ("", "오디오"),
        ("///", "---"),
        ("...", "오디오"),
        (". .숨김", "숨김"),  // 점과 공백이 섞여도 숨김 파일이 되지 않는다
        (" . . ", "오디오"),
    ])
    func sanitizes(_ title: String, _ expected: String) {
        #expect(FileNaming.sanitize(title) == expected)
    }

    @Test func truncatesByBytesWithoutBreakingCharacters() {
        let name = FileNaming.sanitize(String(repeating: "가👍🏽", count: 100))
        #expect(name.utf8.count <= FileNaming.maxBytes)
        #expect(name.hasPrefix("가👍🏽가"))
        #expect(name.unicodeScalars.last != "\u{1F44D}")  // 피부색 조합 중간에서 끊기지 않음
    }
}

private extension Array where Element == String {
    func containsPair(_ pair: [String]) -> Bool {
        indices.dropLast().contains { self[$0] == pair[0] && self[$0 + 1] == pair[1] }
    }
}
