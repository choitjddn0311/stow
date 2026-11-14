import AppKit
import KeyboardShortcuts
import Observation

/// 메인 창·빠른 추출 패널·메뉴 막대를 잇는다. 둘 다 같은 대기열과 설정을 쓴다.
@MainActor
@Observable
final class AppCoordinator {
    static let mainWindowID = "main"

    let settings: AppSettings
    /// 메인 창의 화면 모델(엔진을 찾지 못했으면 nil)
    let mainModel: ExtractViewModel?
    @ObservationIgnored private let panelController: QuickPanelController?
    /// 메인 창을 여는 동작. SwiftUI 환경의 `openWindow`를 화면이 연결한다.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?

    var queue: ExtractQueue? { mainModel?.queue }

    init(settings: AppSettings, mainModel: ExtractViewModel?, panelModel: QuickPanelModel?) {
        self.settings = settings
        self.mainModel = mainModel
        panelController = panelModel.map(QuickPanelController.init(model:))
        panelModel?.onOpenInMainWindow = { [weak self] text in self?.openInMainWindow(urlText: text) }
    }

    /// 전역 단축키를 등록한다(테스트 호스트에서는 부르지 않는다).
    func registerGlobalShortcut() {
        KeyboardShortcuts.onKeyDown(for: .quickExtract) { [weak self] in
            self?.toggleQuickPanel()
        }
    }

    /// 단축키: 패널이 떠 있으면 닫고, 아니면 연다.
    func toggleQuickPanel() {
        if panelController?.isVisible == true {
            panelController?.model.dismiss()
        } else {
            showQuickPanel()
        }
    }

    /// 빠른 추출 패널을 연다. 이용 고지에 동의하기 전이거나 엔진이 없으면 메인 창을 대신 연다.
    func showQuickPanel() {
        guard let panelController, settings.acceptedNoticeVersion >= UsageNotice.version else {
            openMainWindow()
            return
        }
        panelController.show()
    }

    func openMainWindow() {
        NSApp.activate()
        openMainWindowAction?()
    }

    /// 패널에서 "메인 창에서 고르기": 메인 창에 주소를 넣고(자동으로 불러온다) 창을 연다.
    func openInMainWindow(urlText: String) {
        // 메인 창에서 다른 주소를 불러오는 중이었으면 그 조회는 버리고 이 주소를 불러온다.
        mainModel?.urlText = urlText
        openMainWindow()
    }
}
