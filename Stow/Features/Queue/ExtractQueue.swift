import Foundation
import Observation

/// 추출 대기열(MVP 이후 3번, 사용자 결정 2026-11-14).
///
/// - 한 번에 하나씩 순서대로 추출한다(유튜브 요청 차단 위험을 줄이려고).
/// - 포맷·음질·저장 위치는 대기열에 넣을 때 항목에 고정한다.
/// - 재생목록에서 넣은 항목은 저장 위치 아래 재생목록 이름의 하위 폴더에 저장한다.
/// - 유튜브가 요청을 막으면(403·429) 대기열을 일시 정지하고 "다시 시도" 알림창을 띄운다.
///   사용자가 항목을 추가하거나 "다시 시도"를 누르면 이어 간다.
/// - 완료 알림은 대기열이 모두 끝났을 때 한 번 보낸다(재생목록에서 알림이 쏟아지지 않게).
@MainActor
@Observable
final class ExtractQueue {
    /// 항목 하나의 진행률. 항목마다 따로 관찰해, 진행률이 바뀔 때 그 행만 다시 그린다.
    /// 대기열(메인 액터)에서만 읽고 쓴다.
    @Observable
    final class ItemProgress {
        var value: ExtractProgress?
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let title: String
        let duration: TimeInterval?
        let thumbnailURL: URL?
        /// 대기열에 넣을 때 고정한 포맷·저장 위치
        let options: ExtractOptions
        /// 재생목록 하위 폴더 이름(정리된 이름). nil이면 저장 위치에 바로 저장한다.
        let subfolder: String?
        var status: Status
        /// 추출 중 진행률(`status == .running`일 때)
        let progress: ItemProgress

        init(
            url: URL, title: String, duration: TimeInterval? = nil, thumbnailURL: URL? = nil,
            options: ExtractOptions, subfolder: String? = nil
        ) {
            id = UUID()
            self.url = url
            self.title = title
            self.duration = duration
            self.thumbnailURL = thumbnailURL
            self.options = options
            self.subfolder = subfolder.map(FileNaming.sanitize)
            status = .waiting
            progress = ItemProgress()
        }

        /// 실제로 저장할 폴더
        var destination: URL {
            subfolder.map { options.outputDirectory.appending(path: $0, directoryHint: .isDirectory) } ?? options.outputDirectory
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.status == rhs.status && lhs.title == rhs.title
                && lhs.options == rhs.options && lhs.subfolder == rhs.subfolder
        }
    }

