import AppKit
import SwiftUI
import Testing
@testable import Stow

/// 주요 화면 상태를 실제 앱과 같은 방식(창 안의 `NSHostingView`)으로 그려 본다.
///
/// - 항상: 각 상태가 그려지는지(빈 화면이 아닌지), 최소 창 폭에서도 내용이 창 밖으로 나가지 않는지 확인한다.
/// - `TEST_RUNNER_STOW_SNAPSHOT_DIR=<폴더>`를 주면 그린 화면을 PNG로 남긴다(눈으로 레이아웃을 확인할 때).
///
///       TEST_RUNNER_STOW_SNAPSHOT_DIR=/tmp/stow-shots xcodebuild ... test -only-testing:StowTests/UISnapshotTests
@MainActor
struct UISnapshotTests {
    private static let video = VideoMetadata(
        id: "abc12345678", title: "여름밤의 드라이브 (Official Audio) — 아주 긴 제목이 두 줄로 넘어가는 경우를 확인하기 위한 영상 제목",
        duration: 325, uploader: "Stow 뮤직", webpageURL: URL(string: "https://www.youtube.com/watch?v=abc12345678")
    )

    private static let playlist = Playlist(
        id: "PL1", title: "작업할 때 듣는 재생목록",
        entries: [
            PlaylistEntry(id: "aaaaaaaaaaa", title: "첫 번째 곡", duration: 185),
            PlaylistEntry(id: "bbbbbbbbbbb", title: "[Private video]", duration: nil),
            PlaylistEntry(id: "ccccccccccc", title: "세 번째 곡 — 제목이 아주 길어서 한 줄에 다 들어가지 않는 경우를 확인하는 곡 (Live at Seoul 2026)", duration: 3723),
        ],
        totalCount: 620
    )

    private static let validURL = "https://www.youtube.com/watch?v=abc12345678"

