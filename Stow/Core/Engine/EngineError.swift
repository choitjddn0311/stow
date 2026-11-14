import Foundation

/// 엔진(yt-dlp, ffmpeg 등) 실행과 관련된 오류.
/// 3단계에서 yt-dlp 오류 출력 매핑을 추가한다.
enum EngineError: Error, Equatable, Sendable {
    /// 앱 번들에 엔진 구성 요소가 없거나 실행할 수 없다.
    case missingComponent(String)
    /// 프로세스를 시작하지 못했다. `code`는 errno 값이다.
    case launchFailed(executable: String, code: Int32)
}

extension EngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingComponent(let name):
            "추출 엔진 구성 요소(\(name))를 찾을 수 없습니다. 앱을 다시 설치해 주세요."
        case .launchFailed(let executable, let code):
            "추출 엔진을 실행하지 못했습니다(\((executable as NSString).lastPathComponent), 오류 \(code))."
        }
    }
}
