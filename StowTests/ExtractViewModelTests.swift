import Foundation
import Testing
@testable import Stow

/// 저장 폴더가 실제로 있어야 하므로(대기열이 확인함) 테스트용 폴더를 만든다.
private let testOutputDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appending(path: "stow-vm-tests", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private let sampleMetadata = VideoMetadata(
    id: "abc123", title: "테스트 곡", duration: 200, uploader: "채널",
    webpageURL: URL(string: "https://www.youtube.com/watch?v=abc123")
)

private let samplePlaylist = Playlist(id: "PL1", title: "내 재생목록", entries: [
    PlaylistEntry(id: "aaaaaaaaaaa", title: "첫 곡", duration: 100),
    PlaylistEntry(id: "bbbbbbbbbbb", title: "[Private video]", duration: nil),
    PlaylistEntry(id: "ccccccccccc", title: "셋째 곡", duration: 300),
])

@MainActor
private func makeSettings() -> AppSettings {
    let settings = AppSettings(defaults: InMemoryDefaults())
    settings.outputDirectory = testOutputDirectory
    return settings
}

/// 주소 입력·불러오기·재생목록 선택·대기열에 추가.
@MainActor
struct ExtractViewModelTests {
    private let validURL = "https://www.youtube.com/watch?v=abc123"

    private func makeModel(
        _ engine: FakeEngine, autoFetchDelay: Duration = .milliseconds(500)
    ) -> (ExtractViewModel, ExtractQueue, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let queue = ExtractQueue(engine: engine, notifier: notifier)
        let model = ExtractViewModel(settings: makeSettings(), engine: engine, queue: queue, autoFetchDelay: autoFetchDelay)
        return (model, queue, notifier)
    }

    private func loaded(_ engine: FakeEngine) async -> (ExtractViewModel, ExtractQueue, RecordingNotifier) {
        let result = makeModel(engine)
        result.0.urlText = validURL
        result.0.fetch()
        await result.0.waitForTask()
        return result
    }

    /// 조건이 맞을 때까지(최대 3초) 기다린다.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 불러오기

    @Test func invalidURLFailsWithoutCallingEngine() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.urlText = "https://example.com/watch?v=1"
        model.fetch()
        #expect(model.state == .failed(.invalidURL))
        #expect(engine.fetchCount == 0)
    }

    @Test func channelURLIsRejected() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.urlText = "https://www.youtube.com/@channel"
        model.fetch()
        #expect(model.state == .failed(.channelNotSupported))
    }

    @Test func fetchShowsVideo() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)))
        let (model, _, _) = makeModel(engine)
        model.urlText = "  \(validURL)\n"
        model.fetch()
        #expect(model.state == .fetching)
        await model.waitForTask()
        #expect(model.state == .video(sampleMetadata))
        #expect(model.canAddToQueue)
        #expect(model.pendingAddCount == 1)
    }

    @Test func fetchErrorIsShownInline() async {
        let (model, _, _) = await loaded(FakeEngine(media: .failure(.privateVideo)))
        #expect(model.state == .failed(.privateVideo))
        #expect(model.retryAlert == nil)
    }

    @Test func blockedFetchShowsRetryAlert() async {
        let engine = FakeEngine(media: .failure(.blockedByYouTube))
        let (model, _, _) = await loaded(engine)
        #expect(model.retryAlert != nil)
        engine.mediaResult = .success(.video(sampleMetadata))
        model.retryFetch()
        await model.waitForTask()
        #expect(model.state == .video(sampleMetadata))
        #expect(engine.fetchCount == 2)
    }

    @Test func cancelDuringFetchReturnsToIdle() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)), fetchGate: AsyncGate())
        let (model, _, _) = makeModel(engine)
        model.urlText = validURL
        model.fetch()
        #expect(model.state == .fetching)
        model.cancelFetch()
        await model.waitForTask()
        #expect(model.state == .idle)
    }

    // MARK: - 자동 불러오기

    @Test func pastingURLLoadsAutomatically() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)))
        let (model, _, _) = makeModel(engine, autoFetchDelay: .milliseconds(30))
        model.urlText = validURL
        #expect(model.state == .idle)
        await waitUntil { model.state == .video(sampleMetadata) }
        #expect(model.state == .video(sampleMetadata))
        #expect(engine.fetchCount == 1)
    }

    @Test func typingQuicklyFetchesOnlyTheLastText() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)))
        let (model, _, _) = makeModel(engine, autoFetchDelay: .milliseconds(30))
        model.urlText = "https://youtu.be/a"
        model.urlText = "https://youtu.be/ab"
        model.urlText = "https://youtu.be/abc"
        await waitUntil { model.state == .video(sampleMetadata) }
        #expect(engine.fetchedURLs == [URL(string: "https://youtu.be/abc")!])
    }

    @Test func invalidTextShowsErrorAfterPause() async {
        let (model, _, _) = makeModel(FakeEngine(), autoFetchDelay: .milliseconds(30))
        model.urlText = "https://example.com/watch?v=1"
        await waitUntil { model.state != .idle }
        #expect(model.state == .failed(.invalidURL))
        model.urlText = ""
        #expect(model.state == .idle)
    }

    @Test func editingURLAfterLoadingResets() async {
        let (model, _, _) = await loaded(FakeEngine(media: .success(.video(sampleMetadata))))
        model.urlText = "https://youtu.be/other"
        #expect(model.state == .idle)
        #expect(!model.canAddToQueue)
    }

    // MARK: - 대기열에 추가

    @Test func addingVideoQueuesWithSettingsSnapshotAndClearsInput() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)), extractGate: AsyncGate())
        let (model, queue, _) = await loaded(engine)
        model.settings.formatKind = .mp3
        model.settings.mp3Bitrate = .kbps192

        model.addToQueue()
        #expect(model.state == .idle)
        #expect(model.urlText.isEmpty)
        #expect(queue.items.count == 1)
        let item = queue.items[0]
        #expect(item.title == "테스트 곡")
        #expect(item.options == ExtractOptions(format: .mp3(.kbps192), outputDirectory: testOutputDirectory))
        #expect(item.subfolder == nil)

        // 넣은 뒤 설정을 바꿔도 이미 넣은 항목은 그대로다.
        model.settings.formatKind = .flac
        #expect(queue.items[0].options.format == .mp3(.kbps192))
        queue.cancelAll()
        await queue.waitUntilIdle()
    }

    @Test func submitAddsWhenLoadedOtherwiseFetches() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)), extractGate: AsyncGate())
        let (model, queue, _) = makeModel(engine, autoFetchDelay: .seconds(60))
        model.urlText = validURL
        model.submit()
        await model.waitForTask()
        #expect(engine.fetchCount == 1)
        #expect(model.state == .video(sampleMetadata))

        model.submit()
        #expect(queue.items.count == 1)
        #expect(engine.fetchCount == 1)
        queue.cancelAll()
        await queue.waitUntilIdle()
    }

    @Test func addButtonSaysExtractWhenQueueIsIdleOtherwiseAddToQueue() async {
        let engine = FakeEngine(media: .success(.video(sampleMetadata)), extractGate: AsyncGate())
        let (model, queue, _) = await loaded(engine)
        model.settings.formatKind = .mp3
        #expect(model.addButtonTitle == "MP3로 추출")
        #expect(model.addButtonSymbol == "arrow.down.circle.fill")
        model.settings.formatKind = .flac
        #expect(model.addButtonTitle == "FLAC으로 추출")
        model.settings.mediaKind = .video
        #expect(model.addButtonTitle == "MP4로 받기")
        model.settings.videoFormat = .best
        #expect(model.addButtonTitle == "최고 화질로 받기")
        model.settings.mediaKind = .audio

        // 하나가 추출 중이면 다음 것은 줄을 선다.
        model.addToQueue()
        await waitUntil { queue.isRunning }
        model.urlText = validURL
        model.fetch()
        await model.waitForTask()
        #expect(model.addButtonTitle == "대기열에 추가")
        #expect(model.addButtonSymbol == "plus.circle.fill")
        queue.cancelAll()
        await queue.waitUntilIdle()
        #expect(model.addButtonTitle == "FLAC으로 추출")
    }

    @Test func addButtonCountsPlaylistEntries() async {
        let engine = FakeEngine(media: .success(.playlist(samplePlaylist)), extractGate: AsyncGate())
        let (model, queue, _) = await loaded(engine)
        #expect(model.addButtonTitle == "2개 추출")
        model.addToQueue()
        await waitUntil { queue.isRunning }
        model.urlText = "https://www.youtube.com/playlist?list=PL1"
        model.fetch()
        await model.waitForTask()
        #expect(model.addButtonTitle == "2개 대기열에 추가")
        queue.cancelAll()
        await queue.waitUntilIdle()
    }

    // MARK: - 재생목록

    @Test func playlistSelectsAvailableEntriesByDefault() async {
        let (model, _, _) = await loaded(FakeEngine(media: .success(.playlist(samplePlaylist))))
        #expect(model.state == .playlist(samplePlaylist))
        #expect(model.selectedEntryIDs == ["aaaaaaaaaaa", "ccccccccccc"])  // 비공개 영상은 빼고
        #expect(model.pendingAddCount == 2)

        model.toggleEntry("ccccccccccc")
        #expect(model.pendingAddCount == 1)
        model.setAllEntriesSelected(true)
        #expect(model.pendingAddCount == 3)
        model.setAllEntriesSelected(false)
        #expect(!model.canAddToQueue)
    }

    @Test func addingPlaylistQueuesSelectedEntriesIntoSubfolder() async {
        let engine = FakeEngine(media: .success(.playlist(samplePlaylist)), extractGate: AsyncGate())
        let (model, queue, _) = await loaded(engine)
        model.addToQueue()
        #expect(queue.items.map(\.title) == ["첫 곡", "셋째 곡"])
        #expect(queue.items.allSatisfy { $0.subfolder == "내 재생목록" })
        #expect(queue.items[0].url == URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa"))
        #expect(queue.items[0].destination == testOutputDirectory.appending(path: "내 재생목록", directoryHint: .isDirectory))
        #expect(model.state == .idle)
        queue.cancelAll()
        await queue.waitUntilIdle()
    }

    @Test func displayPathAbbreviatesOnlyHomePrefix() {
        let home = URL(filePath: "/Users/choi", directoryHint: .isDirectory)
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi/Music"), home: home) == "~/Music")
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi"), home: home) == "~")
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi2/Music"), home: home) == "/Users/choi2/Music")
    }
}

