import Foundation
import Testing
@testable import Stow

/// 가짜 엔진으로 추출 화면 상태 흐름을 확인한다.
@MainActor
struct ExtractViewModelTests {
    private let metadata = VideoMetadata(id: "abc123", title: "테스트 곡", duration: 200, uploader: "채널")
    private let validURL = "https://www.youtube.com/watch?v=abc123"
    /// 추출 전에 저장 폴더가 있는지 확인하므로 실제로 있는 폴더를 쓴다.
    private static let outputDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "stow-vm-tests", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func makeModel(_ engine: FakeEngine) -> (ExtractViewModel, AppSettings, RecordingNotifier) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-test-\(UUID().uuidString)")!)
        settings.outputDirectory = Self.outputDirectory
        let notifier = RecordingNotifier()
        return (ExtractViewModel(settings: settings, engine: engine, notifier: notifier), settings, notifier)
    }

    private func loaded(_ engine: FakeEngine) async -> (ExtractViewModel, AppSettings, RecordingNotifier) {
        let (model, settings, notifier) = makeModel(engine)
        model.urlText = validURL
        model.fetch()
        await model.waitForTask()
        return (model, settings, notifier)
    }

    // MARK: - 조회

    @Test func invalidURLFailsWithoutCallingEngine() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.urlText = "https://example.com/watch?v=1"
        model.fetch()
        #expect(model.state == .failed(.invalidURL, nil))
        #expect(engine.fetchCount == 0)
    }

    @Test func fetchShowsMetadata() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let (model, _, _) = makeModel(engine)
        model.urlText = "  \(validURL)\n"
        #expect(model.canFetch)
        model.fetch()
        #expect(model.state == .fetching)
        #expect(!model.canFetch)
        await model.waitForTask()
        #expect(model.state == .ready(metadata))
        #expect(model.canExtract)
        #expect(engine.fetchedURLs == [URL(string: validURL)!])
    }

    @Test func fetchErrorIsShownInline() async {
        let engine = FakeEngine(metadata: .failure(.privateVideo))
        let (model, _, _) = await loaded(engine)
        #expect(model.state == .failed(.privateVideo, nil))
        #expect(model.retryAlert == nil)
    }

    @Test func editingURLAfterLoadingResets() async {
        let (model, _, _) = await loaded(FakeEngine(metadata: .success(metadata)))
        model.urlText = "https://youtu.be/other"
        #expect(model.state == .idle)
        #expect(!model.canExtract)
    }

    // MARK: - 추출

    @Test func extractUsesSettingsAndCompletes() async {
        let engine = FakeEngine(metadata: .success(metadata), progressEvents: [
            .downloading(fraction: 0.5, bytesPerSecond: nil, secondsRemaining: 3), .converting,
        ])
        let (model, settings, notifier) = await loaded(engine)
        settings.formatKind = .mp3
        settings.mp3Bitrate = .kbps192

        model.extract()
        #expect(model.state == .extracting(metadata, nil))
        #expect(model.isBusy)
        await model.waitForTask()

        let expectedFile = Self.outputDirectory.appending(path: "테스트 곡.mp3")
        #expect(model.state == .completed(metadata, expectedFile))
        #expect(engine.extractCalls == [
            .init(url: URL(string: validURL)!, options: ExtractOptions(
                format: .mp3(.kbps192), outputDirectory: Self.outputDirectory
            ), fileName: "테스트 곡"),
        ])
        #expect(notifier.prepared)
        #expect(notifier.completed == [expectedFile])

        model.revealInFinder()
        #expect(notifier.revealed == [expectedFile])
    }

    @Test func progressIsReflectedWhileExtracting() async {
        let gate = AsyncGate()
        let engine = FakeEngine(metadata: .success(metadata), progressEvents: [.converting], extractGate: gate)
        let (model, _, _) = await loaded(engine)

        model.extract()
        await engine.waitUntilProgressSent()
        // 진행률은 메인 액터로 전달되므로 반영될 때까지 잠시 기다린다.
        for _ in 0..<100 where model.state != .extracting(metadata, .converting) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state == .extracting(metadata, .converting))
        gate.open()
        await model.waitForTask()
        if case .completed = model.state {} else { Issue.record("완료되지 않음: \(model.state)") }
    }

    @Test func cancelReturnsToReady() async {
        let engine = FakeEngine(metadata: .success(metadata), extractGate: AsyncGate())  // 열리지 않음
        let (model, _, notifier) = await loaded(engine)
        model.extract()
        model.cancel()
        await model.waitForTask()
        #expect(model.state == .ready(metadata))
        #expect(notifier.completed.isEmpty)
    }

    @Test func extractErrorKeepsMetadataAndAllowsRetry() async {
        let engine = FakeEngine(metadata: .success(metadata), extractResult: .failure(.diskFull))
        let (model, _, _) = await loaded(engine)
        model.extract()
        await model.waitForTask()
        #expect(model.state == .failed(.diskFull, metadata))
        #expect(model.retryAlert == nil)
        #expect(model.canExtract)  // 저장 위치를 바꿔 다시 추출할 수 있다
    }

    // MARK: - 유튜브 차단 → 다시 시도 알림창

    @Test func blockedFetchShowsRetryAlert() async {
        let engine = FakeEngine(metadata: .failure(.blockedByYouTube))
        let (model, _, _) = await loaded(engine)
        #expect(model.retryAlert?.action == .fetch)
        #expect(model.retryAlert?.message == EngineError.blockedByYouTube.errorDescription)

        engine.metadataResult = .success(metadata)
        model.retry(.fetch)
        #expect(model.retryAlert == nil)
        await model.waitForTask()
        #expect(model.state == .ready(metadata))
        #expect(engine.fetchCount == 2)
    }

    @Test func blockedExtractShowsRetryAlert() async {
        let engine = FakeEngine(metadata: .success(metadata), extractResult: .failure(.blockedByYouTube))
        let (model, _, _) = await loaded(engine)
        model.extract()
        await model.waitForTask()
        #expect(model.state == .failed(.blockedByYouTube, metadata))
        #expect(model.retryAlert?.action == .extract)

        engine.extractResult = .success(())
        model.retry(.extract)
        await model.waitForTask()
        if case .completed = model.state {} else { Issue.record("완료되지 않음: \(model.state)") }
        #expect(engine.extractCalls.count == 2)
    }

    @Test func startOverClearsState() async {
        let (model, _, _) = await loaded(FakeEngine(metadata: .success(metadata)))
        model.extract()
        await model.waitForTask()
        model.startOver()
        #expect(model.state == .idle)
        #expect(model.urlText.isEmpty)
    }

    // MARK: - 코드 리뷰 반영

    /// 저장 폴더가 없으면 내려받기 전에 알린다.
    @Test func missingOutputFolderFailsBeforeExtracting() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let (model, settings, _) = await loaded(engine)
        settings.outputDirectory = URL(filePath: "/nonexistent/stow-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.extract()
        #expect(model.state == .failed(.outputDirectoryMissing, metadata))
        #expect(engine.extractCalls.isEmpty)
    }

    /// Return: 불러온 주소 그대로면 추출하고, 주소를 바꿨으면 다시 불러온다.
    @Test func submitExtractsWhenLoadedOtherwiseFetches() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let (model, _, _) = makeModel(engine)
        model.urlText = validURL
        model.submit()
        await model.waitForTask()
        #expect(engine.fetchCount == 1)

        model.submit()
        await model.waitForTask()
        #expect(engine.fetchCount == 1)
        #expect(engine.extractCalls.count == 1)
    }

    @Test func cancelDuringFetchReturnsToIdle() async {
        let engine = SlowMetadataEngine()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-test-\(UUID().uuidString)")!)
        let model = ExtractViewModel(settings: settings, engine: engine, notifier: RecordingNotifier())
        model.urlText = validURL
        model.fetch()
        #expect(model.state == .fetching)
        model.cancel()
        await model.waitForTask()
        #expect(model.state == .idle)
    }

    /// 앱 종료 시: 취소하고 끝날 때까지 기다린다.
    @Test func cancelAndWaitStopsExtraction() async {
        let engine = FakeEngine(metadata: .success(metadata), extractGate: AsyncGate())
        let (model, _, _) = await loaded(engine)
        model.extract()
        #expect(model.isBusy)
        await model.cancelAndWait()
        #expect(model.state == .ready(metadata))
        #expect(!model.isBusy)
    }

    // MARK: - 자동 불러오기

    private func autoModel(_ engine: any AudioExtracting) -> ExtractViewModel {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-test-\(UUID().uuidString)")!)
        settings.outputDirectory = Self.outputDirectory
        return ExtractViewModel(
            settings: settings, engine: engine, notifier: RecordingNotifier(), autoFetchDelay: .milliseconds(30)
        )
    }

    /// 조건이 맞을 때까지(최대 3초) 기다린다.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pastingURLLoadsAutomatically() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let model = autoModel(engine)
        model.urlText = validURL
        #expect(model.state == .idle)  // 바로 조회하지 않고 잠시 기다린다
        await waitUntil { model.state == .ready(metadata) }
        #expect(model.state == .ready(metadata))
        #expect(engine.fetchCount == 1)
    }

    @Test func typingQuicklyFetchesOnlyTheLastText() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let model = autoModel(engine)
        model.urlText = "https://youtu.be/a"
        model.urlText = "https://youtu.be/ab"
        model.urlText = "https://youtu.be/abc"
        await waitUntil { model.state == .ready(metadata) }
        #expect(engine.fetchedURLs == [URL(string: "https://youtu.be/abc")!])
    }

    @Test func invalidTextShowsErrorAfterPause() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let model = autoModel(engine)
        model.urlText = "https://example.com/watch?v=1"
        await waitUntil { model.state != .idle }
        #expect(model.state == .failed(.invalidURL, nil))
        #expect(engine.fetchCount == 0)

        model.urlText = ""  // 지우면 오류도 사라진다
        #expect(model.state == .idle)
    }

    /// 조회 중에 주소를 바꾸면 이전 조회를 버리고 새 주소를 불러온다.
    @Test func changingURLDuringFetchRestarts() async {
        let other = VideoMetadata(id: "other", title: "다른 곡")
        let engine = PerURLEngine(slowURL: URL(string: validURL)!, fastResult: other)
        let model = autoModel(engine)
        model.urlText = validURL
        await waitUntil { model.state == .fetching }
        #expect(model.state == .fetching)

        model.urlText = "https://youtu.be/other"
        await waitUntil { model.state == .ready(other) }
        #expect(model.state == .ready(other))
        // 취소된 이전 조회의 결과가 나중에 덮어쓰지 않는다.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.state == .ready(other))
    }

    @Test func returnFetchesImmediately() async {
        let engine = FakeEngine(metadata: .success(metadata))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-test-\(UUID().uuidString)")!)
        let model = ExtractViewModel(
            settings: settings, engine: engine, notifier: RecordingNotifier(), autoFetchDelay: .seconds(60)
        )
        model.urlText = validURL
        model.submit()
        #expect(model.state == .fetching)
        await model.waitForTask()
        #expect(model.state == .ready(metadata))
        #expect(engine.fetchCount == 1)
    }

    @Test func displayPathAbbreviatesOnlyHomePrefix() {
        let home = URL(filePath: "/Users/choi", directoryHint: .isDirectory)
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi/Music"), home: home) == "~/Music")
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi"), home: home) == "~")
        #expect(DisplayPath.abbreviated(URL(filePath: "/Users/choi2/Music"), home: home) == "/Users/choi2/Music")
        #expect(DisplayPath.abbreviated(URL(filePath: "/Volumes/X/Users/choi/a"), home: home) == "/Volumes/X/Users/choi/a")
    }
}

