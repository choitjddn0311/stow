import SwiftUI

/// 화면 전체가 같이 쓰는 간격·크기. 화면마다 다른 숫자를 쓰지 않도록 여기서만 정한다.
enum Metrics {
    /// 행 안에서 아이콘·썸네일과 글 사이
    static let rowSpacing: CGFloat = 12
    /// 제목과 보조 문구 사이
    static let textSpacing: CGFloat = 3
    /// 버튼·작은 요소 사이
    static let controlSpacing: CGFloat = 8
    /// 행 앞 아이콘 칸의 폭(아이콘이 달라도 글 시작 위치가 같게)
    static let rowIconWidth: CGFloat = 20
    /// 메인 창 썸네일 폭(16:9)
    static let thumbnailWidth: CGFloat = 112
    /// 빠른 추출 패널 썸네일 폭(16:9)
    static let compactThumbnailWidth: CGFloat = 64
    /// 아이콘만 있는 버튼이 눌리는 영역(아이콘보다 넓게)
    static let iconButtonSize: CGFloat = 24
}

/// 화면 전환 애니메이션. "동작 줄이기"를 켜면 쓰지 않는다.
enum Motion {
    /// 상태 전환(불러오는 중 → 영상, 대기열 항목 추가·삭제)
    static func stateChange(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    /// 진행 막대가 값 사이를 부드럽게 잇는다.
    static func progress(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: 0.25)
    }

    /// 썸네일이 불러와지며 나타난다.
    static func imageAppear(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}
