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
    @ObservationIgnored private var currentRunID: UUID?

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

    /// 주소 입력란에서 Return을 눌렀을 때: 불러온 주소 그대로면 추출, 아니면 불러오기.
    func submit() {
        if canExtract, urlText == loadedURLText {
            extract()
        } else {
            fetch()
        }
    }

    /// 현재 설정(포맷·저장 위치)으로 추출한다.
    func extract() {
        guard canExtract, let metadata, let url = videoURL else { return }
        let options = settings.extractOptions
        // 내려받고 변환한 뒤에야 폴더가 없다는 것을 알게 되지 않도록 먼저 확인한다.
        guard Self.directoryExists(options.outputDirectory) else {
            state = .failed(.outputDirectoryMissing, metadata)
            return
        }
        notifier.prepare()
        let runID = UUID()
        currentRunID = runID
        state = .extracting(metadata, nil)

        let (progressStream, progressContinuation) = AsyncStream<ExtractProgress>.makeStream()
        let progressTask = Task {
            for await progress in progressStream {
                // 이전 실행의 진행률이 다시 시도한 실행에 섞이지 않게 실행 ID로 거른다.
                guard currentRunID == runID, case .extracting(_, let shown) = state else { continue }
                if Self.isVisibleChange(from: shown, to: progress) {
                    state = .extracting(metadata, progress)
                }
            }
        }
        task = Task {
            let result: Result<URL, any Error>
            do {
                result = .success(try await engine.extract(
                    url, options: options, fileName: metadata.title,
                    progress: { progressContinuation.yield($0) }
                ))
            } catch {
                result = .failure(error)
            }
            progressContinuation.finish()
            await progressTask.value
            currentRunID = nil
            switch result {
            case .success(let file):
                state = .completed(metadata, file)
                notifier.notifyCompleted(title: metadata.title, file: file)
            case .failure(is CancellationError):
                state = .ready(metadata)
            case .failure(let error):
                fail(error, metadata: metadata, retry: .extract)
            }
        }
    }

    /// 진행 중인 조회·추출을 취소한다.
    func cancel() {
        task?.cancel()
    }

    /// 앱을 종료할 때: 진행 중인 작업을 취소하고 엔진 프로세스가 끝날 때까지 기다린다.
    func cancelAndWait() async {
        task?.cancel()
        await task?.value
    }

    /// 알림창의 "다시 시도".
    func retry(_ action: RetryAction) {
        retryAlert = nil
        switch action {
        case .fetch:
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

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// 화면에 보이는 값(퍼센트·남은 시간·단계)이 바뀔 때만 상태를 갱신한다.
    /// yt-dlp는 진행률을 초당 여러 번 출력하므로 줄마다 화면을 다시 그리지 않는다.
    private static func isVisibleChange(from shown: ExtractProgress?, to new: ExtractProgress) -> Bool {
        switch (shown, new) {
        case (.downloading(let oldFraction, _, let oldETA)?, .downloading(let newFraction, _, let newETA)):
            percent(oldFraction) != percent(newFraction) || oldETA != newETA
        default:
            shown != new
        }
    }

    private static func percent(_ fraction: Double?) -> Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    private func fail(_ error: any Error, metadata: VideoMetadata?, retry: RetryAction) {
        let engineError = error as? EngineError ?? .unknown(error.localizedDescription)
        state = .failed(engineError, metadata)
        if engineError == .blockedByYouTube {
            retryAlert = RetryAlert(action: retry, message: engineError.errorDescription ?? "")
        }
    }
}
