import Foundation
import Observation

/// 추출 화면 상태와 동작(PROJECT.md 4장: 대기 → 조회 중 → 준비 → 추출 중 → 완료 / 실패).
@MainActor
@Observable
final class ExtractViewModel {
    enum State: Equatable {
        case idle
        case fetching
        case ready(VideoMetadata)
        case extracting(VideoMetadata, ExtractProgress?)
        case completed(VideoMetadata, URL)
        case failed(EngineError, VideoMetadata?)
    }

    /// 다시 시도할 동작.
    enum RetryAction: Equatable {
        case fetch
        case extract
    }

    /// 유튜브가 요청을 막았을 때 띄우는 알림창.
    struct RetryAlert: Identifiable, Equatable {
        let id = UUID()
        let action: RetryAction
        let message: String
    }

    /// 주소 입력란. 불러온 뒤 주소를 바꾸면 처음 상태로 돌아간다.
    var urlText = "" {
        didSet {
            guard urlText != oldValue, !isBusy, loadedURLText != nil, urlText != loadedURLText else { return }
            loadedURLText = nil
            videoURL = nil
            state = .idle
        }
    }

    private(set) var state: State = .idle
    var retryAlert: RetryAlert?

    let settings: AppSettings
    @ObservationIgnored private let engine: any AudioExtracting
    @ObservationIgnored private let notifier: any CompletionNotifying
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var videoURL: URL?
    @ObservationIgnored private var loadedURLText: String?

    init(settings: AppSettings, engine: any AudioExtracting, notifier: any CompletionNotifying) {
        self.settings = settings
        self.engine = engine
        self.notifier = notifier
    }

    // MARK: - 화면에서 쓰는 값

    var isBusy: Bool {
        switch state {
        case .fetching, .extracting: true
        default: false
        }
    }

    /// 지금 표시할 영상 정보.
    var metadata: VideoMetadata? {
        switch state {
        case .ready(let metadata), .extracting(let metadata, _), .completed(let metadata, _): metadata
        case .failed(_, let metadata): metadata
        case .idle, .fetching: nil
        }
    }

    var canFetch: Bool {
        !isBusy && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canExtract: Bool {
        !isBusy && metadata != nil && videoURL != nil
    }

    // MARK: - 동작

    /// 주소를 검증하고 영상 정보를 불러온다.
    func fetch() {
        guard canFetch else { return }
        let text = urlText
        let url: URL
        do {
            url = try YouTubeURL.parse(text)
        } catch {
            state = .failed(error, nil)
            return
        }
        videoURL = url
        loadedURLText = text
        state = .fetching
        task = Task {
            do {
                let metadata = try await engine.fetchMetadata(for: url)
                state = .ready(metadata)
            } catch is CancellationError {
                state = .idle
            } catch {
                fail(error, metadata: nil, retry: .fetch)
            }
        }
    }

    /// 현재 설정(포맷·저장 위치)으로 추출한다.
    func extract() {
        guard canExtract, let metadata, let url = videoURL else { return }
        notifier.prepare()
        let options = settings.extractOptions
        state = .extracting(metadata, nil)

        let (progressStream, progressContinuation) = AsyncStream<ExtractProgress>.makeStream()
        let progressTask = Task {
            for await progress in progressStream {
                if case .extracting(let current, _) = state, current == metadata {
                    state = .extracting(metadata, progress)
                }
            }
        }
        task = Task {
            defer { progressContinuation.finish() }
            do {
                let file = try await engine.extract(
                    url, options: options, fileName: metadata.title,
                    progress: { progressContinuation.yield($0) }
                )
                progressContinuation.finish()
                await progressTask.value
                state = .completed(metadata, file)
                notifier.notifyCompleted(title: metadata.title, file: file)
            } catch is CancellationError {
                state = .ready(metadata)
            } catch {
                fail(error, metadata: metadata, retry: .extract)
            }
        }
    }

    /// 진행 중인 조회·추출을 취소한다.
    func cancel() {
        task?.cancel()
    }

    /// 알림창의 "다시 시도".
    func retry(_ action: RetryAction) {
        retryAlert = nil
        switch action {
        case .fetch:
            loadedURLText = nil
            fetch()
        case .extract:
            if case .failed(_, let metadata?) = state { state = .ready(metadata) }
            extract()
        }
    }

    func revealInFinder() {
        if case .completed(_, let file) = state { notifier.revealInFinder(file) }
    }

    /// 다른 영상을 추출하도록 처음 상태로 돌아간다.
    func startOver() {
        guard !isBusy else { return }
        loadedURLText = nil
        videoURL = nil
        urlText = ""
        state = .idle
    }

    /// 테스트에서 진행 중인 작업이 끝날 때까지 기다린다.
    func waitForTask() async {
        await task?.value
    }

    private func fail(_ error: any Error, metadata: VideoMetadata?, retry: RetryAction) {
        let engineError = error as? EngineError ?? .unknown(error.localizedDescription)
        state = .failed(engineError, metadata)
        if engineError == .blockedByYouTube {
            retryAlert = RetryAlert(action: retry, message: engineError.errorDescription ?? "")
        }
    }
}
