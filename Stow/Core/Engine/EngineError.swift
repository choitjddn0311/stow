import Foundation

/// 엔진(yt-dlp, ffmpeg 등) 실행과 추출 과정의 오류. `errorDescription`은 사용자에게 보여 줄 문구다.
enum EngineError: Error, Equatable, Sendable {
    // 입력
    /// 유튜브 URL이 아니다.
    case invalidURL
    /// yt-dlp가 지원하지 않는 주소다.
    case unsupportedURL
    /// 채널 페이지 주소다(영상·재생목록만 지원).
    case channelNotSupported
    /// 재생목록에 받을 수 있는 영상이 없다.
    case emptyPlaylist
    /// 진행 중이거나 예정된 라이브 방송이다.
    case liveNotSupported

    // 영상 접근
    /// 비공개 영상이다.
    case privateVideo
    /// 삭제되었거나, 지역 제한 등으로 볼 수 없다.
    case videoUnavailable
    /// 연령 제한 영상이다(로그인 필요).
    case ageRestricted
    /// 멤버십 전용 등 로그인이 필요하다.
    case loginRequired
    /// 유튜브가 자동화된 요청으로 판단해 막았다.
    case blockedByYouTube
    /// 받을 수 있는 오디오 형식이 없다.
    case noAudioFormat
    /// 고른 영상 포맷(예: MP4의 H.264)으로 받을 수 있는 스트림이 없다.
    case noVideoFormat

    // 환경
    /// 네트워크 연결 문제다.
    case network
    /// 저장 공간이 부족하다.
    case diskFull
    /// 저장 위치에 쓸 권한이 없다.
    case permissionDenied
    /// 저장 폴더가 없다(삭제되었거나 외장 디스크가 분리됨).
    case outputDirectoryMissing

    // 엔진
    /// 앱 번들에 엔진 구성 요소가 없거나 실행할 수 없다.
    case missingComponent(String)
    /// 프로세스를 시작하지 못했다. `code`는 errno 값이다.
    case launchFailed(executable: String, code: Int32)
    /// 오디오 변환(ffmpeg 후처리)에 실패했다.
    case conversionFailed
    /// 영상 정보를 해석하지 못했다.
    case metadataUnreadable
    /// 추출은 끝났지만 결과 파일을 찾지 못했다.
    case outputMissing
    /// 분류하지 못한 yt-dlp 오류. 원문을 함께 보관한다.
    case unknown(String)
}

extension EngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "유튜브 영상 주소가 아닙니다. 주소를 확인해 주세요."
        case .unsupportedURL:
            "지원하지 않는 주소입니다. 유튜브 영상 주소를 입력해 주세요."
        case .channelNotSupported:
            "채널 주소는 지원하지 않습니다. 영상이나 재생목록 주소를 입력해 주세요."
        case .emptyPlaylist:
            "재생목록에 받을 수 있는 영상이 없습니다."
        case .liveNotSupported:
            "진행 중이거나 예정된 라이브 방송은 추출할 수 없습니다."
        case .privateVideo:
            "비공개 영상이라 추출할 수 없습니다."
        case .videoUnavailable:
            "영상을 볼 수 없습니다. 삭제되었거나 지역 제한이 있는 영상일 수 있습니다."
        case .ageRestricted:
            "연령 제한 영상이라 추출할 수 없습니다."
        case .loginRequired:
            "로그인이 필요한 영상(멤버십 전용 등)이라 추출할 수 없습니다."
        case .blockedByYouTube:
            "유튜브가 요청을 일시적으로 막았습니다. 잠시 후 다시 시도해 주세요."
        case .noAudioFormat:
            "이 영상에서 받을 수 있는 오디오를 찾지 못했습니다."
        case .noVideoFormat:
            "이 영상은 고른 포맷으로 받을 수 없습니다. 다른 포맷이나 해상도로 해 보세요."
        case .network:
            "네트워크에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요."
        case .diskFull:
            "저장 공간이 부족합니다."
        case .permissionDenied:
            "저장 위치에 파일을 쓸 권한이 없습니다. 다른 폴더를 선택해 주세요."
        case .outputDirectoryMissing:
            "저장 폴더를 찾을 수 없습니다. 폴더가 삭제되었거나 디스크가 분리되었는지 확인해 주세요."
        case .missingComponent(let name):
            "추출 엔진 구성 요소(\(name))를 찾을 수 없습니다. 앱을 다시 설치해 주세요."
        case .launchFailed(let executable, let code):
            "추출 엔진을 실행하지 못했습니다(\((executable as NSString).lastPathComponent), 오류 \(code))."
        case .conversionFailed:
            "오디오 변환에 실패했습니다."
        case .metadataUnreadable:
            "영상 정보를 읽지 못했습니다."
        case .outputMissing:
            "추출한 파일을 찾지 못했습니다."
        case .unknown:
            "추출 중 알 수 없는 오류가 발생했습니다."
        }
    }
}

