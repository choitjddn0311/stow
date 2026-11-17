import SwiftUI

/// 루트 화면. 이용 고지에 동의하기 전에는 고지를, 동의한 뒤에는 추출 화면을 보여 준다.
struct RootView: View {
    let model: ExtractViewModel?
    let settings: AppSettings
    /// 엔진을 찾지 못했을 때의 오류(앱 번들 손상 등).
    var engineError: EngineError?

    var body: some View {
        Group {
            if settings.acceptedNoticeVersion < UsageNotice.version {
                UsageNoticeView { settings.acceptedNoticeVersion = UsageNotice.version }
            } else if let model {
                ExtractView(model: model)
            } else {
                EngineUnavailableView(error: engineError ?? .missingComponent("bin"))
            }
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

/// 앱 안의 엔진을 찾지 못해 시작할 수 없을 때(앱이 손상됨). 무엇이 문제인지 알리고 다시 받을 곳을 연결한다.
private struct EngineUnavailableView: View {
    let error: EngineError

    var body: some View {
        ContentUnavailableView {
            Label("Stow를 시작할 수 없습니다", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.errorDescription ?? "앱 구성 요소를 찾지 못했습니다. 앱을 다시 설치해 주세요.")
        } actions: {
            Link("최신 버전 받기", destination: AppLinks.latestRelease)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
