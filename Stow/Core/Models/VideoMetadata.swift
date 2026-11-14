import Foundation

/// `yt-dlp -J` 출력에서 필요한 값만 읽은 영상 정보.
struct VideoMetadata: Sendable, Equatable {
    var id: String
    var title: String
    /// 초 단위 길이. 알 수 없으면 nil.
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var uploader: String?
    var webpageURL: URL?
    /// yt-dlp `live_status`: `not_live`, `is_live`, `is_upcoming`, `was_live`, `post_live` 등.
    var liveStatus: String?
}

extension VideoMetadata: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, duration, thumbnail, uploader, channel
        case webpageURL = "webpage_url"
        case liveStatus = "live_status"
        case type = "_type"
    }

    /// 재생목록·채널(`_type`이 `playlist` 등)이면 `EngineError.playlistNotSupported`를 던진다.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(String.self, forKey: .type), type != "video" {
            throw EngineError.playlistNotSupported
        }
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        // URL 값이 잘못되어도 전체 해석이 실패하지 않도록 문자열로 읽는다.
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnail).flatMap(URL.init(string:))
        uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
            ?? container.decodeIfPresent(String.self, forKey: .channel)
        webpageURL = try container.decodeIfPresent(String.self, forKey: .webpageURL).flatMap(URL.init(string:))
        liveStatus = try container.decodeIfPresent(String.self, forKey: .liveStatus)
    }
}