/// 대기열: 한 번에 하나씩, 취소·제거·다시 시도, 차단 시 일시 정지, 완료 알림.
@MainActor
struct ExtractQueueTests {
    private func item(_ title: String, subfolder: String? = nil, directory: URL = testOutputDirectory) -> ExtractQueue.Item {
        ExtractQueue.Item(
            url: URL(string: "https://youtu.be/\(title)")!, title: title,
            options: ExtractOptions(format: .mp3(.kbps320), outputDirectory: directory), subfolder: subfolder
        )
    }

    @Test func runsItemsOneAtATimeInOrderAndNotifiesOnce() async {
        let engine = FakeEngine(progressEvents: [.converting])
        let notifier = RecordingNotifier()
        let queue = ExtractQueue(engine: engine, notifier: notifier)
        queue.add([item("a"), item("b"), item("c")])
        #expect(queue.isRunning)
        #expect(engine.maxConcurrentExtractions <= 1)
        await queue.waitUntilIdle()

        #expect(engine.extractCalls.map(\.fileName) == ["a", "b", "c"])
        #expect(engine.maxConcurrentExtractions == 1)
        #expect(queue.completedCount == 3)
        #expect(notifier.prepared)
        #expect(notifier.completedTitles == ["3개 저장 완료"])
        #expect(!queue.isRunning)
    }

