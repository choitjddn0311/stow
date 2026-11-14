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

    /// 패널을 닫아 달라는 요청(컨트롤러가 연결한다)
    @ObservationIgnored var onClose: () -> Void = {}
    /// 이 주소를 메인 창에서 열어 달라는 요청(재생목록에서 고르기)
    @ObservationIgnored var onOpenInMainWindow: (String) -> Void = { _ in }

    @ObservationIgnored private let clipboard: any ClipboardReading
    /// 이번에 클립보드에서 채운 주소와 그때의 클립보드 번호
    @ObservationIgnored private var filledFromClipboard: (text: String, changeCount: Int)?
    /// 대기열에 넣은 클립보드 번호. 같은 번호면 다음에 열 때 다시 채우지 않는다.
    @ObservationIgnored private var consumedChangeCount: Int?

    init(extract: ExtractViewModel, clipboard: any ClipboardReading) {
        self.extract = extract
        self.clipboard = clipboard
    }

    /// 패널을 열 때: 이전 입력을 지우고, 클립보드에 새 유튜브 주소가 있으면 채워서 불러온다.
    func prepareForPresentation() async {
        presentationID += 1
        addWhenReady = false
        extract.cancelFetch()
        extract.urlText = ""
        filledFromClipboard = nil

        let changeCount = clipboard.changeCount
        guard changeCount != consumedChangeCount else { return }
        guard let text = ClipboardURL.youTubeText(from: await clipboard.webURLText()) else { return }
        // 클립보드를 읽는 동안 사용자가 직접 입력했으면 덮어쓰지 않는다.
        guard extract.urlText.isEmpty else { return }
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
            addWhenReady = true
        case .idle, .failed:
            guard extract.canFetch else { return }
            addWhenReady = true
            extract.fetch()
            // 주소가 잘못되어 바로 실패하면 기다리지 않는다.
            if extract.stage == .failed { addWhenReady = false }
        }
    }

    /// 불러오기 단계가 바뀔 때 화면이 부른다. Return을 눌러 두었으면 불러온 뒤 바로 추가한다.
    func stageDidChange() {
        guard addWhenReady else { return }
        switch extract.stage {
        case .video, .playlist:
            add()
        case .fetching:
            break
        case .idle, .failed:
            addWhenReady = false
        }
    }

    /// 재생목록을 메인 창에서 열어 영상을 고르게 한다.
    func openInMainWindow() {
        let text = extract.urlText
        dismiss()
        onOpenInMainWindow(text)
    }

    /// Esc·바깥 클릭: 조회를 멈추고 닫는다.
    func dismiss() {
        addWhenReady = false
        extract.cancelFetch()
        onClose()
    }

    private func add() {
        addWhenReady = false
        guard extract.canAddToQueue else { return }
        if let filled = filledFromClipboard,
           filled.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == extract.urlText.trimmingCharacters(in: .whitespacesAndNewlines) {
            consumedChangeCount = filled.changeCount
        }
        extract.addToQueue()
        onClose()
    }
}
