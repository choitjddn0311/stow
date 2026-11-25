using System.Globalization;

namespace Stow.Core.Engine;

/// <summary>내려받는 스트림. 영상은 영상·오디오 스트림을 따로 받은 뒤 합친다.</summary>
public enum DownloadPart
{
    /// <summary>영상과 오디오가 함께 든 스트림(합칠 필요 없음) 또는 알 수 없음</summary>
    Combined,
    /// <summary>영상만 있는 스트림</summary>
    Video,
    /// <summary>오디오만 있는 스트림(오디오 추출도 이것)</summary>
    Audio,
}

/// <summary>추출 진행 상황.</summary>
public abstract record ExtractProgress
{
    private ExtractProgress() { }

    /// <summary>내려받는 중. Fraction은 0~1, 전체 크기를 모르면 null.</summary>
    public sealed record Downloading(double? Fraction, double? BytesPerSecond, int? SecondsRemaining, DownloadPart Part = DownloadPart.Combined)
        : ExtractProgress;
    /// <summary>선택한 포맷으로 변환하는 중(ffmpeg).</summary>
    public sealed record Converting : ExtractProgress;
    /// <summary>영상과 오디오를 한 파일로 합치는 중(다시 인코딩하지 않음).</summary>
    public sealed record Merging : ExtractProgress;
    /// <summary>메타데이터(제목·아티스트·챕터)를 넣는 중.</summary>
    public sealed record EmbeddingMetadata : ExtractProgress;

    /// <summary>영상 스트림이 차지하는 몫(영상이 오디오보다 훨씬 크다). 막대 하나에서 영상 단계를 길게 둔다.</summary>
    public const double VideoShare = 0.85;

    /// <summary>영상·오디오를 나눠 받을 때 이 단계의 진행률을 전체 진행률로 바꾼다. 합쳐진 스트림은 그대로.</summary>
    public static double Overall(double fraction, DownloadPart part) => part switch
    {
        DownloadPart.Video => fraction * VideoShare,
        DownloadPart.Audio => VideoShare + fraction * (1 - VideoShare),
        _ => fraction,
    };

    /// <summary>진행률(0~1)을 화면에 보이는 정수 백분율로.</summary>
    public static int DisplayPercent(double fraction) => (int)Math.Round(fraction * 100, MidpointRounding.AwayFromZero);
}

/// <summary>yt-dlp 출력 한 줄에서 읽은 것.</summary>
public abstract record ProgressEvent
{
    private ProgressEvent() { }

    public sealed record Progress(ExtractProgress Value) : ProgressEvent;
    /// <summary>최종 결과 파일 경로(<c>--print after_move:</c>).</summary>
    public sealed record OutputFile(string Path) : ProgressEvent;
}

/// <summary>
/// yt-dlp 출력 한 줄을 해석한다(Mac 앱 ProgressParser와 같은 템플릿). 직접 정한 표식(<c>[stow:...]</c>)이 붙은 줄만 읽는다.
/// </summary>
public static class ProgressParser
{
    public const string DownloadMarker = "[stow:download]";
    public const string PostprocessMarker = "[stow:postprocess]";
    public const string FileMarker = "[stow:file]";

    /// <summary>상태, 받은 바이트, 전체 바이트, 추정 전체 바이트, 속도(B/s), 남은 시간(초), 스트림의 영상·오디오 코덱(없으면 none).</summary>
    public const string DownloadTemplate = "download:" + DownloadMarker + " %(progress.status)s %(progress.downloaded_bytes)s "
        + "%(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s "
        + "%(info.vcodec)s %(info.acodec)s";
    /// <summary>상태(started/finished), 후처리기 이름.</summary>
    public const string PostprocessTemplate = "postprocess:" + PostprocessMarker + " %(progress.status)s %(progress.postprocessor)s";
    public const string FileTemplate = "after_move:" + FileMarker + " %(filepath)s";

    public static ProgressEvent? Parse(string line)
    {
        if (line.StartsWith(FileMarker + " ", StringComparison.Ordinal))
        {
            var path = line[(FileMarker.Length + 1)..];
            return path.Length == 0 ? null : new ProgressEvent.OutputFile(path);
        }
        if (line.StartsWith(DownloadMarker + " ", StringComparison.Ordinal))
        {
            return ParseDownload(line[(DownloadMarker.Length + 1)..]) is { } download ? new ProgressEvent.Progress(download) : null;
        }
        if (line.StartsWith(PostprocessMarker + " ", StringComparison.Ordinal))
        {
            return ParsePostprocess(line[(PostprocessMarker.Length + 1)..]) is { } post ? new ProgressEvent.Progress(post) : null;
        }
        return null;
    }

    private static ExtractProgress? ParseDownload(string fields)
    {
        var values = fields.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // 코덱 두 칸은 없어도 읽는다(합친 스트림으로 본다).
        if (values.Length is not (6 or 8)) return null;
        var status = values[0];
        var downloaded = Number(values[1]);
        var total = Number(values[2]) ?? Number(values[3]);
        var speed = Number(values[4]);
        // 멈춘 연결에서는 남은 시간이 아주 크게 나올 수 있다. int 범위를 넘으면 모르는 것으로 본다.
        var eta = Number(values[5]) is { } e && e >= 0 && e <= int.MaxValue ? (int?)Math.Round(e) : null;

        double? fraction = status == "finished" ? 1
            : downloaded is { } d && total is { } t && t > 0 ? Math.Clamp(d / t, 0, 1)
            : null;
        var part = values.Length == 8 ? (values[6], values[7]) switch
        {
            ("none", _) => DownloadPart.Audio,
            (_, "none") => DownloadPart.Video,
            _ => DownloadPart.Combined,
        } : DownloadPart.Combined;
        return new ExtractProgress.Downloading(fraction, speed, eta, part);
    }

    private static ExtractProgress? ParsePostprocess(string fields)
    {
        var values = fields.Split(' ');
        if (values.Length != 2 || values[0] != "started") return null;
        return values[1] switch
        {
            "ExtractAudio" => new ExtractProgress.Converting(),
            "Merger" => new ExtractProgress.Merging(),
            "Metadata" => new ExtractProgress.EmbeddingMetadata(),
            _ => null,
        };
    }

    /// <summary>yt-dlp는 값이 없으면 NA를 출력한다.</summary>
    private static double? Number(string text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
}
