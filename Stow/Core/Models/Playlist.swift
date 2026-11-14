import Foundation

/// 재생목록(`yt-dlp -J --flat-playlist`). 영상 정보는 목록에 나오는 만큼만 있다(썸네일·채널 없음).
struct Playlist: Sendable, Equatable {
    /// 한 번에 불러오는 영상 수 상한(`YtDlpArguments`의 `--playlist-end`). 아주 큰 재생목록이 화면을 멈추지 않게 한다.
    static let maxEntries = 500

    var id: String
    var title: String
    var entries: [PlaylistEntry]
    /// 재생목록 전체 영상 수(yt-dlp `playlist_count`). 상한 때문에 일부만 불러왔으면 `entries.count`보다 크다.
    var totalCount: Int? = nil

    var isTruncated: Bool { (totalCount ?? 0) > entries.count }
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

    /// 유튜브 영상 ID 형식: 영문·숫자·`-`·`_` 11자. 재생목록(`PL…`)·채널(`UC…`) ID는 길이가 달라 걸러진다.
    static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
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
        case totalCount = "playlist_count"
    }

    /// 항목 하나를 해석하지 못해도 나머지는 살린다. 영상이 아닌 항목(하위 재생목록, 채널 탭)은 뺀다.
    private struct LenientEntry: Decodable {
        let entry: PlaylistEntry?

        private enum CodingKeys: String, CodingKey {
            case id, title, duration
            case type = "_type"
            case extractor = "ie_key"
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            let type = (try? container?.decodeIfPresent(String.self, forKey: .type)) ?? nil
            let extractor = (try? container?.decodeIfPresent(String.self, forKey: .extractor)) ?? nil
            guard type == nil || type == "url" || type == "video",
                  extractor == nil || extractor == "Youtube",
                  let id = try? container?.decode(String.self, forKey: .id), PlaylistEntry.isValidID(id)
            else {
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
        // 같은 영상이 두 번 들어 있으면 처음 것만 남긴다(선택·화면이 ID로 구분하므로).
        var seen = Set<String>()
        entries = (try container.decodeIfPresent([LenientEntry].self, forKey: .entries) ?? [])
            .compactMap(\.entry)
            .filter { seen.insert($0.id).inserted }
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
    }
}
