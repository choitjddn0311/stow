import Foundation

/// 사용자가 붙여 넣은 문자열이 유튜브 URL인지 확인한다(PROJECT.md 데이터 흐름 1단계).
/// 영상 ID 형식 등 세부 검증은 yt-dlp에 맡긴다.
enum YouTubeURL {
    private static let hosts: Set<String> = ["youtube.com", "youtu.be"]

    /// 유튜브 URL이면 정규화한 URL을, 아니면 `EngineError.invalidURL`을 던진다.
    /// 스킴이 없으면(예: `youtu.be/abc`) https로 본다.
    static func parse(_ input: String) throws(EngineError) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), isYouTubeHost(host),
            components.path.count > 1,
            let url = components.url
        else {
            throw .invalidURL
        }
        return url
    }

    /// `youtube.com`, `youtu.be`와 그 하위 도메인(www, m, music 등).
    private static func isYouTubeHost(_ host: String) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
