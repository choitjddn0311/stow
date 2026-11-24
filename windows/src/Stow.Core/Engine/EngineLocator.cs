namespace Stow.Core.Engine;

/// <summary>
/// 앱에 넣은 엔진 파일 위치. 앱 폴더의 <c>engine\</c> 아래에 있다:
/// <c>python\python.exe</c>, <c>yt-dlp</c>(zipimport), <c>deno.exe</c>, <c>ffmpeg.exe</c>, <c>ffprobe.exe</c>.
/// </summary>
public sealed class EngineLocator
{
    public string Directory { get; }
    public string Python => Path.Combine(Directory, "python", "python.exe");
    public string YtDlp => Path.Combine(Directory, "yt-dlp");
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
        foreach (var (name, path) in new[] { ("Python", Python), ("yt-dlp", YtDlp), ("deno", Deno), ("ffmpeg", Ffmpeg), ("ffprobe", Ffprobe) })
        {
            if (!File.Exists(path)) missing.Add(name);
        }
        return missing;
    }

    /// <summary>
    /// yt-dlp 실행 명령: 번들 Python으로 zipimport 버전을 실행한다(<c>python.exe -I -B yt-dlp …</c>).
    /// -I: 사용자 환경(PYTHONPATH, site-packages)을 무시, -B: .pyc를 쓰지 않음(앱 폴더는 쓰기 금지일 수 있다).
    /// </summary>
    public ProcessCommand YtDlpCommand(IEnumerable<string> arguments) =>
        new(Python, ["-I", "-B", YtDlp, .. arguments], PythonEnvironment);

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
