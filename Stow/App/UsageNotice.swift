import AppKit
import SwiftUI

/// 첫 실행 이용 고지. 문구를 바꾸면 `version`을 올려 사용자에게 다시 보여 준다.
/// MVP 문구는 초안이며 상용 배포 전 법률 검토가 필요하다(PROJECT.md 6장).
enum UsageNotice {
    static let version = 1
    static let title = "Stow 이용 안내"
    static let paragraphs = [
        "Stow는 본인이 저작권을 가지고 있거나 사용 허락을 받은 영상의 오디오를 추출하는 도구입니다.",
        "다른 사람의 저작물을 허락 없이 내려받거나 배포하면 저작권법이나 YouTube 이용약관을 위반할 수 있으며, 그에 따른 책임은 사용자에게 있습니다.",
    ]
    static let quitButton = "종료"
    static let acceptButton = "동의하고 시작"
}

struct UsageNoticeView: View {
    let onAccept: () -> Void
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(UsageNotice.title, systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            ForEach(UsageNotice.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(UsageNotice.quitButton, action: onQuit)
                Button(UsageNotice.acceptButton, action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
    }
}

#Preview {
    UsageNoticeView(onAccept: {})
}
