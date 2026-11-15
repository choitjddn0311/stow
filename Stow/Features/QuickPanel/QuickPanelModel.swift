import Foundation
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    /// 빠른 추출 패널 열기. 기본값 ⌥⌘Y(사용자 결정 2026-11-14), 설정 창에서 바꿀 수 있다.
    static let quickExtract = Self("quickExtract", initial: .init(.y, modifiers: [.command, .option]))
}

/// 빠른 추출 패널의 동작(MVP 이후 5번, 사용자 결정 2026-11-14).
///
/// - 열 때 클립보드 첫 항목이 유튜브 주소면 채우고 바로 불러온다. 이미 대기열에 넣은 같은 클립보드 내용은 다시 채우지 않는다.
/// - Return은 "대기열에 추가": 불러오는 중이면 끝난 뒤 추가하고, 아직 안 불러왔으면 불러온 뒤 추가한다.
/// - 추가하면 패널을 닫는다(추출은 대기열이 뒤에서 이어 간다).
/// 불러오기·대기열 추가 자체는 메인 창과 같은 `ExtractViewModel`(패널 전용 인스턴스)이 한다.
@MainActor
@Observable
final class QuickPanelModel {
    let extract: ExtractViewModel
    /// Return을 눌렀지만 아직 불러오는 중이라, 끝나면 바로 추가할 상태
    private(set) var addWhenReady = false
    /// 패널을 열 때마다 바뀐다. 화면이 주소란에 초점을 다시 줄 때 쓴다.
    private(set) var presentationID = 0
    /// 패널이 열려 있는지(닫힌 뒤 늦게 끝난 클립보드 읽기·조회 결과를 버리는 데 쓴다)
    private(set) var isPresented = false

    /// 패널을 닫아 달라는 요청(컨트롤러가 연결한다)
    /// `returnFocus`: 닫은 뒤 원래 쓰던 앱으로 초점을 돌려줄지(메인 창을 열 때는 false)
    @ObservationIgnored var onClose: (_ returnFocus: Bool) -> Void = { _ in }
    /// 주소(와 이미 불러온 재생목록)를 메인 창에서 열어 달라는 요청
    @ObservationIgnored var onOpenInMainWindow: (String, Playlist?) -> Void = { _, _ in }
    /// 폴더 선택 창을 띄워 달라는 요청(컨트롤러가 연결한다). 고른 폴더를 돌려준다.
    @ObservationIgnored var onChooseFolder: (URL) -> URL? = { _ in nil }

    @ObservationIgnored private let clipboard: any ClipboardReading
    /// 이번에 클립보드에서 채운 주소와 그때의 클립보드 번호
    @ObservationIgnored private var filledFromClipboard: (text: String, changeCount: Int)?
    /// 대기열에 넣은 클립보드 번호. 같은 번호면 다음에 열 때 다시 채우지 않는다.
    @ObservationIgnored private var consumedChangeCount: Int?
    /// Return을 누른 뒤 조회가 끝나기를 기다리는 작업
    @ObservationIgnored private var pendingAddTask: Task<Void, Never>?

    init(extract: ExtractViewModel, clipboard: any ClipboardReading) {
        self.extract = extract
        self.clipboard = clipboard
    }

    /// 패널을 열 때: 이전 입력을 지우고, 클립보드에 새 유튜브 주소가 있으면 채워서 불러온다.
    func prepareForPresentation() async {
        presentationID += 1
        let presentation = presentationID
        isPresented = true
        cancelPendingAdd()
        extract.cancelFetch()
        extract.urlText = ""
        filledFromClipboard = nil

        let changeCount = clipboard.changeCount
        guard changeCount != consumedChangeCount else { return }
        let text = ClipboardURL.youTubeText(from: await clipboard.webURLText())
        // 읽는 동안 패널이 닫혔거나 다시 열렸거나, 사용자가 직접 입력했으면 쓰지 않는다.
        guard let text, isPresented, presentation == presentationID, extract.urlText.isEmpty else { return }
        // 읽는 동안 클립보드가 바뀌었으면 어느 내용을 읽었는지 알 수 없으므로 채우지 않는다.
        guard clipboard.changeCount == changeCount else { return }
        filledFromClipboard = (text, changeCount)
        extract.urlText = text
        extract.fetch()
    }

    /// Return 또는 "추가" 버튼.
    func submit() {
        switch extract.stage {
        case .video, .playlist:
            add()
        case .fetching:
            addAfterFetch()
        case .idle, .failed:
            guard extract.canFetch else { return }
            extract.fetch()
            // 주소가 잘못되어 바로 실패하면 기다리지 않는다.
            if extract.isFetching { addAfterFetch() }
        }
    }

    /// 재생목록을 메인 창에서 열어 영상을 고르게 한다(불러온 목록을 넘겨 다시 조회하지 않는다).
    func openInMainWindow() {
        let text = extract.urlText
        let playlist: Playlist? = if case .playlist(let playlist) = extract.state { playlist } else { nil }
        dismiss(returnFocus: false)
        onOpenInMainWindow(text, playlist)
    }

    /// 포맷 칩 메뉴. 바꾼 값은 메인 창 기본 설정에도 남는다.
    func select(_ format: AudioFormat) {
        extract.settings.select(format)
    }

    /// 폴더 칩 메뉴의 최근 폴더.
    func selectOutputDirectory(_ url: URL) {
        extract.settings.outputDirectory = url
    }

    /// 폴더 칩 메뉴의 "다른 폴더…". 선택 창이 떠 있는 동안 패널은 닫히지 않는다.
    func chooseOtherFolder() {
        if let url = onChooseFolder(extract.settings.outputDirectory) {
            extract.settings.outputDirectory = url
        }
    }

    /// Esc·바깥 클릭: 조회를 멈추고 닫는다.
    func dismiss(returnFocus: Bool = true) {
        isPresented = false
        cancelPendingAdd()
        extract.cancelFetch()
        onClose(returnFocus)
    }

    /// 테스트에서 Return 뒤 추가가 끝날 때까지 기다린다.
    func waitForPendingAdd() async {
        await pendingAddTask?.value
    }

    // MARK: - 내부

    /// 조회가 끝나면 바로 추가한다. 화면이 그려지지 않는 동안에도 동작하도록 모델이 직접 기다린다.
    private func addAfterFetch() {
        guard pendingAddTask == nil else { return }
        addWhenReady = true
        pendingAddTask = Task { [weak self] in
            guard let self else { return }
            // 기다리는 동안 주소가 바뀌어 새 조회가 시작될 수 있으므로 조회가 없을 때까지 기다린다.
            while extract.isFetching, !Task.isCancelled {
                await extract.waitForTask()
            }
            guard !Task.isCancelled, addWhenReady else { return }
            pendingAddTask = nil
            switch extract.stage {
            case .video, .playlist: add()
            case .idle, .failed, .fetching: addWhenReady = false
            }
        }
    }

    private func cancelPendingAdd() {
        pendingAddTask?.cancel()
        pendingAddTask = nil
        addWhenReady = false
    }

    private func add() {
        cancelPendingAdd()
        guard extract.canAddToQueue else { return }
        if let filled = filledFromClipboard,
           filled.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == extract.urlText.trimmingCharacters(in: .whitespacesAndNewlines) {
            consumedChangeCount = filled.changeCount
        }
        extract.addToQueue()
        isPresented = false
        onClose(true)
    }
}
