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

@MainActor
final class FakeClipboard: ClipboardReading {
    var changeCount = 1
    var text: String?
    private(set) var readCount = 0

    func webURLText() async -> String? {
        readCount += 1
        return text
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

        gate.open()
        await f.panel.extract.waitForTask()
        f.panel.stageDidChange()  // 화면이 단계 변화를 알린다
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
        await f.panel.extract.waitForTask()
        f.panel.stageDidChange()
        #expect(f.queue.items.count == 1)
        #expect(f.closeCount() == 1)
        await f.queue.waitUntilIdle()
    }

    @Test func failedFetchDoesNotAddOrClose() async {
        let f = makePanel(engine: FakeEngine(media: .failure(.network)))
        f.panel.extract.urlText = videoURL
        f.panel.submit()
        await f.panel.extract.waitForTask()
        f.panel.stageDidChange()

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
        await f.panel.extract.waitForTask()
        f.panel.stageDidChange()

        #expect(f.queue.items.map(\.title) == ["첫 곡", "셋째 곡"])
        #expect(f.queue.items.allSatisfy { $0.subfolder == "내 재생목록" })
        #expect(f.closeCount() == 1)
        f.queue.cancelAll()
        await f.queue.waitUntilIdle()
    }

    @Test func openInMainWindowPassesURLAndCloses() async {
        let f = makePanel(engine: FakeEngine())
        var opened: [String] = []
        f.panel.onOpenInMainWindow = { opened.append($0) }
        f.panel.extract.urlText = "https://www.youtube.com/playlist?list=PL1"

        f.panel.openInMainWindow()
        #expect(opened == ["https://www.youtube.com/playlist?list=PL1"])
        #expect(f.closeCount() == 1)
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
