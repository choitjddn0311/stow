namespace Stow.Core.Models;

/// <summary>MP3 비트레이트(kbps, 고정 비트레이트).</summary>
public enum Mp3Bitrate
{
    Kbps128 = 128,
    Kbps192 = 192,
    Kbps320 = 320,
}

/// <summary>받을 영상 포맷. 둘 다 다시 인코딩하지 않고 유튜브의 영상·오디오 스트림을 합치기만 한다.</summary>
public enum VideoFormat
{
    /// <summary>편집 프로그램에서 바로 열리는 H.264 + AAC MP4. 유튜브가 H.264를 1080p까지만 제공한다.</summary>
    Mp4,
    /// <summary>가장 높은 화질(4K 이상은 VP9·AV1). 파일 형식(MP4·WebM·MKV)은 받은 스트림에 따라 정해진다.</summary>
    Best,
}

/// <summary>
/// 영상 해상도(세로 픽셀). 고른 해상도가 없으면 그보다 낮은 것 중 가장 높은 해상도를 받는다
/// (그보다 낮은 것도 없으면 가장 낮은 해상도). <see cref="Best"/>는 제한 없이 가장 높은 해상도.
/// </summary>
public enum VideoResolution
{
    Best = 0,
    P2160 = 2160,
    P1440 = 1440,
    P1080 = 1080,
    P720 = 720,
    P480 = 480,
}

public static class VideoFormatExtensions
{
    /// <summary>고를 수 있는 해상도. MP4는 1080p가 상한이다.</summary>
    public static IReadOnlyList<VideoResolution> Resolutions(this VideoFormat format) => format switch
    {
        VideoFormat.Mp4 => [VideoResolution.P1080, VideoResolution.P720, VideoResolution.P480],
        _ => [VideoResolution.Best, VideoResolution.P2160, VideoResolution.P1440, VideoResolution.P1080, VideoResolution.P720, VideoResolution.P480],
    };

    public static VideoResolution DefaultResolution(this VideoFormat format) =>
        format == VideoFormat.Mp4 ? VideoResolution.P1080 : VideoResolution.Best;

    /// <summary>이 포맷에 있는 해상도로 맞춘다: 있으면 그대로, 없으면 그보다 낮은 것 중 가장 높은 것, 그것도 없으면 기본값.</summary>
    public static VideoResolution SupportedResolution(this VideoFormat format, VideoResolution resolution)
    {
        var options = format.Resolutions();
        if (options.Contains(resolution)) return resolution;
        var limit = resolution == VideoResolution.Best ? int.MaxValue : (int)resolution;
        var lower = options.Where(r => r != VideoResolution.Best && (int)r <= limit).ToList();
        return lower.Count > 0 ? lower.MaxBy(r => (int)r) : format.DefaultResolution();
    }
}

/// <summary>결과 포맷: 오디오 추출(MP3·WAV·FLAC) 또는 영상 다운로드.</summary>
public abstract record OutputFormat
{
    private OutputFormat() { }

    public sealed record Mp3(Mp3Bitrate Bitrate) : OutputFormat;
    public sealed record Wav : OutputFormat;
    public sealed record Flac : OutputFormat;
    public sealed record Video(VideoFormat Format, VideoResolution Resolution) : OutputFormat;

    public bool IsVideo => this is Video;

    /// <summary>결과 파일 확장자. 최고 화질 영상은 받은 스트림에 따라 정해지므로 null(결과 파일의 확장자를 쓴다).</summary>
    public string? FileExtension => this switch
    {
        Mp3 => "mp3",
        Wav => "wav",
        Flac => "flac",
        Video { Format: VideoFormat.Mp4 } => "mp4",
        _ => null,
    };
}

/// <summary>추출 옵션.</summary>
public sealed record ExtractOptions(OutputFormat Format, string OutputDirectory);
