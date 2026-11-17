import SwiftUI

/// 오류·주의·안내 문구 한 줄(아이콘 + 글).
///
/// 뜻은 아이콘 색으로만 전하지 않는다: 글은 읽기 쉬운 기본 글자색으로 두고(빨강·주황 글자는 밝은 배경에서
/// 대비가 부족하다), 아이콘 모양과 화면 읽기 프로그램용 머리말("오류:")로 종류를 알린다.
struct StatusMessage: View {
    enum Kind {
        case error, warning, info

        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .info: "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            case .info: .secondary
            }
        }

        var accessibilityPrefix: String? {
            switch self {
            case .error: "오류"
            case .warning: "주의"
            case .info: nil
            }
        }
    }

    let kind: Kind
    let text: String
    /// 최대 줄 수. nil이면 제한 없음. 잘리면 전체 문구는 도움말(마우스를 올리면)로 볼 수 있다.
    var lineLimit: Int? = nil
    /// 다른 글 사이에 끼워 넣는 작은 모양(아이콘과 글을 붙이고 주변 글자 크기를 따른다).
    /// 기본 모양은 폼 행의 아이콘 칸에 맞춰 정렬된다.
    var compact = false

    init(_ kind: Kind, _ text: String, lineLimit: Int? = nil, compact: Bool = false) {
        self.kind = kind
        self.text = text
        self.lineLimit = lineLimit
        self.compact = compact
    }

    /// 엔진 오류 문구
    init(error: EngineError, lineLimit: Int? = nil) {
        self.init(.error, error.errorDescription ?? "오류가 발생했습니다.", lineLimit: lineLimit)
    }

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    icon
                    message
                }
            } else {
                Label { message } icon: { icon }
            }
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.accessibilityPrefix.map { "\($0): \(text)" } ?? text)
    }

    private var icon: some View {
        Image(systemName: kind.symbol)
            .foregroundStyle(kind.tint)
    }

    private var message: some View {
        Text(text)
            .foregroundStyle(kind == .info ? .secondary : .primary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}