/// yt-dlp 오류 출력(stderr의 `ERROR:` 줄)을 `EngineError`로 분류한다.
/// 문구는 yt-dlp 버전에 따라 바뀔 수 있으므로, 분류하지 못하면 `.unknown`에 원문을 남긴다.
/// 경고(`WARNING:`)·진행률 줄은 원인이 아니므로 분류에 쓰지 않는다. `ERROR:` 줄이 없으면
/// (강제 종료, Python 예외 등) 마지막 몇 줄을 `.unknown`에 남긴다.
enum YtDlpErrorMapper {
    /// 앞에서부터 처음 맞는 규칙을 쓴다. 더 구체적인 규칙을 앞에 둔다.
    private static let rules: [(patterns: [String], error: EngineError)] = [
        (["No space left on device"], .diskFull),
        (["Permission denied", "Operation not permitted", "Read-only file system"], .permissionDenied),
        (["Private video"], .privateVideo),
        (["confirm your age", "age-restricted", "inappropriate for some users"], .ageRestricted),
        // 403·429와 "This content isn't available"은 유튜브의 요청 제한·차단이다.
        // 네트워크·삭제 영상 규칙("Unable to download", "Video unavailable")보다 앞에 둔다.
        ([
            "not a bot", "HTTP Error 429", "Too Many Requests", "HTTP Error 403",
            "content isn't available", "content isn\u{2019}t available",
        ], .blockedByYouTube),
        (["members-only", "Join this channel", "requires payment", "Sign in to"], .loginRequired),
        (["live event will begin", "Premieres in", "This live event"], .liveNotSupported),
        (["Unsupported URL"], .unsupportedURL),
        (["Requested format is not available", "No video formats found"], .noAudioFormat),
        ([
            "Video unavailable", "This video is unavailable", "This video has been removed",
            "This video is no longer available", "not made this video available in your country",
            "account associated with this video has been terminated",
        ], .videoUnavailable),
        ([
            "Unable to download", "Failed to resolve", "nodename nor servname", "timed out",
            "Connection reset", "Connection refused", "Network is unreachable", "urlopen error",
            "Remote end closed connection", "SSL:", "HTTP Error 5",
        ], .network),
        (["Postprocessing:", "ffmpeg", "ffprobe"], .conversionFailed),
    ]

    static func map(stderr lines: [String]) -> EngineError {
        let errors = lines.filter { $0.hasPrefix("ERROR:") }
        guard !errors.isEmpty else {
            let tail = lines.filter { !$0.hasPrefix("[stow:") && !$0.hasPrefix("WARNING:") }.suffix(10)
            return .unknown(tail.joined(separator: "\n"))
        }
        let message = errors.joined(separator: "\n")
        for rule in rules where rule.patterns.contains(where: { message.localizedCaseInsensitiveContains($0) }) {
            return rule.error
        }
        return .unknown(message)
    }
}