/// `slowURL`은 취소될 때까지 끝나지 않고, 다른 주소는 바로 `fastResult`를 돌려주는 엔진.
final class PerURLEngine: AudioExtracting {
    let slowURL: URL
    let fastResult: VideoMetadata

    init(slowURL: URL, fastResult: VideoMetadata) {
        self.slowURL = slowURL
        self.fastResult = fastResult
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        if url == slowURL {
            try await Task.sleep(for: .seconds(600))
        }
        return fastResult
    }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        throw EngineError.network
    }
}

/// 조회가 취소될 때까지 끝나지 않는 엔진.
final class SlowMetadataEngine: AudioExtracting {
    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        try await Task.sleep(for: .seconds(600))
        throw EngineError.network
    }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        throw EngineError.network
    }
}

@MainActor
struct AppSettingsTests {
    @Test func defaults() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stow-test-\(UUID().uuidString)")!)
        #expect(settings.format == .mp3(.kbps320))
        #expect(settings.outputDirectory == AppSettings.defaultOutputDirectory)
        #expect(settings.acceptedNoticeVersion == 0)
    }

    /// 앱을 다시 실행해도(같은 저장소로 새로 만들어도) 설정이 유지된다.
    @Test func persistsAcrossInstances() {
        let suite = "stow-test-\(UUID().uuidString)"
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.formatKind = .flac
        first.mp3Bitrate = .kbps128
        first.outputDirectory = URL(filePath: "/tmp/저장 폴더", directoryHint: .isDirectory)
        first.acceptedNoticeVersion = UsageNotice.version

        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.format == .flac)
        #expect(second.mp3Bitrate == .kbps128)
        #expect(second.outputDirectory.path == "/tmp/저장 폴더")
        #expect(second.acceptedNoticeVersion == UsageNotice.version)

        second.formatKind = .mp3
        #expect(second.format == .mp3(.kbps128))  // WAV/FLAC을 거쳐도 MP3 음질은 기억한다
        UserDefaults().removePersistentDomain(forName: suite)
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
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
    private var _metadataResult: Result<VideoMetadata, EngineError>
    private var _extractResult: Result<Void, EngineError>
    private var _fetchedURLs: [URL] = []
    private var _extractCalls: [ExtractCall] = []
    private let progressEvents: [ExtractProgress]
    private let extractGate: AsyncGate?
    private let progressSent = AsyncGate()

    init(
        metadata: Result<VideoMetadata, EngineError> = .failure(.network),
        progressEvents: [ExtractProgress] = [],
        extractResult: Result<Void, EngineError> = .success(()),
        extractGate: AsyncGate? = nil
    ) {
        _metadataResult = metadata
        _extractResult = extractResult
        self.progressEvents = progressEvents
        self.extractGate = extractGate
    }

    var metadataResult: Result<VideoMetadata, EngineError> {
        get { lock.withLock { _metadataResult } }
        set { lock.withLock { _metadataResult = newValue } }
    }
    var extractResult: Result<Void, EngineError> {
        get { lock.withLock { _extractResult } }
        set { lock.withLock { _extractResult = newValue } }
    }
    var fetchedURLs: [URL] { lock.withLock { _fetchedURLs } }
    var fetchCount: Int { fetchedURLs.count }
    var extractCalls: [ExtractCall] { lock.withLock { _extractCalls } }

    func waitUntilProgressSent() async {
        try? await progressSent.wait()
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        lock.withLock { _fetchedURLs.append(url) }
        return try metadataResult.get()
    }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        lock.withLock { _extractCalls.append(ExtractCall(url: url, options: options, fileName: fileName)) }
        progressEvents.forEach(progress)
        progressSent.open()
        try await extractGate?.wait()
        try extractResult.get()
        return options.outputDirectory.appending(path: "\(fileName).\(options.format.fileExtension)")
    }
}

@MainActor
final class RecordingNotifier: CompletionNotifying {
    private(set) var prepared = false
    private(set) var completed: [URL] = []
    private(set) var revealed: [URL] = []

    func prepare() { prepared = true }
    func notifyCompleted(title: String, file: URL) { completed.append(file) }
    func revealInFinder(_ file: URL) { revealed.append(file) }
}

@MainActor
final class SilentNotifier: CompletionNotifying {
    func prepare() {}
    func notifyCompleted(title: String, file: URL) {}
    func revealInFinder(_ file: URL) {}
}
