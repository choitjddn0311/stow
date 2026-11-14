import Foundation

/// 재생목록(`yt-dlp -J --flat-playlist`). 영상 정보는 목록에 나오는 만큼만 있다(썸네일·채널 없음).
struct Playlist: Sendable, Equatable {
    var id: String
    var title: String
    var entries: [PlaylistEntry]
}

/// 재생목록 안의 영상 하나.
struct PlaylistEntry: Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var duration: TimeInterval?

    /// 이 영상의 주소. 목록의 `url` 대신 ID로 만든다(형식이 다른 주소가 섞이지 않게).
    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    /// yt-dlp가 비공개·삭제된 영상에 붙이는 제목. 기본 선택에서 뺀다.
    var isUnavailable: Bool {
        title.hasPrefix("[Private") || title.hasPrefix("[Deleted") || title.hasPrefix("[Unavailable")
    }

    /// 유튜브 영상 ID 형식(영문·숫자·`-`·`_`). 다른 문자가 섞인 항목은 주소를 만들지 않는다.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}

/// 주소를 조회한 결과: 영상 하나 또는 재생목록.
enum FetchedMedia: Sendable, Equatable {
    case video(VideoMetadata)
    case playlist(Playlist)
}

extension FetchedMedia: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type = "_type"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case nil, "video":
            self = .video(try VideoMetadata(from: decoder))
        case "playlist":
            self = .playlist(try Playlist(from: decoder))
        default:
            throw EngineError.unsupportedURL
        }
    }
}

extension Playlist: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, entries
    }

    /// 항목 하나를 해석하지 못해도 나머지는 살린다.
    private struct LenientEntry: Decodable {
        let entry: PlaylistEntry?

        private enum CodingKeys: String, CodingKey { case id, title, duration }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            guard let id = try? container?.decode(String.self, forKey: .id), PlaylistEntry.isValidID(id) else {
                entry = nil
                return
            }
            let title = (try? container?.decodeIfPresent(String.self, forKey: .title)) ?? nil
            let duration = (try? container?.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
            entry = PlaylistEntry(id: id, title: title ?? "제목 없음", duration: duration)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        entries = (try container.decodeIfPresent([LenientEntry].self, forKey: .entries) ?? []).compactMap(\.entry)
    }
}