    @Test func cancelRunningItemMovesOnToNext() async {
        let gate = AsyncGate()
        let engine = FakeEngine(extractGate: gate)
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a"), item("b")])
        let first = queue.items[0].id
        queue.cancel(first)
        // 첫 항목 취소 → 둘째가 시작된다. 둘째는 문을 열어 끝낸다.
        for _ in 0..<300 where queue.items[1].status == .waiting { try? await Task.sleep(for: .milliseconds(10)) }
        gate.open()
        await queue.waitUntilIdle()
        #expect(queue.items[0].status == .cancelled)
        if case .completed = queue.items[1].status {} else { Issue.record("둘째가 완료되지 않음: \(queue.items[1].status)") }
    }

    @Test func cancelWaitingRemoveAndRetry() async {
        let gate = AsyncGate()
        let engine = FakeEngine(extractGate: gate)
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a"), item("b"), item("c")])
        let (b, c) = (queue.items[1].id, queue.items[2].id)
        queue.cancel(b)
        #expect(queue.items[1].status == .cancelled)
        queue.remove(c)
        #expect(queue.items.count == 2)

        queue.retry(b)
        #expect(queue.items[1].status == .waiting)
        gate.open()
        await queue.waitUntilIdle()
        #expect(queue.completedCount == 2)
        #expect(engine.extractCalls.map(\.fileName) == ["a", "b"])

        queue.clearFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func blockedByYouTubePausesQueueUntilResume() async {
        let engine = FakeEngine(extractResult: .failure(.blockedByYouTube))
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a"), item("b")])
        await queue.waitUntilIdle()
        #expect(queue.isPaused)
        #expect(queue.blockedAlert != nil)
        #expect(queue.items[0].status == .failed(.blockedByYouTube))
        #expect(queue.items[1].status == .waiting)  // 멈춰서 둘째는 시작하지 않는다
        #expect(engine.extractCalls.count == 1)

        engine.extractResult = .success(())
        queue.resume()
        await queue.waitUntilIdle()
        #expect(!queue.isPaused)
        #expect(queue.completedCount == 2)
    }

    @Test func otherErrorsDoNotStopTheQueue() async {
        let engine = FakeEngine(extractResult: .failure(.privateVideo))
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a"), item("b")])
        await queue.waitUntilIdle()
        #expect(queue.failedCount == 2)
        #expect(!queue.isPaused)
    }

    @Test func playlistSubfolderIsCreated() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "stow-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = FakeEngine()
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a", subfolder: "목록: 1/2", directory: base)])
        await queue.waitUntilIdle()
        let folder = base.appending(path: "목록- 1-2", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(engine.extractCalls.first?.options.outputDirectory == folder)
    }

    @Test func missingOutputFolderFailsItem() async {
        let engine = FakeEngine()
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a", directory: URL(filePath: "/nonexistent/stow-\(UUID().uuidString)"))])
        await queue.waitUntilIdle()
        #expect(queue.items[0].status == .failed(.outputDirectoryMissing))
        #expect(engine.extractCalls.isEmpty)
    }

    @Test func progressIsReflectedWhileRunning() async {
        let gate = AsyncGate()
        let engine = FakeEngine(progressEvents: [.converting], extractGate: gate)
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a")])
        for _ in 0..<300 where queue.items[0].progress.value != .converting {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.items[0].status == .running)
        #expect(queue.items[0].progress.value == .converting)
        gate.open()
        await queue.waitUntilIdle()
    }

    @Test func cancelAndWaitStopsRunningItemAndKeepsWaitingOnes() async {
        let engine = FakeEngine(extractGate: AsyncGate())
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a"), item("b")])
        await queue.cancelAndWait()
        #expect(!queue.isRunning)
        #expect(queue.items[0].status == .cancelled)
        #expect(queue.items[1].status == .waiting)
    }

    @Test func revealInFinderUsesCompletedFile() async {
        let notifier = RecordingNotifier()
        let queue = ExtractQueue(engine: FakeEngine(), notifier: notifier)
        queue.add([item("a")])
        await queue.waitUntilIdle()
        queue.revealInFinder(queue.items[0].id)
        #expect(notifier.revealed == [testOutputDirectory.appending(path: "a.mp3")])
    }
}

@MainActor
struct AppSettingsTests {
    @Test func defaults() {
        let settings = AppSettings(defaults: InMemoryDefaults(keepAppDefaults: true))
        #expect(settings.format == .mp3(.kbps320))
        #expect(settings.outputDirectory == AppSettings.defaultOutputDirectory)
        #expect(settings.acceptedNoticeVersion == 0)
    }

