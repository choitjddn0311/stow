import Foundation

/// 사용자가 붙여 넣은 문자열이 유튜브 영상 URL인지 확인한다(PROJECT.md 데이터 흐름 1단계).
/// 영상 ID 형식 등 세부 검증은 yt-dlp에 맡긴다.
enum YouTubeURL {
    private static let hosts: Set<String> = ["youtube.com", "youtu.be"]
    /// 재생목록·채널 페이지 경로. yt-dlp가 모든 영상을 처리하므로 미리 거부한다(MVP는 단일 영상만).
    private static let collectionPathPrefixes = ["/playlist", "/@", "/channel/", "/c/", "/user/", "/feed/"]

    /// 유튜브 영상 URL이면 정규화한 URL을 돌려준다.
    /// - 스킴이 없으면(예: `youtu.be/abc`) https로 본다.
    /// - 유튜브가 아니면 `.invalidURL`, 재생목록·채널 페이지면 `.playlistNotSupported`를 던진다.
    static func parse(_ input: String) throws(EngineError) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 스킴은 문자열 맨 앞에서만 찾는다(쿼리 안의 "https://"는 스킴이 아니다).
        let hasScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        let candidate = hasScheme ? trimmed : "https://" + trimmed
        guard
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), isYouTubeHost(host),
            components.path.count > 1,
            let url = components.url
        else {
            throw .invalidURL
        }
        let path = components.path.lowercased()
        if host != "youtu.be", collectionPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            throw .playlistNotSupported
        }
        return url
    }

    /// `youtube.com`, `youtu.be`와 그 하위 도메인(www, m, music 등).
    private static func isYouTubeHost(_ host: String) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
