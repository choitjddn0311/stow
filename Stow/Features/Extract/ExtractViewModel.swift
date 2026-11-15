import Foundation
import Observation

/// 주소 입력과 불러오기(영상 하나 또는 재생목록 선택)를 맡고, 고른 것을 대기열(`ExtractQueue`)에 넣는다.
/// 추출 자체는 대기열이 한다(MVP 이후 3번, 2026-11-14).
///
/// 상태: 대기 → 조회 중 → 영상 / 재생목록 선택 → (대기열에 추가하면) 대기, 또는 실패.
@MainActor
@Observable
final class ExtractViewModel {
    enum State: Equatable {
        case idle
        case fetching
        case video(VideoMetadata)
        case playlist(Playlist)
        case failed(EngineError)
    }

    /// 유튜브가 요청을 막았을 때 띄우는 알림창(불러오기 단계). 추출 단계의 차단은 대기열이 띄운다.
    struct RetryAlert: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    /// 주소 입력란. 붙여 넣거나 입력을 멈추면 `autoFetchDelay` 뒤에 자동으로 불러온다.
    /// 불러온 뒤 주소를 바꾸면 처음 상태로 돌아가고 새 주소를 불러온다.
    var urlText = "" {
        didSet { urlTextDidChange(from: oldValue) }
    }

    private(set) var state: State = .idle
    /// 재생목록에서 고른 영상 ID
    var selectedEntryIDs: Set<String> = []
    var retryAlert: RetryAlert?

    let settings: AppSettings
    let queue: ExtractQueue
    @ObservationIgnored private let engine: any AudioExtracting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedURLText: String?
    @ObservationIgnored private var currentFetchID: UUID?
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?
    /// 입력을 멈춘 뒤 자동으로 불러오기까지 기다리는 시간. 한 글자씩 입력할 때마다 조회하지 않게 한다.
    @ObservationIgnored private let autoFetchDelay: Duration

    init(
        settings: AppSettings,
        engine: any AudioExtracting,
        queue: ExtractQueue,
        autoFetchDelay: Duration = .milliseconds(500)
    ) {
        self.settings = settings
        self.engine = engine
        self.queue = queue
        self.autoFetchDelay = autoFetchDelay
    }

    // MARK: - 화면에서 쓰는 값

    /// 진행률 같은 세부 값을 뺀 화면 단계. 화면 전환 애니메이션의 기준으로 쓴다.
    enum Stage: Hashable {
        case idle, fetching, video, playlist, failed
    }

    var stage: Stage {
        switch state {
        case .idle: .idle
        case .fetching: .fetching
        case .video: .video
        case .playlist: .playlist
        case .failed: .failed
        }
    }

    var isFetching: Bool { state == .fetching }

