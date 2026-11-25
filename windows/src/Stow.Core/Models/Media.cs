using System.Text.Json;
using Stow.Core.Engine;

namespace Stow.Core.Models;

/// <summary><c>yt-dlp -J</c> 출력에서 필요한 값만 읽은 영상 정보.</summary>
public sealed record VideoMetadata(
    string Id,
    string Title,
    double? Duration,
    Uri? ThumbnailUrl,
    string? Uploader,
    Uri? WebpageUrl,
    string? LiveStatus);

/// <summary>재생목록 안의 영상 하나.</summary>
public sealed record PlaylistEntry(string Id, string Title, double? Duration)
{
    /// <summary>이 영상의 주소. 목록의 url 대신 ID로 만든다(형식이 다른 주소가 섞이지 않게).</summary>
    public Uri Url => new($"https://www.youtube.com/watch?v={Id}");

    /// <summary>yt-dlp가 비공개·삭제된 영상에 붙이는 제목. 기본 선택에서 뺀다.</summary>
    public bool IsUnavailable =>
        Title.StartsWith("[Private", StringComparison.Ordinal) || Title.StartsWith("[Deleted", StringComparison.Ordinal)
        || Title.StartsWith("[Unavailable", StringComparison.Ordinal);

    /// <summary>유튜브 영상 ID 형식: 영문·숫자·<c>-</c>·<c>_</c> 11자. 재생목록·채널 ID는 길이가 달라 걸러진다.</summary>
    public static bool IsValidId(string id) =>
        id.Length == 11 && id.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_');
}

/// <summary>재생목록(<c>yt-dlp -J --flat-playlist</c>). 영상 정보는 목록에 나오는 만큼만 있다.</summary>
public sealed record Playlist(string Id, string Title, IReadOnlyList<PlaylistEntry> Entries, int? TotalCount)
{
    /// <summary>한 번에 불러오는 영상 수 상한(<c>--playlist-end</c>). 아주 큰 재생목록이 화면을 멈추지 않게 한다.</summary>
    public const int MaxEntries = 500;

    public bool IsTruncated => (TotalCount ?? 0) > Entries.Count;
}

/// <summary>주소를 조회한 결과: 영상 하나 또는 재생목록.</summary>
public abstract record FetchedMedia
{
    private FetchedMedia() { }

    public sealed record OfVideo(VideoMetadata Metadata) : FetchedMedia;
    public sealed record OfPlaylist(Playlist Playlist) : FetchedMedia;

    /// <summary><c>yt-dlp -J</c>의 JSON을 해석한다. <c>_type</c>이 영상·재생목록이 아니면 지원하지 않는 주소.</summary>
    public static FetchedMedia Parse(string json)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            throw new EngineException(EngineErrorKind.MetadataUnreadable);
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new EngineException(EngineErrorKind.MetadataUnreadable);
            return String(root, "_type") switch
            {
                null or "video" => new OfVideo(ParseVideo(root)),
                "playlist" => new OfPlaylist(ParsePlaylist(root)),
                _ => throw new EngineException(EngineErrorKind.UnsupportedUrl),
            };
        }
    }

    private static VideoMetadata ParseVideo(JsonElement root)
    {
        var id = String(root, "id") ?? throw new EngineException(EngineErrorKind.MetadataUnreadable);
        return new VideoMetadata(
            Id: id,
            Title: String(root, "title") ?? id,
            Duration: Number(root, "duration"),
            // 주소 값이 잘못되어도 전체 해석이 실패하지 않게 한다.
            ThumbnailUrl: Url(String(root, "thumbnail")),
            Uploader: String(root, "uploader") ?? String(root, "channel"),
            WebpageUrl: Url(String(root, "webpage_url")),
            LiveStatus: String(root, "live_status"));
    }

    private static Playlist ParsePlaylist(JsonElement root)
    {
        var id = String(root, "id") ?? throw new EngineException(EngineErrorKind.MetadataUnreadable);
        var entries = new List<PlaylistEntry>();
        var seen = new HashSet<string>();
        if (root.TryGetProperty("entries", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in list.EnumerateArray())
            {
                // 항목 하나를 해석하지 못해도 나머지는 살린다. 영상이 아닌 항목(하위 재생목록, 채널 탭)은 뺀다.
                if (item.ValueKind != JsonValueKind.Object) continue;
                var type = String(item, "_type");
                var extractor = String(item, "ie_key");
                var entryId = String(item, "id");
                if (type is not (null or "url" or "video") || extractor is not (null or "Youtube")
                    || entryId is null || !PlaylistEntry.IsValidId(entryId))
                {
                    continue;
                }
                // 같은 영상이 두 번 들어 있으면 처음 것만 남긴다.
                if (!seen.Add(entryId)) continue;
                entries.Add(new PlaylistEntry(entryId, String(item, "title") ?? "제목 없음", Number(item, "duration")));
            }
        }
        int? total = root.TryGetProperty("playlist_count", out var count) && count.TryGetInt32(out var n) ? n : null;
        return new Playlist(id, String(root, "title") ?? id, entries, total);
    }

    private static string? String(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static double? Number(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : null;

    private static Uri? Url(string? text) => Uri.TryCreate(text, UriKind.Absolute, out var uri) ? uri : null;
}