    /// 메인 창: 상태 × (기본 폭·최소 폭) × (라이트·다크)
    @Test(arguments: MainState.allCases)
    func mainWindowRenders(state: MainState) async throws {
        for (width, height) in [(600.0, 900.0), (560.0, 500.0)] {
            for dark in [false, true] {
                let fixture = try await Fixture.make(state)
                let root = RootView(model: fixture.model, settings: fixture.settings)
                let image = try await Self.render(root, width: width, height: height, dark: dark)
                #expect(Self.distinctColorCount(in: image) > 10, "\(state) \(Int(width)) dark=\(dark): 빈 화면")
                Self.save(image, name: "main-\(state.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                await fixture.tearDown()
            }
        }
    }

    /// 빠른 추출 패널: 상태 × (라이트·다크)
    @Test(arguments: [MainState.idle, .fetching, .video, .playlist, .failed, .videoMode])
    func quickPanelRenders(state: MainState) async throws {
        for dark in [false, true] {
            let fixture = try await Fixture.make(state)
            let panel = QuickPanelView(model: QuickPanelModel(extract: fixture.model, clipboard: EmptyClipboard()))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: QuickPanelView.cornerRadius))
                .padding(20)
            let image = try await Self.render(
                panel, width: QuickPanelView.width + 40, height: QuickPanelView.height + 40, dark: dark
            )
            #expect(Self.distinctColorCount(in: image) > 10, "\(state) dark=\(dark): 빈 화면")
            Self.save(image, name: "panel-\(state.rawValue)-\(dark ? "dark" : "light")")
            await fixture.tearDown()
        }
    }

    /// 엔진을 찾지 못했을 때, 이용 고지, 라이선스 창
    @Test func otherScreensRender() async throws {
        let settings = AppSettings(defaults: InMemoryDefaults())
        settings.acceptedNoticeVersion = UsageNotice.version
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let broken = RootView(model: nil, settings: settings, engineError: .missingComponent("bin/yt-dlp"))
            let brokenImage = try await Self.render(broken, width: 600, height: 540, dark: dark)
            #expect(Self.distinctColorCount(in: brokenImage) > 10, "엔진 없음 화면이 비어 있음")
            Self.save(brokenImage, name: "engine-missing-\(suffix)")

            let fresh = AppSettings(defaults: InMemoryDefaults())
            let notice = RootView(model: nil, settings: fresh)
            let noticeImage = try await Self.render(notice, width: 600, height: 540, dark: dark)
            #expect(Self.distinctColorCount(in: noticeImage) > 10, "이용 고지 화면이 비어 있음")
            Self.save(noticeImage, name: "notice-\(suffix)")

            let licenses = try await Self.render(OpenSourceLicensesView(), width: 760, height: 540, dark: dark)
            #expect(Self.distinctColorCount(in: licenses) > 10)
            Self.save(licenses, name: "licenses-\(suffix)")
        }
    }

    @Test func retryIsOfferedOnlyForTransientErrors() {
        #expect(EngineError.network.isWorthRetrying)
        #expect(EngineError.unknown("x").isWorthRetrying)
        #expect(!EngineError.invalidURL.isWorthRetrying)
        #expect(!EngineError.privateVideo.isWorthRetrying)
        #expect(!EngineError.channelNotSupported.isWorthRetrying)
        #expect(!EngineError.launchFailed(executable: "yt-dlp", code: 13).isWorthRetrying)
        #expect(!EngineError.missingComponent("bin").isWorthRetrying)
    }

    @Test func spokenDuration() {
        #expect(DurationFormat.spoken(from: 325) == "5분 25초")
        #expect(DurationFormat.spoken(from: 3723) == "1시간 2분 3초")
        #expect(DurationFormat.spoken(from: 60) == "1분")
        #expect(DurationFormat.spoken(from: 0) == "0초")
    }

    // MARK: - 상태 만들기

    enum MainState: String, CaseIterable, Sendable {
        case idle, fetching, video, playlist, failed, queue, paused
        /// 종류를 영상으로 바꾼 상태 + 영상 항목을 받는 대기열
        case videoMode
    }

    private struct Fixture {
        let model: ExtractViewModel
        let settings: AppSettings
        let engine: SnapshotEngine

        @MainActor
        static func make(_ state: MainState) async throws -> Fixture {
            let defaults = InMemoryDefaults()
            let settings = AppSettings(defaults: defaults)
            settings.acceptedNoticeVersion = UsageNotice.version
            let directory = FileManager.default.temporaryDirectory.appending(path: "stow-snapshots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            settings.outputDirectory = directory

            let engine = SnapshotEngine()
            let queue = ExtractQueue(engine: engine, notifier: SilentNotifier())
            let model = ExtractViewModel(settings: settings, engine: engine, queue: queue)
            let options = ExtractOptions(format: .mp3(.kbps320), outputDirectory: directory)
            func item(_ title: String) -> ExtractQueue.Item {
                ExtractQueue.Item(url: URL(string: "https://youtu.be/abc12345678")!, title: title, options: options)
            }

            switch state {
            case .idle:
                break
            case .fetching:
                engine.media = nil  // 끝나지 않는 조회
                model.urlText = validURL
                model.fetch()
            case .video:
                engine.media = .success(.video(video))
                model.urlText = validURL
                model.fetch()
                await model.waitForTask()
            case .playlist:
                engine.media = .success(.playlist(playlist))
                model.urlText = "https://www.youtube.com/playlist?list=PL1"
                model.fetch()
                await model.waitForTask()
            case .failed:
                engine.media = .failure(.network)
                model.urlText = validURL
                model.fetch()
                await model.waitForTask()
            case .queue:
                engine.media = .success(.video(video))
                model.urlText = validURL
                model.fetch()
                await model.waitForTask()
                let cancelled = item("취소한 곡")
                queue.add([
                    item("done 완료한 곡"), item("fail 실패한 곡 — 제목이 길어서 잘리는 경우를 확인하는 아주 긴 제목의 곡입니다"),
                    item("run 추출 중인 곡"), item("대기 중인 곡"), cancelled,
                ])
                queue.cancel(cancelled.id)
                for _ in 0..<300 where queue.items[2].progress.value == nil {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(queue.items[2].status == .running, "추출 중 상태를 만들지 못함")
                #expect(queue.completedCount == 1 && queue.failedCount == 1, "완료·실패 상태를 만들지 못함")
            case .videoMode:
                engine.media = .success(.video(video))
                model.urlText = validURL
                model.fetch()
                await model.waitForTask()
                settings.select(.video(.mp4, .p1080))
                let videoOptions = ExtractOptions(format: .video(.best, .p2160), outputDirectory: directory)
                queue.add([
                    item("done 완료한 곡"),
                    ExtractQueue.Item(url: URL(string: "https://youtu.be/abc12345678")!, title: "run 받는 중인 영상", options: videoOptions),
                    ExtractQueue.Item(url: URL(string: "https://youtu.be/abc12345678")!, title: "대기 중인 영상", options: videoOptions),
                ])
                for _ in 0..<300 where queue.items[1].progress.value == nil {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(queue.items[1].status == .running, "영상 받는 중 상태를 만들지 못함")
            case .paused:
                queue.add([item("blocked 막힌 곡"), item("대기 중인 곡")])
                for _ in 0..<300 where !queue.isPaused {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(queue.isPaused, "일시 정지 상태를 만들지 못함")
            }
            return Fixture(model: model, settings: settings, engine: engine)
        }

        @MainActor
        func tearDown() async {
            model.cancelFetch()
            await model.queue.cancelAndWait()
        }
    }

    // MARK: - 그리기

    private static func render(_ view: some View, width: CGFloat, height: CGFloat, dark: Bool) async throws -> CGImage {
        // 실제 창처럼 창 배경색을 깐다(배경이 없는 화면은 투명 위에 그려져 다크 모드 글자가 안 보인다).
        let hosting = NSHostingView(
            rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
        )
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        // 화면에 띄우지 않는 창에 넣어 실제 창과 같은 배율·모양으로 그린다.
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = frame
        // 상태 반영·레이아웃이 끝나길 잠깐 기다린다.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.contentView = nil
        window.close()
        return try #require(bitmap.cgImage)
    }

    private static func save(_ image: CGImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["STOW_SNAPSHOT_DIR"], !directory.isEmpty else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: folder.appending(path: "\(name).png"))
    }

    private static func distinctColorCount(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: pixels.count, by: 4 * 7) {
            colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
        }
        return colors.count
    }
}

/// 제목 앞머리로 추출 결과를 정하는 가짜 엔진: "done"은 완료, "fail"은 실패, "blocked"는 유튜브 차단,
/// "run"은 진행률 42%에서 취소될 때까지 머문다. 그 밖의 제목도 취소될 때까지 머문다.
private final class SnapshotEngine: AudioExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var _media: Result<FetchedMedia, EngineError>?

    /// nil이면 조회가 취소될 때까지 끝나지 않는다.
    var media: Result<FetchedMedia, EngineError>? {
        get { lock.withLock { _media } }
        set { lock.withLock { _media = newValue } }
    }

    func fetchMedia(for url: URL) async throws -> FetchedMedia {
        guard let media else {
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
        return try media.get()
    }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        if fileName.hasPrefix("done") {
            return options.outputDirectory.appending(path: "\(fileName).\(options.format.fileExtension ?? "mp4")")
        }
        if fileName.hasPrefix("fail") { throw EngineError.network }
        if fileName.hasPrefix("blocked") { throw EngineError.blockedByYouTube }
        // 영상은 오디오 스트림을 받는 단계(영상은 이미 받음)로 보여 준다.
        progress(.downloading(
            fraction: 0.42, bytesPerSecond: 1_200_000, secondsRemaining: 18,
            part: options.format.isVideo ? .audio : .combined
        ))
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}

private struct EmptyClipboard: ClipboardReading {
    var changeCount: Int { 0 }
    func webURLText() async -> String? { nil }
}
