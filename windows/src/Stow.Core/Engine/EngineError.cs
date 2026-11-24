namespace Stow.Core.Engine;

/// <summary>엔진(yt-dlp, ffmpeg 등) 실행과 추출 과정의 오류 종류. Mac 앱의 EngineError와 같다.</summary>
public enum EngineErrorKind
{
    // 입력
    InvalidUrl,
    UnsupportedUrl,
    ChannelNotSupported,
    EmptyPlaylist,
    LiveNotSupported,
    // 영상 접근
    PrivateVideo,
    VideoUnavailable,
    AgeRestricted,
    LoginRequired,
    BlockedByYouTube,
    NoAudioFormat,
    NoVideoFormat,
    // 환경
    Network,
    DiskFull,
    PermissionDenied,
    OutputDirectoryMissing,
    /// <summary>저장 경로가 Windows 경로 길이 한도를 넘는다.</summary>
    PathTooLong,
    // 엔진
    MissingComponent,
    LaunchFailed,
    ConversionFailed,
    MetadataUnreadable,
    OutputMissing,
    Unknown,
}

/// <summary>사용자에게 보여 줄 문구(<see cref="Exception.Message"/>)를 가진 엔진 오류. <see cref="Detail"/>은 원문·구성 요소 이름.</summary>
public sealed class EngineException(EngineErrorKind kind, string? detail = null, Exception? inner = null)
    : Exception(MessageFor(kind, detail), inner)
{
    public EngineErrorKind Kind { get; } = kind;
    public string? Detail { get; } = detail;

    /// <summary>같은 주소로 다시 해 볼 만한 오류(일시적인 문제).</summary>
    public bool IsWorthRetrying => Kind is EngineErrorKind.Network or EngineErrorKind.BlockedByYouTube
        or EngineErrorKind.MetadataUnreadable or EngineErrorKind.Unknown;

    public static string MessageFor(EngineErrorKind kind, string? detail = null) => kind switch
    {
        EngineErrorKind.InvalidUrl => "유튜브 영상 주소가 아닙니다. 주소를 확인해 주세요.",
        EngineErrorKind.UnsupportedUrl => "지원하지 않는 주소입니다. 유튜브 영상 주소를 입력해 주세요.",
        EngineErrorKind.ChannelNotSupported => "채널 주소는 지원하지 않습니다. 영상이나 재생목록 주소를 입력해 주세요.",
        EngineErrorKind.EmptyPlaylist => "재생목록에 받을 수 있는 영상이 없습니다.",
        EngineErrorKind.LiveNotSupported => "진행 중이거나 예정된 라이브 방송은 추출할 수 없습니다.",
        EngineErrorKind.PrivateVideo => "비공개 영상이라 추출할 수 없습니다.",
        EngineErrorKind.VideoUnavailable => "영상을 볼 수 없습니다. 삭제되었거나 지역 제한이 있는 영상일 수 있습니다.",
        EngineErrorKind.AgeRestricted => "연령 제한 영상이라 추출할 수 없습니다.",
        EngineErrorKind.LoginRequired => "로그인이 필요한 영상(멤버십 전용 등)이라 추출할 수 없습니다.",
        EngineErrorKind.BlockedByYouTube => "유튜브가 요청을 일시적으로 막았습니다. 잠시 후 다시 시도해 주세요.",
        EngineErrorKind.NoAudioFormat => "이 영상에서 받을 수 있는 오디오를 찾지 못했습니다.",
        EngineErrorKind.NoVideoFormat => "이 영상은 고른 포맷으로 받을 수 없습니다. 다른 포맷으로 해 보세요.",
        EngineErrorKind.Network => "네트워크에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요.",
        EngineErrorKind.DiskFull => "저장 공간이 부족합니다.",
        EngineErrorKind.PermissionDenied => "저장 위치에 파일을 쓸 권한이 없습니다. 다른 폴더를 선택해 주세요.",
        EngineErrorKind.OutputDirectoryMissing => "저장 폴더를 찾을 수 없습니다. 폴더가 삭제되었거나 디스크가 분리되었는지 확인해 주세요.",
        EngineErrorKind.PathTooLong => "저장 위치의 경로가 너무 깁니다. 더 짧은 경로의 폴더를 선택해 주세요.",
        EngineErrorKind.MissingComponent => $"추출 엔진 구성 요소({detail})를 찾을 수 없습니다. 앱을 다시 설치해 주세요.",
        EngineErrorKind.LaunchFailed => $"추출 엔진을 실행하지 못했습니다({Path.GetFileName(detail ?? "")}).",
        EngineErrorKind.ConversionFailed => "오디오 변환에 실패했습니다.",
        EngineErrorKind.MetadataUnreadable => "영상 정보를 읽지 못했습니다.",
        EngineErrorKind.OutputMissing => "추출한 파일을 찾지 못했습니다.",
        _ => "추출 중 알 수 없는 오류가 발생했습니다.",
    };
}

