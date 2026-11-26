using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Features;

/// <summary>화면에 보이는 이름·문구(Mac 앱과 같은 문구).</summary>
public static class DisplayText
{
    /// <summary>예: "MP3 320kbps", "FLAC", "MP4 1080p", "최고 화질", "최고 화질 1440p"</summary>
    public static string Name(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 mp3 => $"MP3 {(int)mp3.Bitrate}kbps",
        OutputFormat.Wav => "WAV",
        OutputFormat.Flac => "FLAC",
        OutputFormat.Video v => v.Resolution == VideoResolution.Best ? Name(v.Format) : $"{Name(v.Format)} {Name(v.Resolution)}",
        _ => "",
    };

    public static string Name(VideoFormat format) => format == VideoFormat.Mp4 ? "MP4" : "최고 화질";

    public static string Name(VideoResolution resolution) => resolution == VideoResolution.Best ? "최고" : $"{(int)resolution}p";

    /// <summary>음질·해상도 없이: "MP3", "MP4", "최고 화질"</summary>
    public static string ShortName(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 => "MP3",
        OutputFormat.Wav => "WAV",
        OutputFormat.Flac => "FLAC",
        OutputFormat.Video v => Name(v.Format),
        _ => "",
    };

    /// <summary>"MP3로 추출", "FLAC으로 추출", "MP4로 받기", "최고 화질로 받기"(영상은 변환 없이 그대로 받으므로 "받기")</summary>
    public static string ActionTitle(OutputFormat format) => format switch
    {
        OutputFormat.Flac => "FLAC으로 추출",
        OutputFormat.Video => $"{ShortName(format)}로 받기",
        _ => $"{ShortName(format)}로 추출",
    };

    /// <summary>출력 섹션 아래 설명(Windows판: 최고 화질은 AV1 재생 확장 안내).</summary>
    public static string FormatNote(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 => "MP3는 대부분의 기기·프로그램에서 재생됩니다.",
        OutputFormat.Wav or OutputFormat.Flac => "무손실(원본 샘플레이트 유지)로 저장합니다.",
        OutputFormat.Video { Format: VideoFormat.Mp4 } => "편집 프로그램(Premiere·DaVinci Resolve 등)에서 바로 열리는 H.264 MP4입니다. 유튜브가 1080p까지만 제공합니다.",
        _ => "가장 높은 화질로 받습니다. 대부분 AV1 코덱의 MP4이며, 재생하려면 Microsoft Store의 'AV1 Video Extension'(무료)이 필요할 수 있습니다.",
    };

    /// <summary>진행 상황 문구. 영상은 영상·오디오를 따로 받으므로 지금 받는 쪽을 밝힌다.</summary>
    public static string Progress(ExtractProgress? progress, OutputFormat format)
    {
        switch (progress)
        {
            case null:
                return "준비 중…";
            case ExtractProgress.Downloading d:
                var verb = (format.IsVideo, d.Part) switch
                {
                    (true, DownloadPart.Video) => "영상 받는 중",
                    (true, DownloadPart.Audio) => "오디오 받는 중",
                    _ => "다운로드 중",
                };
                if (d.Fraction is not { } fraction) return $"{verb}…";
                return $"{verb} {ExtractProgress.DisplayPercent(fraction)}%" + (d.SecondsRemaining is { } s ? $" · 약 {s}초 남음" : "");
            case ExtractProgress.Converting:
                return $"{Name(format)}(으)로 변환 중…";
            case ExtractProgress.Merging:
                return "영상과 오디오를 합치는 중…";
            case ExtractProgress.EmbeddingMetadata:
                return format.IsVideo ? "제목·채널 정보를 넣는 중…" : "제목·아티스트 정보를 넣는 중…";
            default:
                return "";
        }
    }

    /// <summary>325 → "5:25", 3723 → "1:02:03"</summary>
    public static string Duration(double seconds)
    {
        var total = (int)Math.Round(seconds);
        var (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60);
        return hours > 0 ? $"{hours}:{minutes:00}:{secs:00}" : $"{minutes}:{secs:00}";
    }

    /// <summary>화면 읽기용: 325 → "5분 25초"</summary>
    public static string SpokenDuration(double seconds)
    {
        var total = (int)Math.Round(seconds);
        var (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60);
        var parts = new List<string>();
        if (hours > 0) parts.Add($"{hours}시간");
        if (minutes > 0) parts.Add($"{minutes}분");
        if (secs > 0 || parts.Count == 0) parts.Add($"{secs}초");
        return string.Join(" ", parts);
    }
}