    /// 앱을 다시 실행해도(같은 저장소로 새로 만들어도) 설정이 유지된다.
    @Test func persistsAcrossInstances() {
        let suite = InMemoryDefaults()
        let first = AppSettings(defaults: suite)
        first.formatKind = .flac
        first.mp3Bitrate = .kbps128
        first.outputDirectory = URL(filePath: "/tmp/저장 폴더", directoryHint: .isDirectory)
        first.acceptedNoticeVersion = UsageNotice.version

        let second = AppSettings(defaults: suite)
        #expect(second.format == .flac)
        #expect(second.mp3Bitrate == .kbps128)
        #expect(second.outputDirectory.path == "/tmp/저장 폴더")
        #expect(second.acceptedNoticeVersion == UsageNotice.version)

        second.formatKind = .mp3
        #expect(second.format == .mp3(.kbps128))  // WAV/FLAC을 거쳐도 MP3 음질은 기억한다
    }

    /// 영상 기능 전의 설정(종류 값 없음)은 오디오로 시작하고, 영상 포맷·해상도는 기본값.
    @Test func videoDefaultsForExistingUsers() {
        let suite = InMemoryDefaults()
        suite.set("wav", forKey: "formatKind")
        let settings = AppSettings(defaults: suite)
        #expect(settings.mediaKind == .audio)
        #expect(settings.format == .wav)
        settings.mediaKind = .video
        #expect(settings.format == .video(.mp4, .p1080))
        settings.videoFormat = .best
        #expect(settings.format == .video(.best, .best))
    }

