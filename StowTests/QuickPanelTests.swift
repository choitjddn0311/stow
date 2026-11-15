import Foundation
import Testing
@testable import Stow

private let panelOutputDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appending(path: "stow-panel-tests", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private let videoURL = "https://www.youtube.com/watch?v=abc123"

private let panelMetadata = VideoMetadata(
    id: "abc123", title: "패널 곡", duration: 200, uploader: "채널",
    webpageURL: URL(string: videoURL)
)

private let samplePanelPlaylist = Playlist(id: "PL1", title: "패널 재생목록", entries: [
    PlaylistEntry(id: "aaaaaaaaaaa", title: "첫 곡", duration: 100),
    PlaylistEntry(id: "bbbbbbbbbbb", title: "[Deleted video]", duration: nil),
])

@MainActor
final class FakeClipboard: ClipboardReading {
    var changeCount = 1
    var text: String?
    private(set) var readCount = 0
    /// 읽는 도중에 일어나는 일(패널 닫기, 클립보드 바뀜 등)을 흉내 낸다.
    var duringRead: (() -> Void)?

    func webURLText() async -> String? {
        readCount += 1
        let result = text
        duringRead?()
        return result
    }

    func set(_ text: String?) {
        self.text = text
        changeCount += 1
    }
}

/// 빠른 추출 패널: 클립보드 자동 입력, Return으로 추가, 추가 후 닫기.
@MainActor
struct QuickPanelModelTests {
    private struct Fixture {
        let panel: QuickPanelModel
        let queue: ExtractQueue
        let engine: FakeEngine
        let clipboard: FakeClipboard
        let closeCount: () -> Int
    }

    private func makePanel(engine: FakeEngine, clipboard: FakeClipboard = FakeClipboard()) -> Fixture {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-panel-test-\(UUID().uuidString)")!)
        settings.outputDirectory = panelOutputDirectory
        let queue = ExtractQueue(engine: engine, notifier: SilentNotifier())
        // 자동 불러오기 지연을 길게 두어, 테스트가 부른 fetch만 돌게 한다.
        let extract = ExtractViewModel(settings: settings, engine: engine, queue: queue, autoFetchDelay: .seconds(60))
        let panel = QuickPanelModel(extract: extract, clipboard: clipboard)
        var closes = 0
        panel.onClose = { closes += 1 }
        return Fixture(panel: panel, queue: queue, engine: engine, clipboard: clipboard, closeCount: { closes })
    }

    /// 포맷·폴더 칩: 바꾼 값이 메인 창과 같은 설정에 남는다.
    @Test func chipsChangeSharedSettings() {
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))))
        let settings = f.panel.extract.settings

        f.panel.select(.mp3(.kbps192))
        #expect(settings.format == .mp3(.kbps192))
        f.panel.select(.flac)
        #expect(settings.format == .flac)
        #expect(f.panel.extract.addButtonTitle.contains("FLAC"))

        let other = URL(filePath: "/tmp/stow-panel-other", directoryHint: .isDirectory)
        f.panel.selectOutputDirectory(other)
        #expect(settings.outputDirectory == other)
        #expect(f.closeCount() == 0)  // 설정을 바꿔도 패널은 닫히지 않는다
    }

    /// "다른 폴더…": 고르면 설정에 반영, 취소하면 그대로.
    @Test func chooseOtherFolder() {
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))))
        let settings = f.panel.extract.settings
        let picked = URL(filePath: "/tmp/stow-panel-picked", directoryHint: .isDirectory)
        var offered: URL?

        f.panel.onChooseFolder = { current in offered = current; return nil }
        f.panel.chooseOtherFolder()
        #expect(offered == panelOutputDirectory)  // 지금 폴더에서 시작한다
        #expect(settings.outputDirectory == panelOutputDirectory)

        f.panel.onChooseFolder = { _ in picked }
        f.panel.chooseOtherFolder()
        #expect(settings.outputDirectory == picked)
        #expect(f.closeCount() == 0)
    }

    @Test func clipboardYouTubeURLIsFilledAndFetched() async {
        let clipboard = FakeClipboard()
        clipboard.set("  \(videoURL)\n")
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)

        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText == videoURL)
        await f.panel.extract.waitForTask()
        #expect(f.panel.extract.state == .video(panelMetadata))
        #expect(f.engine.fetchCount == 1)
    }

    @Test func nonYouTubeClipboardIsIgnored() async {
        let clipboard = FakeClipboard()
        clipboard.set("https://example.com/watch?v=1")
        let f = makePanel(engine: FakeEngine(), clipboard: clipboard)

        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText.isEmpty)
        #expect(f.panel.extract.state == .idle)
        #expect(f.engine.fetchCount == 0)
    }

    @Test func returnOnLoadedVideoAddsToQueueAndCloses() async {
        let clipboard = FakeClipboard()
        clipboard.set(videoURL)
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)
        await f.panel.prepareForPresentation()
        await f.panel.extract.waitForTask()

        f.panel.submit()
        #expect(f.queue.items.map(\.title) == ["패널 곡"])
        #expect(f.closeCount() == 1)
        #expect(f.panel.extract.urlText.isEmpty)
        await f.queue.waitUntilIdle()
    }

    @Test func returnWhileFetchingAddsWhenLoaded() async {
        let gate = AsyncGate()
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata)), fetchGate: gate))
        f.panel.extract.urlText = videoURL
        f.panel.extract.fetch()
        #expect(f.panel.extract.isFetching)

        f.panel.submit()
        #expect(f.panel.addWhenReady)
        #expect(f.queue.items.isEmpty)

        // 화면이 그려지지 않아도 모델이 조회 끝을 기다렸다가 추가한다.
        gate.open()
        await f.panel.waitForPendingAdd()
        #expect(f.queue.items.count == 1)
        #expect(f.closeCount() == 1)
        #expect(!f.panel.addWhenReady)
        await f.queue.waitUntilIdle()
    }

    @Test func returnOnTypedURLFetchesThenAdds() async {
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))))
        f.panel.extract.urlText = videoURL

        f.panel.submit()
        #expect(f.panel.addWhenReady)
        await f.panel.waitForPendingAdd()
        #expect(f.queue.items.count == 1)
        #expect(f.closeCount() == 1)
        await f.queue.waitUntilIdle()
    }

    @Test func failedFetchDoesNotAddOrClose() async {
        let f = makePanel(engine: FakeEngine(media: .failure(.network)))
        f.panel.extract.urlText = videoURL
        f.panel.submit()
        await f.panel.waitForPendingAdd()

        #expect(f.panel.extract.state == .failed(.network))
        #expect(!f.panel.addWhenReady)
        #expect(f.queue.items.isEmpty)
        #expect(f.closeCount() == 0)
    }

    @Test func invalidURLFailsImmediately() async {
        let f = makePanel(engine: FakeEngine())
        f.panel.extract.urlText = "https://example.com/x"
        f.panel.submit()
        #expect(f.panel.extract.state == .failed(.invalidURL))
        #expect(!f.panel.addWhenReady)
        #expect(f.engine.fetchCount == 0)
    }

    @Test func sameClipboardIsNotRefilledAfterAdding() async {
        let clipboard = FakeClipboard()
        clipboard.set(videoURL)
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)
        await f.panel.prepareForPresentation()
        await f.panel.extract.waitForTask()
        f.panel.submit()
        await f.queue.waitUntilIdle()

        // 같은 클립보드로 다시 열면 비어 있고, 클립보드를 읽지도 않는다.
        let readsBefore = clipboard.readCount
        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText.isEmpty)
        #expect(clipboard.readCount == readsBefore)

        // 클립보드가 바뀌면 다시 채운다.
        clipboard.set("https://youtu.be/xyz789")
        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText == "https://youtu.be/xyz789")
        await f.panel.extract.waitForTask()
    }

    @Test func dismissedWithoutAddingRefillsNextTime() async {
        let clipboard = FakeClipboard()
        clipboard.set(videoURL)
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)
        await f.panel.prepareForPresentation()
        await f.panel.extract.waitForTask()
        f.panel.dismiss()
        #expect(f.closeCount() == 1)

        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText == videoURL)
        await f.panel.extract.waitForTask()
    }

    @Test func dismissCancelsFetch() async {
        let gate = AsyncGate()
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata)), fetchGate: gate))
        f.panel.extract.urlText = videoURL
        f.panel.submit()
        f.panel.dismiss()
        await f.panel.extract.waitForTask()

        #expect(f.panel.extract.state == .idle)
        #expect(!f.panel.addWhenReady)
        #expect(f.queue.items.isEmpty)
    }

    @Test func playlistAddsAvailableEntriesIntoSubfolder() async {
        let playlist = Playlist(id: "PL1", title: "내 재생목록", entries: [
            PlaylistEntry(id: "aaaaaaaaaaa", title: "첫 곡", duration: 100),
            PlaylistEntry(id: "bbbbbbbbbbb", title: "[Private video]", duration: nil),
            PlaylistEntry(id: "ccccccccccc", title: "셋째 곡", duration: 300),
        ])
        let f = makePanel(engine: FakeEngine(media: .success(.playlist(playlist)), extractGate: AsyncGate()))
        f.panel.extract.urlText = "https://www.youtube.com/playlist?list=PL1"
        f.panel.submit()
        await f.panel.waitForPendingAdd()

        #expect(f.queue.items.map(\.title) == ["첫 곡", "셋째 곡"])
        #expect(f.queue.items.allSatisfy { $0.subfolder == "내 재생목록" })
        #expect(f.closeCount() == 1)
        f.queue.cancelAll()
        await f.queue.waitUntilIdle()
    }

    @Test func openInMainWindowHandsOverLoadedPlaylist() async {
        let playlistURL = "https://www.youtube.com/playlist?list=PL1"
        let f = makePanel(engine: FakeEngine(media: .success(.playlist(samplePanelPlaylist))))
        var opened: [(String, Playlist?)] = []
        f.panel.onOpenInMainWindow = { opened.append(($0, $1)) }
        f.panel.extract.urlText = playlistURL
        f.panel.extract.fetch()
        await f.panel.extract.waitForTask()

        f.panel.openInMainWindow()
        #expect(opened.count == 1)
        #expect(opened.first?.0 == playlistURL)
        #expect(opened.first?.1 == samplePanelPlaylist)
        #expect(f.closeCount() == 1)
    }

    @Test func closingWhileReadingClipboardDoesNotFill() async {
        let clipboard = FakeClipboard()
        clipboard.set(videoURL)
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)
        clipboard.duringRead = { f.panel.dismiss() }

        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText.isEmpty)
        #expect(f.engine.fetchCount == 0)
    }

    @Test func clipboardChangedWhileReadingIsNotFilled() async {
        let clipboard = FakeClipboard()
        clipboard.set(videoURL)
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata))), clipboard: clipboard)
        clipboard.duringRead = { clipboard.set("https://youtu.be/xyz789") }

        await f.panel.prepareForPresentation()
        #expect(f.panel.extract.urlText.isEmpty)
        #expect(f.engine.fetchCount == 0)
    }

    @Test func dismissCancelsPendingAdd() async {
        let gate = AsyncGate()
        let f = makePanel(engine: FakeEngine(media: .success(.video(panelMetadata)), fetchGate: gate))
        f.panel.extract.urlText = videoURL
        f.panel.submit()
        #expect(f.panel.addWhenReady)
        f.panel.dismiss()
        gate.open()
        await f.panel.extract.waitForTask()
        await f.panel.waitForPendingAdd()

        #expect(f.queue.items.isEmpty)
        #expect(!f.panel.addWhenReady)
    }
}

