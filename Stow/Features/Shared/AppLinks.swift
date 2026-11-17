import Foundation

/// 앱이 여는 외부 주소(한곳에서 관리해 저장소를 옮겨도 한 번만 고치면 되게).
enum AppLinks {
    /// GitHub 릴리스 목록
    static let releases = URL(string: "https://github.com/choitjddn0311/stow/releases")!
    /// 최신 릴리스
    static let latestRelease = URL(string: "https://github.com/choitjddn0311/stow/releases/latest")!
}
