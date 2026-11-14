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
                Label(
                    (engineError ?? .missingComponent("bin")).errorDescription ?? "",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
                .padding(32)
            }
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}