/// 패널이 불러온 재생목록을 메인 창이 다시 조회하지 않고 받는다.
@MainActor
struct ShowLoadedPlaylistTests {
    @Test func showsPlaylistWithoutFetchingAndKeepsIt() async throws {
        let engine = FakeEngine(media: .success(.video(panelMetadata)))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-panel-test-\(UUID().uuidString)")!)
        let queue = ExtractQueue(engine: engine, notifier: SilentNotifier())
        let model = ExtractViewModel(settings: settings, engine: engine, queue: queue, autoFetchDelay: .milliseconds(20))
        // 메인 창에 다른 영상이 불러와 있던 상태
        model.urlText = videoURL
        model.fetch()
        await model.waitForTask()

        let playlistURL = "https://www.youtube.com/playlist?list=PL1"
        model.showLoaded(samplePanelPlaylist, urlText: playlistURL)
        #expect(model.urlText == playlistURL)
        #expect(model.state == .playlist(samplePanelPlaylist))
        #expect(model.selectedEntryIDs == ["aaaaaaaaaaa"])

        // 자동 불러오기가 돌지 않는다.
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.fetchCount == 1)
        #expect(model.state == .playlist(samplePanelPlaylist))
        // Return은 다시 불러오지 않고 대기열에 넣는다.
        model.submit()
        #expect(queue.items.map(\.title) == ["첫 곡"])
        queue.cancelAll()
        await queue.waitUntilIdle()
    }
}

struct ClipboardURLTests {
    @Test func acceptsYouTubeVideoAndPlaylistURLs() {
        #expect(ClipboardURL.youTubeText(from: " https://youtu.be/abc123 \n") == "https://youtu.be/abc123")
        #expect(ClipboardURL.youTubeText(from: "https://www.youtube.com/playlist?list=PL1") != nil)
    }

    @Test func rejectsOtherText() {
        #expect(ClipboardURL.youTubeText(from: nil) == nil)
        #expect(ClipboardURL.youTubeText(from: "") == nil)
        #expect(ClipboardURL.youTubeText(from: "안녕하세요") == nil)
        #expect(ClipboardURL.youTubeText(from: "https://example.com/watch?v=1") == nil)
        #expect(ClipboardURL.youTubeText(from: "https://www.youtube.com/@channel") == nil)
        // 주소 여러 개(여러 줄)는 하나로 보지 않는다.
        #expect(ClipboardURL.youTubeText(from: "https://youtu.be/a\nhttps://youtu.be/b") == nil)
    }
}
