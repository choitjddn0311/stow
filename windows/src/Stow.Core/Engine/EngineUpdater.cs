using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Stow.Core.Engine;

/// <summary>yt-dlp stable 릴리스 하나.</summary>
/// <param name="Version">예: "2026.10.26"(태그와 <c>yt-dlp --version</c> 출력이 같다)</param>
public sealed record YtDlpRelease(string Version, Uri Binary, Uri Checksums);

public enum EngineUpdateErrorKind { Network, InvalidRelease, ChecksumMismatch, ValidationFailed, InstallFailed }

/// <summary>엔진 업데이트 오류. <see cref="Exception.Message"/>는 사용자에게 보여 줄 문구다.</summary>
public sealed class EngineUpdateException(EngineUpdateErrorKind kind, string? detail = null, Exception? inner = null)
    : Exception(MessageFor(kind), inner)
{
    public EngineUpdateErrorKind Kind { get; } = kind;
    public string? Detail { get; } = detail;

    private static string MessageFor(EngineUpdateErrorKind kind) => kind switch
    {
        EngineUpdateErrorKind.Network => "업데이트 정보를 받지 못했습니다. 인터넷 연결을 확인해 주세요.",
        EngineUpdateErrorKind.InvalidRelease => "업데이트 정보를 해석하지 못했습니다.",
        EngineUpdateErrorKind.ChecksumMismatch => "받은 엔진 파일이 공식 체크섬과 달라 설치하지 않았습니다.",
        EngineUpdateErrorKind.ValidationFailed => "받은 엔진을 실행해 보지 못해 설치하지 않았습니다.",
        _ => "엔진을 설치하지 못했습니다.",
    };
}

/// <summary>HTTP GET(테스트에서는 가짜 응답).</summary>
public interface IHttpFetcher
{
    Task<byte[]> GetAsync(Uri url, CancellationToken cancellationToken = default);
}

public sealed class HttpFetcher : IHttpFetcher
{
    private static readonly HttpClient Client = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        // GitHub API는 User-Agent가 필요하다. 사용자 정보는 넣지 않는다.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Stow");
        return client;
    }

    public async Task<byte[]> GetAsync(Uri url, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        // API 응답 형식 지정은 API 요청에만(릴리스 파일은 CDN으로 리다이렉트된다).
        if (url.Host == "api.github.com") request.Headers.Accept.ParseAdd("application/vnd.github+json");
        try
        {
            using var response = await Client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) throw new EngineUpdateException(EngineUpdateErrorKind.Network, $"HTTP {(int)response.StatusCode}");
            return await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            throw new EngineUpdateException(EngineUpdateErrorKind.Network, error.Message, error);
        }
    }
}