    /// 종류를 바꿔도 각 종류의 마지막 포맷, 영상 포맷마다의 해상도를 기억한다.
    @Test func remembersFormatsPerKind() {
        let suite = InMemoryDefaults()
        let first = AppSettings(defaults: suite)
        first.select(.flac)
        first.select(.video(.best, .p1440))
        first.select(.video(.mp4, .p720))

        let second = AppSettings(defaults: suite)
        #expect(second.format == .video(.mp4, .p720))
        second.videoFormat = .best
        #expect(second.format == .video(.best, .p1440))
        second.mediaKind = .audio
        #expect(second.format == .flac)
    }

    /// MP4에 없는 해상도(1080p 초과·최고)는 1080p로 맞춘다.
    @Test func mp4ClampsResolutionsAbove1080p() {
        let settings = AppSettings(defaults: InMemoryDefaults())
        settings.select(.video(.mp4, .p720))
        settings.videoResolution = .p2160
        #expect(settings.format == .video(.mp4, .p1080))
        settings.select(.video(.mp4, .best))
        #expect(settings.format == .video(.mp4, .p1080))
    }

    /// 실제 저장소(디스크)에 쓰고 새 객체로 다시 읽어도 유지된다. 다른 테스트는 메모리 저장소를 쓰므로 여기서만 진짜 저장소를 쓴다.
    /// 실행마다 새 이름을 만들면 ~/Library/Preferences에 파일이 쌓이므로 고정 이름 하나를 앞뒤로 비워 가며 쓴다.
    @Test func persistsOnDisk() throws {
        let suiteName = "stow-tests-persistence"
        let writer = try #require(UserDefaults(suiteName: suiteName))
        writer.removePersistentDomain(forName: suiteName)
        defer { writer.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: writer)
        first.formatKind = .wav
        first.mp3Bitrate = .kbps192
        first.outputDirectory = URL(filePath: "/tmp/디스크 저장", directoryHint: .isDirectory)
        first.acceptedNoticeVersion = UsageNotice.version
        #expect(CFPreferencesAppSynchronize(suiteName as CFString))

        let reader = try #require(UserDefaults(suiteName: suiteName))
        let second = AppSettings(defaults: reader)
        #expect(second.format == .wav)
        #expect(second.mp3Bitrate == .kbps192)
        #expect(second.outputDirectory.path == "/tmp/디스크 저장")
        #expect(second.acceptedNoticeVersion == UsageNotice.version)
        #expect(second.recentOutputDirectories.first?.path == "/tmp/디스크 저장")
    }

    @Test func selectFormat() {
        let settings = AppSettings(defaults: InMemoryDefaults())
        settings.select(.mp3(.kbps128))
        #expect(settings.formatKind == .mp3)
        #expect(settings.mp3Bitrate == .kbps128)
        settings.select(.wav)
        #expect(settings.format == .wav)
        #expect(settings.mp3Bitrate == .kbps128)  // MP3 음질은 기억한다
    }

