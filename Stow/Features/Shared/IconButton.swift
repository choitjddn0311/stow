import SwiftUI

/// 아이콘만 있는 버튼. 눌리는 영역을 아이콘보다 넓게 잡고, 도움말과 화면 읽기 프로그램용 이름을 함께 붙인다.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Metrics.iconButtonSize, height: Metrics.iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 행 앞 아이콘: 회색 선 SF Symbol(색 배지는 이모지처럼 보여 쓰지 않는다, 사용자 결정 2026-11-15).
struct RowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.rowIconWidth)
            .accessibilityHidden(true)
    }
}
