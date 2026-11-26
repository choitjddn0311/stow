namespace Stow.Core.Engine;

/// <summary>
/// 앱에 넣은 엔진 파일 위치. 앱 폴더의 <c>engine\</c> 아래에 있다:
/// <c>python\python.exe</c>, <c>yt-dlp</c>(zipimport), <c>deno.exe</c>, <c>ffmpeg.exe</c>, <c>ffprobe.exe</c>.
/// </summary>
public sealed class EngineLocator
{
    public string Directory { get; }
    public string Python => Path.Combine(Directory, "python", "python.exe");
    /// <summary>지금 쓰는 yt-dlp: 앱 안에서 받은 새 버전이 있으면 그것, 아니면 앱에 들어 있는 것.</summary>
    public string YtDlp => ytDlpOverride ?? BundledYtDlp;
    /// <summary>앱에 들어 있는 yt-dlp</summary>
    public string BundledYtDlp => Path.Combine(Directory, "yt-dlp");

    private volatile string? ytDlpOverride;
    /// <summary>앱 안에서 받은 yt-dlp(null이면 앱에 들어 있는 것). 다음 실행부터 쓴다(진행 중인 추출은 그대로).</summary>
    public string? YtDlpOverride { get => ytDlpOverride; set => ytDlpOverride = value; }

    /// <summary>앱에 들어 있는 yt-dlp 버전(엔진 폴더의 <c>yt-dlp.version</c>). 없으면 null.</summary>
    public string? BundledYtDlpVersion
    {
        get
        {
            try
            {
                var text = File.ReadAllText(Path.Combine(Directory, "yt-dlp.version")).Trim();
                return EngineUpdater.IsValidVersion(text) ? text : null;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return null;
            }
        }
    }
    public string Deno => Path.Combine(Directory, "deno.exe");
    public string Ffmpeg => Path.Combine(Directory, "ffmpeg.exe");
    public string Ffprobe => Path.Combine(Directory, "ffprobe.exe");
    /// <summary>yt-dlp <c>--ffmpeg-location</c>에 넘길 폴더(ffmpeg·ffprobe가 있는 곳).</summary>
    public string FfmpegDirectory => Directory;

    public EngineLocator(string directory) => Directory = directory;

    /// <summary>앱 폴더 기준 엔진 위치(<c>AppContext.BaseDirectory\engine</c>).</summary>
    public static EngineLocator Bundled() => new(Path.Combine(AppContext.BaseDirectory, "engine"));

    /// <summary>없는 구성 요소의 이름(모두 있으면 빈 목록).</summary>
    public IReadOnlyList<string> MissingComponents()
    {
        var missing = new List<string>();
        foreach (var (name, path) in new[] { ("Python", Python), ("yt-dlp", BundledYtDlp), ("deno", Deno), ("ffmpeg", Ffmpeg), ("ffprobe", Ffprobe) })
        {
            if (!File.Exists(path)) missing.Add(name);
        }
        return missing;
    }

    /// <summary>
    /// yt-dlp 실행 명령: 번들 Python으로 zipimport 버전을 실행한다(<c>python.exe -I -B yt-dlp …</c>).
    /// -I: 사용자 환경(PYTHONPATH, site-packages)을 무시, -B: .pyc를 쓰지 않음(앱 폴더는 쓰기 금지일 수 있다).
    /// </summary>
    public ProcessCommand YtDlpCommand(IEnumerable<string> arguments) => YtDlpCommand(YtDlp, arguments);

    /// <summary>특정 yt-dlp 파일(받은 새 버전 확인용)을 번들 Python으로 실행하는 명령.</summary>
    public ProcessCommand YtDlpCommand(string ytDlp, IEnumerable<string> arguments) =>
        new(Python, ["-I", "-B", ytDlp, .. arguments], PythonEnvironment);

    /// <summary>Windows 콘솔 코드 페이지와 관계없이 출력을 UTF-8로 받게 한다(한글 제목이 깨지지 않게).</summary>
    public static readonly IReadOnlyDictionary<string, string> PythonEnvironment = new Dictionary<string, string>
    {
        ["PYTHONUTF8"] = "1",
        ["PYTHONIOENCODING"] = "utf-8",
    };
}

/// <summary>실행할 프로그램과 인자(배열). 셸 문자열을 조합하지 않는다.</summary>
public sealed record ProcessCommand(
    string Executable,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string>? Environment = null);