    /// 최근 저장 폴더: 지금 폴더가 맨 앞, 같은 폴더는 한 번, 최대 5개, 다시 실행해도 유지.
    @Test func recentOutputDirectories() {
        let suite = InMemoryDefaults()
        let settings = AppSettings(defaults: suite)
        #expect(settings.recentOutputDirectories.map(\.path) == [InMemoryDefaults.testOutputDirectory.path])

        let folders = (1...6).map { URL(filePath: "/tmp/최근\($0)", directoryHint: .isDirectory) }
        for folder in folders { settings.outputDirectory = folder }
        #expect(settings.recentOutputDirectories.map(\.path) == ["/tmp/최근6", "/tmp/최근5", "/tmp/최근4", "/tmp/최근3", "/tmp/최근2"])

        // 이미 있는 폴더(끝의 / 표기만 다름)를 다시 고르면 맨 앞으로 옮기고 중복하지 않는다.
        settings.outputDirectory = URL(filePath: "/tmp/최근3/", directoryHint: .isDirectory)
        #expect(settings.recentOutputDirectories.map { $0.path(percentEncoded: false) }.count == 5)
        #expect(AppSettings.isSameDirectory(settings.recentOutputDirectories[0], folders[2]))
        #expect(settings.recentOutputDirectories.filter { AppSettings.isSameDirectory($0, folders[2]) }.count == 1)

        let reopened = AppSettings(defaults: suite)
        #expect(reopened.recentOutputDirectories.count == 5)
        #expect(AppSettings.isSameDirectory(reopened.recentOutputDirectories[0], folders[2]))
    }

    /// 심볼릭 링크로 가리킨 같은 폴더는 같은 폴더로 본다(/tmp → /private/tmp).
    @Test func sameDirectoryThroughSymlink() throws {
        let name = "stow-same-\(UUID().uuidString)"
        let dir = URL(filePath: "/private/tmp/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AppSettings.isSameDirectory(URL(filePath: "/tmp/\(name)/"), dir))
        #expect(!AppSettings.isSameDirectory(URL(filePath: "/tmp/\(name)"), URL(filePath: "/tmp/\(name)-other")))
    }

    /// 메뉴의 최근 폴더: 지금 폴더는 늘 보이고, 없어진 폴더는 뺀다.
    @Test func availableRecentsSkipMissingFolders() throws {
        let suite = InMemoryDefaults()
        let settings = AppSettings(defaults: suite)
        let existing = FileManager.default.temporaryDirectory.appending(path: "stow-recent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        let missing = URL(filePath: "/tmp/stow-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let missingCurrent = URL(filePath: "/tmp/stow-missing-current-\(UUID().uuidString)", directoryHint: .isDirectory)

        settings.outputDirectory = existing
        settings.outputDirectory = missing
        settings.outputDirectory = missingCurrent
        let shown = settings.availableRecentOutputDirectories
        #expect(shown.contains { AppSettings.isSameDirectory($0, missingCurrent) })  // 지금 폴더는 없어도 보인다
        #expect(shown.contains { AppSettings.isSameDirectory($0, existing) })
        #expect(!shown.contains { AppSettings.isSameDirectory($0, missing) })
    }

    @Test func durationFormat() {
        #expect(DurationFormat.string(from: 5) == "0:05")
        #expect(DurationFormat.string(from: 325) == "5:25")
        #expect(DurationFormat.string(from: 3723) == "1:02:03")
    }
}

// MARK: - 가짜 구현

/// 열 때까지 기다리게 하는 문.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.withLock { isOpen = true }
    }