    var canFetch: Bool {
        !isFetching && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 대기열에 넣을 영상 수(영상이면 1, 재생목록이면 고른 수).
    var pendingAddCount: Int {
        switch state {
        case .video: 1
        // 선택은 재생목록 항목 ID만 담으므로 바로 센다(큰 재생목록에서도 화면을 그릴 때마다 목록을 훑지 않게).
        case .playlist: selectedEntryIDs.count
        default: 0
        }
    }

    var canAddToQueue: Bool { pendingAddCount > 0 }

    /// 추가 버튼 이름. 누르면 바로 추출이 시작되면(진행 중·대기 중인 항목이 없음) "추출",
    /// 다른 영상 뒤에 줄을 서면 "대기열에 추가"라고 부른다.
    /// 예: "MP3로 추출", "FLAC으로 추출", "12개 추출", "대기열에 추가", "12개 대기열에 추가"
    /// 아직 불러오지 않았을 때(빠른 추출 패널)는 영상 하나로 보고 부른다.
    var addButtonTitle: String {
        let startsNow = !queue.isRunning && queue.waitingCount == 0
        let count: String? = if case .playlist = state { "\(pendingAddCount)개" } else { nil }
        switch (startsNow, count) {
        case (true, let count?): return "\(count) 추출"
        case (true, nil):
            let kind = settings.formatKind
            return "\(kind.displayName)\(kind == .flac ? "으로" : "로") 추출"
        case (false, let count?): return "\(count) 대기열에 추가"
        case (false, nil): return "대기열에 추가"
        }
    }

    /// 추가 버튼 아이콘: 바로 추출이면 내려받기, 줄을 서면 더하기.
    var addButtonSymbol: String {
        !queue.isRunning && queue.waitingCount == 0 ? "arrow.down.circle.fill" : "plus.circle.fill"
    }

    // MARK: - 동작

    /// 주소를 검증하고 영상 정보(또는 재생목록)를 불러온다(자동 불러오기도 이 함수를 쓴다).
    func fetch() {
        autoFetchTask?.cancel()
        guard canFetch else { return }
        let text = urlText
        let url: URL
        do {
            url = try YouTubeURL.parse(text)
        } catch {
            state = .failed(error)
            return
        }
        loadedURLText = text
        state = .fetching
        let fetchID = UUID()
        currentFetchID = fetchID
        task = Task {
            let result: Result<FetchedMedia, any Error>
            do {
                result = .success(try await engine.fetchMedia(for: url))
            } catch {
                result = .failure(error)
            }
            // 주소를 바꿔 다른 조회가 시작되었으면 이 결과는 버린다.
            guard currentFetchID == fetchID else { return }
            currentFetchID = nil
            switch result {
            case .success(.video(let metadata)):
                state = .video(metadata)
            case .success(.playlist(let playlist)):
                showPlaylist(playlist)
            case .failure(is CancellationError):
                state = .idle
            case .failure(let error):
                let engineError = error as? EngineError ?? .unknown(error.localizedDescription)
                state = .failed(engineError)
                if engineError == .blockedByYouTube {
                    retryAlert = RetryAlert(message: engineError.errorDescription ?? "")
                }
            }
        }
    }

    /// 주소 입력란에서 Return을 눌렀을 때: 불러온 주소 그대로면 대기열에 추가, 아니면 불러오기.
    func submit() {
        if canAddToQueue, urlText == loadedURLText {
            addToQueue()
        } else {
            fetch()
        }
    }

    /// 불러온 영상(또는 재생목록에서 고른 영상)을 지금 설정으로 대기열에 넣고 주소란을 비운다.
    func addToQueue() {
        let options = settings.extractOptions
        switch state {
        case .video(let metadata):
            guard let url = metadata.webpageURL ?? loadedURLText.flatMap({ try? YouTubeURL.parse($0) }) else { return }
            queue.add([ExtractQueue.Item(
                url: url, title: metadata.title, duration: metadata.duration,
                thumbnailURL: metadata.thumbnailURL, options: options
            )])
        case .playlist(let playlist):
            let items = playlist.entries
                .filter { selectedEntryIDs.contains($0.id) }
                .map { ExtractQueue.Item(url: $0.url, title: $0.title, duration: $0.duration, options: options, subfolder: playlist.title) }
            guard !items.isEmpty else { return }
            queue.add(items)
        default:
            return
        }
        startOver()
    }

    /// 다른 곳(빠른 추출 패널)에서 이미 불러온 재생목록을 다시 조회하지 않고 보여 준다.
    /// 이 화면에 불러와 있던 것이나 진행 중인 조회는 버린다(사용자가 이 재생목록을 열기로 했으므로).
    func showLoaded(_ playlist: Playlist, urlText text: String) {
        autoFetchTask?.cancel()
        if isFetching {
            currentFetchID = nil
            task?.cancel()
        }
        retryAlert = nil
        // 불러온 주소로 먼저 기록해, 주소란을 바꿀 때 자동 불러오기가 돌지 않게 한다.
        loadedURLText = text
        urlText = text
        showPlaylist(playlist)
    }

    /// 진행 중인 조회를 취소한다.
    func cancelFetch() {
        task?.cancel()
    }

    /// 알림창의 "다시 시도"(불러오기).
    func retryFetch() {
        retryAlert = nil
        fetch()
    }

    // MARK: 재생목록 선택

    func setAllEntriesSelected(_ selected: Bool) {
        guard case .playlist(let playlist) = state else { return }
        selectedEntryIDs = selected ? Set(playlist.entries.map(\.id)) : []
    }

    func toggleEntry(_ id: String) {
        if selectedEntryIDs.contains(id) {
            selectedEntryIDs.remove(id)
        } else {
            selectedEntryIDs.insert(id)
        }
    }

    /// 처음 상태로 돌아간다(주소란 비움).
    func startOver() {
        guard !isFetching else { return }
        loadedURLText = nil
        urlText = ""
        selectedEntryIDs = []
        state = .idle
    }

    /// 테스트에서 진행 중인 조회가 끝날 때까지 기다린다.
    func waitForTask() async {
        await task?.value
    }

    // MARK: - 내부

    private func showPlaylist(_ playlist: Playlist) {
        // 비공개·삭제된 영상은 기본 선택에서 뺀다.
        selectedEntryIDs = Set(playlist.entries.filter { !$0.isUnavailable }.map(\.id))
        state = .playlist(playlist)
    }

    /// 주소가 바뀌었을 때: 이전 결과를 지우고, 잠시 뒤 새 주소를 자동으로 불러온다.
    private func urlTextDidChange(from oldValue: String) {
        guard urlText != oldValue else { return }
        autoFetchTask?.cancel()

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 불러온 주소와 같으면(앞뒤 공백만 바뀐 경우 포함) 그대로 둔다.
        if let loadedURLText, trimmed == loadedURLText.trimmingCharacters(in: .whitespacesAndNewlines) { return }

        if isFetching {
            // 조회 중에 주소를 바꾸면 그 조회를 버리고 새로 불러온다.
            currentFetchID = nil
            task?.cancel()
        }
        loadedURLText = nil
        retryAlert = nil
        selectedEntryIDs = []
        state = .idle
        guard !trimmed.isEmpty else { return }

        let delay = autoFetchDelay
        autoFetchTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            fetch()
        }
    }
}
