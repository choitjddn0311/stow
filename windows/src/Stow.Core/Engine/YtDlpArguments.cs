using Stow.Core.Models;

namespace Stow.Core.Engine;

/// <summary>yt-dlp 인자 생성(Mac 앱 YtDlpArguments와 같다). 인자는 배열로만 만들고 셸 문자열을 조합하지 않는다.</summary>
public sealed class YtDlpArguments(EngineLocator engine, IReadOnlyList<string>? additional = null)
{
    /// <summary>모든 실행에 공통으로 넣는 인자.</summary>
    public IReadOnlyList<string> Common =>
    [
        // 사용자의 yt-dlp 설정 파일을 읽지 않는다.
        "--ignore-config",
        "--no-playlist",
        "--color", "never",
        "--ffmpeg-location", engine.FfmpegDirectory,
        "--js-runtimes", "deno:" + engine.Deno,
        .. additional ?? [],
    ];

    /// <summary>
    /// 영상·재생목록 조회(<c>-J</c>): 한 줄 JSON을 stdout에 출력한다. 재생목록은 목록만 읽고(<c>--flat-playlist</c>)
    /// 처음 <see cref="Playlist.MaxEntries"/>개까지만 읽는다.
    /// </summary>
    public IReadOnlyList<string> Metadata(Uri url) =>
    [
        .. Common,
        "--dump-single-json", "--flat-playlist", "--playlist-end", Playlist.MaxEntries.ToString(),
        "--", url.AbsoluteUri,
    ];

    /// <summary>오디오 추출 또는 영상 다운로드. 작업 폴더에 <c>&lt;영상 ID&gt;.&lt;확장자&gt;</c>로 저장한다.</summary>
    public IReadOnlyList<string> Extract(Uri url, OutputFormat format, string workDirectory) =>
    [
        .. Common,
        .. FormatArguments(format),
        "--embed-metadata",
        // 중간 파일과 결과 파일을 모두 작업 폴더에 둔다. "home:"을 붙여 경로의 ":"가 형식 구분자로 해석되지 않게 한다.
        "--paths", "home:" + workDirectory,
        "--paths", "temp:" + workDirectory,
        "--output", "%(id)s.%(ext)s",
        "--newline",
        // --print는 --quiet를 함께 켜므로 진행률 출력을 다시 켠다.
        "--progress",
        "--progress-template", ProgressParser.DownloadTemplate,
        "--progress-template", ProgressParser.PostprocessTemplate,
        "--print", ProgressParser.FileTemplate,
        "--",
        url.AbsoluteUri,
    ];

    /// <summary>포맷별 선택·변환 인자.</summary>
    public static IReadOnlyList<string> FormatArguments(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 mp3 => ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3",
            "--audio-quality", $"{(int)mp3.Bitrate}K"],
        OutputFormat.Wav => ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "wav"],
        OutputFormat.Flac => ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "flac"],
        // H.264 영상(오디오 없는 스트림) + AAC(m4a). 나뉜 스트림이 없으면 처음부터 합쳐진 MP4. 다시 인코딩하지 않는다.
        // HLS(m3u8)는 고르지 않는다(MPEG-TS를 다시 담는 데 번들 ffmpeg에 없는 영상 파서가 필요할 수 있다).
        OutputFormat.Video { Format: VideoFormat.Mp4 } video =>
        [
            "--format", "bv[vcodec^=avc1][protocol!*=m3u8]+ba[ext=m4a][protocol!*=m3u8]/b[ext=mp4][protocol!*=m3u8]",
            .. SortArguments(video.Resolution),
            "--merge-output-format", "mp4",
        ],
        // 가장 높은 해상도의 영상 + 오디오. QuickTime 등에서 열리는 MP4가 되도록 오디오는 AAC를, 같은 해상도면 AV1을 먼저.
        OutputFormat.Video video =>
        [
            "--format", "bv[protocol!*=m3u8]+ba[ext=m4a][protocol!*=m3u8]/bv[protocol!*=m3u8]+ba[protocol!*=m3u8]/b[protocol!*=m3u8]",
            "--format-sort", (video.Resolution == VideoResolution.Best ? "res" : $"res:{(int)video.Resolution}") + ",vcodec:av01",
            "--merge-output-format", "mp4/webm/mkv",
        ],
        _ => throw new ArgumentOutOfRangeException(nameof(format)),
    };

    /// <summary><c>-S res:N</c>: N 이하 중 가장 높은 해상도, 없으면 N보다 높은 것 중 가장 낮은 것.</summary>
    private static IReadOnlyList<string> SortArguments(VideoResolution resolution) =>
        resolution == VideoResolution.Best ? [] : ["--format-sort", $"res:{(int)resolution}"];
}