    /// 열릴 때까지 기다린다. 작업이 취소되면 `CancellationError`를 던진다.
    func wait() async throws {
        while true {
            try Task.checkCancellation()
            if lock.withLock({ isOpen }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class FakeEngine: AudioExtracting, @unchecked Sendable {
    struct ExtractCall: Equatable {
        let url: URL
        let options: ExtractOptions
        let fileName: String
    }

    private let lock = NSLock()
    private var _mediaResult: Result<FetchedMedia, EngineError>
    private var _extractResult: Result<Void, EngineError>
    private var _fetchedURLs: [URL] = []
    private var _extractCalls: [ExtractCall] = []
    private var _running = 0
    private var _maxRunning = 0
    private let progressEvents: [ExtractProgress]
    private let extractGate: AsyncGate?
    private let fetchGate: AsyncGate?

    init(
        media: Result<FetchedMedia, EngineError> = .failure(.network),
        progressEvents: [ExtractProgress] = [],
        extractResult: Result<Void, EngineError> = .success(()),
        extractGate: AsyncGate? = nil,
        fetchGate: AsyncGate? = nil
    ) {
        _mediaResult = media
        _extractResult = extractResult
        self.progressEvents = progressEvents
        self.extractGate = extractGate
        self.fetchGate = fetchGate
    }

    var mediaResult: Result<FetchedMedia, EngineError> {
        get { lock.withLock { _mediaResult } }
        set { lock.withLock { _mediaResult = newValue } }
    }
    var extractResult: Result<Void, EngineError> {
        get { lock.withLock { _extractResult } }
        set { lock.withLock { _extractResult = newValue } }
    }
    var fetchedURLs: [URL] { lock.withLock { _fetchedURLs } }
    var fetchCount: Int { fetchedURLs.count }
    var extractCalls: [ExtractCall] { lock.withLock { _extractCalls } }
    var maxConcurrentExtractions: Int { lock.withLock { _maxRunning } }

    func fetchMedia(for url: URL) async throws -> FetchedMedia {
        lock.withLock { _fetchedURLs.append(url) }
        try await fetchGate?.wait()
        return try mediaResult.get()
    }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        lock.withLock {
            _extractCalls.append(ExtractCall(url: url, options: options, fileName: fileName))
            _running += 1
            _maxRunning = max(_maxRunning, _running)
        }
        defer { lock.withLock { _running -= 1 } }
        progressEvents.forEach(progress)
        try await extractGate?.wait()
        try extractResult.get()
        return options.outputDirectory.appending(path: "\(fileName).\(options.format.fileExtension ?? "mp4")")
    }
}

@MainActor
final class RecordingNotifier: CompletionNotifying {
    private(set) var prepared = false
    private(set) var completedTitles: [String] = []
    private(set) var completed: [URL] = []
    private(set) var revealed: [URL] = []

    func prepare() { prepared = true }
    func notifyCompleted(title: String, file: URL) {
        completedTitles.append(title)
        completed.append(file)
    }
    func revealInFinder(_ file: URL) { revealed.append(file) }
}

@MainActor
final class SilentNotifier: CompletionNotifying {
    func prepare() {}
    func notifyCompleted(title: String, file: URL) {}
    func revealInFinder(_ file: URL) {}
}

/// 코드 리뷰(PR #15) 반영 확인: 일시 정지 중 사용자 동작으로 재개, 다시 시도 시 이전 진행률 초기화.
@MainActor
struct ExtractQueueReviewTests {
    private func item(_ title: String) -> ExtractQueue.Item {
        ExtractQueue.Item(
            url: URL(string: "https://youtu.be/\(title)")!, title: title,
            options: ExtractOptions(format: .mp3(.kbps320), outputDirectory: testOutputDirectory)
        )
    }

    @Test func addingWhilePausedResumesQueue() async {
        let engine = FakeEngine(extractResult: .failure(.blockedByYouTube))
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a")])
        await queue.waitUntilIdle()
        #expect(queue.isPaused)

        engine.extractResult = .success(())
        queue.add([item("b")])  // "나중에"를 고른 뒤 새로 추가해도 멈춰 있지 않는다
        await queue.waitUntilIdle()
        #expect(!queue.isPaused)
        #expect(queue.completedCount == 2)  // 차단으로 실패했던 a도 다시 시도된다
    }

    @Test func retryWhilePausedResumesQueue() async {
        let engine = FakeEngine(extractResult: .failure(.blockedByYouTube))
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a")])
        await queue.waitUntilIdle()
        engine.extractResult = .success(())
        queue.retry(queue.items[0].id)
        await queue.waitUntilIdle()
        #expect(!queue.isPaused)
        #expect(queue.completedCount == 1)
    }

    @Test func retryStartsWithFreshProgress() async {
        let engine = FakeEngine(progressEvents: [.converting], extractResult: .failure(.network))
        let queue = ExtractQueue(engine: engine, notifier: RecordingNotifier())
        queue.add([item("a")])
        await queue.waitUntilIdle()
        #expect(queue.items[0].status == .failed(.network))

        let gate = AsyncGate()
        let retryEngine = FakeEngine(extractGate: gate)  // 진행률을 보내지 않는 엔진
        let retryQueue = ExtractQueue(engine: retryEngine, notifier: RecordingNotifier())
        retryQueue.add([item("b")])
        #expect(retryQueue.items[0].progress.value == nil)
        gate.open()
        await retryQueue.waitUntilIdle()

        // 같은 대기열에서 다시 시도하면 시작할 때 진행률을 비운다.
        queue.retry(queue.items[0].id)
        #expect(queue.items[0].status == .running)
        #expect(queue.items[0].progress.value == nil)
        await queue.waitUntilIdle()
    }
}