/// <summary>
/// 앱 안에서 yt-dlp를 업데이트한다(Mac 앱 EngineUpdater와 같다).
/// <list type="bullet">
/// <item>받은 yt-dlp는 앱 폴더 밖 <c>storage\&lt;버전&gt;\yt-dlp</c>에 둔다(앱 폴더는 업데이트 때 통째로 바뀐다).</item>
/// <item>공식 <c>SHA2-256SUMS</c>와 대조하고, 번들 Python으로 <c>--version</c>을 실행해 태그와 같을 때만 설치한다.</item>
/// <item>지금 쓰는 버전은 <c>storage\current</c>에 기록한다.</item>
/// </list>
/// </summary>
public sealed class EngineUpdater(string storage, EngineLocator engine, IHttpFetcher? fetcher = null, ProcessRunner? runner = null,
    Func<string, CancellationToken, Task<string>>? versionReader = null)
{
    public static readonly Uri LatestReleaseApi = new("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest");

    private readonly IHttpFetcher fetcher = fetcher ?? new HttpFetcher();
    private readonly ProcessRunner runner = runner ?? new ProcessRunner();

    public string Storage { get; } = storage;
    private string CurrentFile => Path.Combine(Storage, "current");

    /// <summary>받아서 설치한 yt-dlp. 없으면 null.</summary>
    public (string Version, string Path)? Installed()
    {
        try
        {
            var version = File.ReadAllText(CurrentFile).Trim();
            if (!IsValidVersion(version)) return null;
            var path = BinaryPath(version);
            return File.Exists(path) ? (version, path) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>GitHub에서 최신 stable 릴리스를 확인한다.</summary>
    public async Task<YtDlpRelease> LatestReleaseAsync(CancellationToken cancellationToken = default)
    {
        var data = await fetcher.GetAsync(LatestReleaseApi, cancellationToken).ConfigureAwait(false);
        try
        {
            var release = JsonSerializer.Deserialize<GitHubRelease>(data);
            var binary = release?.Assets?.FirstOrDefault(a => a.Name == "yt-dlp")?.BrowserDownloadUrl;
            var sums = release?.Assets?.FirstOrDefault(a => a.Name == "SHA2-256SUMS")?.BrowserDownloadUrl;
            if (release?.TagName is { } tag && IsValidVersion(tag) && binary is not null && sums is not null)
            {
                return new YtDlpRelease(tag, new Uri(binary), new Uri(sums));
            }
        }
        catch (Exception error) when (error is JsonException or UriFormatException)
        {
            throw new EngineUpdateException(EngineUpdateErrorKind.InvalidRelease, error.Message, error);
        }
        throw new EngineUpdateException(EngineUpdateErrorKind.InvalidRelease);
    }

    /// <summary>yt-dlp 파일을 번들 Python으로 실행해 버전을 읽는다.</summary>
    public async Task<string> VersionOfAsync(string ytDlp, CancellationToken cancellationToken = default)
    {
        // 테스트: Python 없이 파일 내용으로 버전을 정한다.
        if (versionReader is not null) return await versionReader(ytDlp, cancellationToken).ConfigureAwait(false);
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(engine.YtDlpCommand(ytDlp, ["--version"]), null, cancellationToken).ConfigureAwait(false);
        }
        catch (ProcessLaunchException error)
        {
            throw new EngineUpdateException(EngineUpdateErrorKind.ValidationFailed, error.Message, error);
        }
        var line = result.Stdout.FirstOrDefault()?.Trim();
        if (!result.IsSuccess || line is null || !IsValidVersion(line))
        {
            throw new EngineUpdateException(EngineUpdateErrorKind.ValidationFailed, string.Join("\n", result.Stderr));
        }
        return line;
    }

    /// <summary>릴리스를 받아 검증하고 설치한 뒤, 설치한 파일 경로를 돌려준다.</summary>
    public async Task<string> InstallAsync(YtDlpRelease release, CancellationToken cancellationToken = default)
    {
        var binary = await fetcher.GetAsync(release.Binary, cancellationToken).ConfigureAwait(false);
        var sums = await fetcher.GetAsync(release.Checksums, cancellationToken).ConfigureAwait(false);
        if (Checksum("yt-dlp", sums) is not { } expected || Sha256(binary) != expected)
        {
            throw new EngineUpdateException(EngineUpdateErrorKind.ChecksumMismatch);
        }

        // 준비 폴더에 쓰고 검증한 뒤 버전 폴더로 옮긴다(검증 전 파일이 쓰이지 않게).
        var staging = Path.Combine(Storage, ".staging-" + Guid.NewGuid().ToString("N"));
        var staged = Path.Combine(staging, "yt-dlp");
        try
        {
            try
            {
                Directory.CreateDirectory(staging);
                await File.WriteAllBytesAsync(staged, binary, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new EngineUpdateException(EngineUpdateErrorKind.InstallFailed, error.Message, error);
            }

            var actual = await VersionOfAsync(staged, cancellationToken).ConfigureAwait(false);
            if (actual != release.Version)
            {
                throw new EngineUpdateException(EngineUpdateErrorKind.ValidationFailed, $"버전 불일치: {actual} ≠ {release.Version}");
            }

            var destination = BinaryPath(release.Version);
            try
            {
                var folder = Path.GetDirectoryName(destination)!;
                if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
                Directory.CreateDirectory(folder);
                File.Move(staged, destination);
                var temp = CurrentFile + ".tmp";
                await File.WriteAllTextAsync(temp, release.Version, cancellationToken).ConfigureAwait(false);
                File.Move(temp, CurrentFile, overwrite: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new EngineUpdateException(EngineUpdateErrorKind.InstallFailed, error.Message, error);
            }
            return destination;
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// <paramref name="keep"/> 버전 폴더만 남기고 지운다(null이면 받은 버전을 모두 지운다).
    /// 실행 중인 yt-dlp가 파일을 읽을 수 있으므로 앱 시작 직후, 추출 전에만 부른다.
    /// </summary>
    public void RemoveVersions(string? keep)
    {
        if (!Directory.Exists(Storage)) return;
        foreach (var item in Directory.EnumerateFileSystemEntries(Storage))
        {
            var name = Path.GetFileName(item);
            if (name == "current" || name == keep) continue;
            try
            {
                if (Directory.Exists(item)) Directory.Delete(item, recursive: true);
                else File.Delete(item);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
            }
        }
        if (keep is null) ClearCurrent();
    }

    /// <summary>받아 둔 버전을 쓰지 않도록 기록만 지운다(실행 중일 수 있는 파일은 다음 앱 시작 때 지운다).</summary>
    public void ClearCurrent()
    {
        try { File.Delete(CurrentFile); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private string BinaryPath(string version) => Path.Combine(Storage, version, "yt-dlp");

    // MARK: 버전·체크섬

    /// <summary>yt-dlp 버전 형식: YYYY.MM.DD 또는 YYYY.MM.DD.N(숫자와 점만)</summary>
    public static bool IsValidVersion(string text)
    {
        var parts = text.Split('.');
        return parts.Length is 3 or 4 && parts.All(p => p.Length > 0 && p.All(char.IsAsciiDigit));
    }

    /// <summary><paramref name="a"/>가 <paramref name="b"/>보다 새 버전이면 true(숫자 단위 비교: 2026.10.26 &lt; 2026.10.26.1 &lt; 2026.11.2).</summary>
    public static bool IsNewer(string a, string b)
    {
        var lhs = a.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var rhs = b.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        for (var i = 0; i < Math.Max(lhs.Length, rhs.Length); i++)
        {
            var l = i < lhs.Length ? lhs[i] : 0;
            var r = i < rhs.Length ? rhs[i] : 0;
            if (l != r) return l > r;
        }
        return false;
    }

    /// <summary><c>SHA2-256SUMS</c> 형식("&lt;hex&gt;  &lt;파일명&gt;")에서 파일 하나의 체크섬을 찾는다.</summary>
    public static string? Checksum(string name, byte[] sums)
    {
        foreach (var line in Encoding.UTF8.GetString(sums).Split('\n'))
        {
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (fields.Length == 2 && (fields[1] == name || fields[1] == "*" + name)) return fields[0].ToLowerInvariant();
        }
        return null;
    }

    public static string Sha256(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("assets")] public List<GitHubAsset>? Assets { get; set; }
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
    }
}
