import AppKit
import SwiftUI

/// 첫 실행 이용 고지. 문구를 바꾸면 `version`을 올려 사용자에게 다시 보여 준다.
/// MVP 문구는 초안이며 상용 배포 전 법률 검토가 필요하다(PROJECT.md 6장).
enum UsageNotice {
    /// 2: 영상 다운로드를 넣으며 "오디오를 추출하는 도구"를 "영상과 오디오를 내려받는 도구"로 바꿈
    static let version = 2
    static let title = "Stow 이용 안내"
    static let paragraphs = [
        "Stow는 본인이 저작권을 가지고 있거나 사용 허락을 받은 영상과 그 오디오를 내려받는 도구입니다.",
        "다른 사람의 저작물을 허락 없이 내려받거나 배포하면 저작권법이나 YouTube 이용약관을 위반할 수 있으며, 그에 따른 책임은 사용자에게 있습니다.",
    ]
    static let quitButton = "종료"
    static let acceptButton = "동의하고 시작"
}

struct UsageNoticeView: View {
    let onAccept: () -> Void
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    /// macOS 경고창 형식: 아이콘 → 제목 → 본문 → 세로로 쌓은 버튼(주 동작이 위).
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityHidden(true)
            Text(UsageNotice.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            // 문단 수가 바뀌어도 모두 보이도록 반복한다(첫 문단은 본문, 나머지는 보조 문구).
            ForEach(Array(UsageNotice.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                Button(action: onAccept) {
                    Text(UsageNotice.acceptButton).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button(action: onQuit) {
                    Text(UsageNotice.quitButton).frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(width: 420)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    UsageNoticeView(onAccept: {})
}