/// <summary>
/// yt-dlp 오류 출력(stderr의 <c>ERROR:</c> 줄)을 <see cref="EngineErrorKind"/>로 분류한다. Mac 앱과 같은 규칙.
/// 분류하지 못하면 Unknown에 원문을 남긴다. <c>ERROR:</c> 줄이 없으면 마지막 몇 줄을 남긴다.
/// </summary>
public static class YtDlpErrorMapper
{
    /// <summary>앞에서부터 처음 맞는 규칙을 쓴다. 더 구체적인 규칙을 앞에 둔다.</summary>
    private static readonly (string[] Patterns, EngineErrorKind Kind)[] Rules =
    [
        (["No space left on device", "There is not enough space on the disk"], EngineErrorKind.DiskFull),
        (["Permission denied", "Operation not permitted", "Read-only file system", "Access is denied"], EngineErrorKind.PermissionDenied),
        (["Private video"], EngineErrorKind.PrivateVideo),
        (["confirm your age", "age-restricted", "inappropriate for some users"], EngineErrorKind.AgeRestricted),
        // 403·429와 "This content isn't available"은 유튜브의 요청 제한·차단이다. 네트워크·삭제 영상 규칙보다 앞에 둔다.
        (["not a bot", "HTTP Error 429", "Too Many Requests", "HTTP Error 403", "content isn't available", "content isn’t available"],
            EngineErrorKind.BlockedByYouTube),
        (["members-only", "Join this channel", "requires payment", "Sign in to"], EngineErrorKind.LoginRequired),
        (["live event will begin", "Premieres in", "This live event"], EngineErrorKind.LiveNotSupported),
        (["Unsupported URL"], EngineErrorKind.UnsupportedUrl),
        (["Requested format is not available", "No video formats found"], EngineErrorKind.NoAudioFormat),
        (["Video unavailable", "This video is unavailable", "This video has been removed", "This video is no longer available",
          "not made this video available in your country", "account associated with this video has been terminated"],
            EngineErrorKind.VideoUnavailable),
        (["Unable to download", "Failed to resolve", "nodename nor servname", "getaddrinfo failed", "timed out",
          "Connection reset", "Connection refused", "Network is unreachable", "urlopen error",
          "Remote end closed connection", "SSL:", "HTTP Error 5"], EngineErrorKind.Network),
        (["Postprocessing:", "ffmpeg", "ffprobe"], EngineErrorKind.ConversionFailed),
    ];

    /// <param name="video">영상을 받던 중이면 true. "고른 형식이 없음"을 영상 포맷 문구로 바꾼다
    /// (형식이 하나도 없는 "No video formats found"는 포맷을 바꿔도 안 되므로 그대로).</param>
    public static EngineException Map(IReadOnlyList<string> stderr, bool video = false)
    {
        var errors = stderr.Where(l => l.StartsWith("ERROR:", StringComparison.Ordinal)).ToList();
        if (errors.Count == 0)
        {
            var tail = stderr.Where(l => !l.StartsWith("[stow:", StringComparison.Ordinal) && !l.StartsWith("WARNING:", StringComparison.Ordinal))
                .TakeLast(10);
            return new EngineException(EngineErrorKind.Unknown, string.Join("\n", tail));
        }
        var message = string.Join("\n", errors);
        if (video && message.Contains("Requested format is not available", StringComparison.OrdinalIgnoreCase))
        {
            return new EngineException(EngineErrorKind.NoVideoFormat, message);
        }
        foreach (var (patterns, kind) in Rules)
        {
            if (patterns.Any(p => message.Contains(p, StringComparison.OrdinalIgnoreCase))) return new EngineException(kind, message);
        }
        return new EngineException(EngineErrorKind.Unknown, message);
    }
}