    enum Status: Equatable {
        case waiting
        case running
        case completed(URL)
        case failed(EngineError)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .waiting, .running: false
            }
        }
    }

    /// 유튜브가 요청을 막았을 때 띄우는 알림창.
    struct BlockedAlert: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    private(set) var items: [Item] = []
    /// 유튜브 차단으로 멈춘 상태. "다시 시도"·"재개"·항목 추가로 이어 간다.
    private(set) var isPaused = false
    var blockedAlert: BlockedAlert?

    @ObservationIgnored private let engine: any AudioExtracting
    @ObservationIgnored private let notifier: any CompletionNotifying
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runningID: UUID?
    /// 실행마다 새로 만든다. 같은 항목을 다시 시도했을 때 이전 실행의 진행률이 섞이지 않게 한다.
    @ObservationIgnored private var runToken: UUID?
    /// 이번에 대기열이 돌기 시작한 뒤 완료한 파일(대기열이 비면 한 번 알리고 초기화)
    @ObservationIgnored private var completedInRun: [URL] = []

    init(engine: any AudioExtracting, notifier: any CompletionNotifying) {
        self.engine = engine
        self.notifier = notifier
    }

    // MARK: - 화면에서 쓰는 값

    var isRunning: Bool { runningID != nil }
    var waitingCount: Int { items.count(where: { $0.status == .waiting }) }
    var completedCount: Int { items.count(where: { if case .completed = $0.status { true } else { false } }) }
    var failedCount: Int { items.count(where: { if case .failed = $0.status { true } else { false } }) }
    var hasFinishedItems: Bool { items.contains { $0.status.isFinished } }
    var hasPendingItems: Bool { items.contains { !$0.status.isFinished } }

    // MARK: - 동작

    /// 항목을 넣는다. 차단으로 멈춰 있었다면 사용자가 다시 시작한 것으로 보고 이어 간다.
    func add(_ newItems: [Item]) {
        guard !newItems.isEmpty else { return }
        notifier.prepare()
        items.append(contentsOf: newItems)
        if isPaused { unpause() }
        startNextIfNeeded()
    }

    /// 진행 중이면 취소하고, 대기 중이면 취소 상태로 둔다.
    func cancel(_ id: UUID) {
        if id == runningID {
            task?.cancel()
        } else if let index = index(of: id), items[index].status == .waiting {
            items[index].status = .cancelled
        }
    }

    /// 진행 중이 아닌 항목을 목록에서 뺀다.
    func remove(_ id: UUID) {
        guard id != runningID else { return }
        items.removeAll { $0.id == id }
    }

    /// 실패·취소된 항목을 다시 대기열에 넣는다. 차단으로 멈춰 있었다면 이어 간다.
    func retry(_ id: UUID) {
        guard let index = index(of: id) else { return }
        switch items[index].status {
        case .failed, .cancelled:
            items[index].status = .waiting
            if isPaused { unpause() }
            startNextIfNeeded()
        default:
            break
        }
    }

    /// 대기 중인 항목을 모두 취소하고 진행 중인 항목도 멈춘다.
    func cancelAll() {
        for index in items.indices where items[index].status == .waiting {
            items[index].status = .cancelled
        }
        task?.cancel()
    }

    /// 완료·실패·취소된 항목을 목록에서 지운다.
    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    /// 유튜브 차단으로 멈춘 대기열을 이어 간다(알림창 "다시 시도", 아래 바 "재개").
    func resume() {
        unpause()
        startNextIfNeeded()
    }

    func revealInFinder(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), case .completed(let file) = item.status {
            notifier.revealInFinder(file)
        }
    }

    /// 앱을 종료할 때: 대기 항목은 두고 진행 중인 추출만 취소한 뒤 엔진 프로세스가 끝날 때까지 기다린다.
    func cancelAndWait() async {
        isPaused = true
        task?.cancel()
        await task?.value
    }

    /// 테스트에서 대기열이 빌 때까지 기다린다.
    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    // MARK: - 내부

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// 일시 정지를 풀고, 차단으로 실패한 항목을 다시 대기열에 넣는다.
    private func unpause() {
        blockedAlert = nil
        for index in items.indices where items[index].status == .failed(.blockedByYouTube) {
            items[index].status = .waiting
        }
        isPaused = false
    }

    private func startNextIfNeeded() {
        guard task == nil, !isPaused else { return }
        guard let index = items.firstIndex(where: { $0.status == .waiting }) else {
            finishRun()
            return
        }
        let item = items[index]
        let token = UUID()
        runningID = item.id
        runToken = token
        item.progress.value = nil
        items[index].status = .running
        task = Task { await run(item, token: token) }
    }

    private func run(_ item: Item, token: UUID) async {
        let result: Result<URL, any Error>
        do {
            try prepareDestination(for: item)
            let (stream, continuation) = AsyncStream<ExtractProgress>.makeStream()
            let progressTask = Task {
                for await progress in stream { updateProgress(item, token: token, progress) }
            }
            defer { continuation.finish() }
            let file = try await engine.extract(
                item.url,
                options: ExtractOptions(format: item.options.format, outputDirectory: item.destination),
                fileName: item.title,
                progress: { continuation.yield($0) }
            )
            continuation.finish()
            await progressTask.value
            result = .success(file)
        } catch {
            result = .failure(error)
        }

        if let index = index(of: item.id) {
            switch result {
            case .success(let file):
                items[index].status = .completed(file)
                completedInRun.append(file)
            case .failure(is CancellationError):
                items[index].status = .cancelled
            case .failure(let error):
                let engineError = error as? EngineError ?? .unknown(error.localizedDescription)
                items[index].status = .failed(engineError)
                if engineError == .blockedByYouTube {
                    isPaused = true
                    blockedAlert = BlockedAlert(message: engineError.errorDescription ?? "")
                }
            }
        }
        runningID = nil
        runToken = nil
        task = nil
        startNextIfNeeded()
    }

    /// 진행률은 이 실행(token)의 것이고, 퍼센트·남은 시간·단계가 바뀔 때만 반영한다.
    private func updateProgress(_ item: Item, token: UUID, _ progress: ExtractProgress) {
        guard runToken == token, runningID == item.id else { return }
        if Self.isVisibleChange(from: item.progress.value, to: progress) {
            item.progress.value = progress
        }
    }

    /// 저장 폴더를 확인하고, 재생목록 하위 폴더는 만든다. 저장 위치 자체가 없으면 실패로 둔다.
    private func prepareDestination(for item: Item) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: item.options.outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw EngineError.outputDirectoryMissing }
        if item.subfolder != nil {
            do {
                try fileManager.createDirectory(at: item.destination, withIntermediateDirectories: true)
            } catch {
                throw EngineError.permissionDenied
            }
        }
    }

    /// 대기열이 비면 이번에 완료한 것을 한 번 알린다.
    private func finishRun() {
        guard !completedInRun.isEmpty else { return }
        let files = completedInRun
        completedInRun = []
        let title = files.count == 1 ? "1개 추출 완료" : "\(files.count)개 추출 완료"
        notifier.notifyCompleted(title: title, file: files[files.count - 1])
    }

    private static func isVisibleChange(from shown: ExtractProgress?, to new: ExtractProgress) -> Bool {
        switch (shown, new) {
        case (.downloading(let oldFraction, _, let oldETA, let oldPart)?, .downloading(let newFraction, _, let newETA, let newPart)):
            percent(oldFraction) != percent(newFraction) || oldETA != newETA || oldPart != newPart
        default:
            shown != new
        }
    }

    private static func percent(_ fraction: Double?) -> Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }
}
