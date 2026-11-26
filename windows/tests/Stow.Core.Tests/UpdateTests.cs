using System.Text;
using Stow.Core.Engine;
using Stow.Core.Settings;
using Stow.Core.Updates;
using Velopack.Logging;
using Velopack.Sources;

namespace Stow.Core.Tests;

/// <summary>주소별 가짜 응답. 없는 주소는 네트워크 오류.</summary>
internal sealed class FakeFetcher : IHttpFetcher
{
    public Dictionary<string, byte[]> Responses { get; } = [];
    public int Requests;

    public Task<byte[]> GetAsync(Uri url, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref Requests);
        return Responses.TryGetValue(url.ToString(), out var data)
            ? Task.FromResult(data)
            : throw new EngineUpdateException(EngineUpdateErrorKind.Network);
    }
}

public class EngineUpdaterTests
{
    private const string Binary = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.20/yt-dlp";
    private const string Sums = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.20/SHA2-256SUMS";

    /// <summary>엔진 폴더(번들 yt-dlp 2026.10.26)·저장 폴더·가짜 네트워크. 가짜 yt-dlp 파일 내용이 곧 버전이다.</summary>
    internal static (EngineUpdater Updater, EngineLocator Engine, FakeFetcher Fetcher, string Storage) Make(string latest = "2026.11.20")
    {
        var root = Directory.CreateTempSubdirectory("stow-update-").FullName;
        var engineDir = Path.Combine(root, "engine");
        Directory.CreateDirectory(engineDir);
        File.WriteAllText(Path.Combine(engineDir, "yt-dlp"), "2026.10.26");
        File.WriteAllText(Path.Combine(engineDir, "yt-dlp.version"), "2026.10.26\n");
        var engine = new EngineLocator(engineDir);
        var fetcher = new FakeFetcher();
        SetLatest(fetcher, latest);
        var storage = Path.Combine(root, "data", "engine", "yt-dlp");
        var updater = new EngineUpdater(storage, engine, fetcher, versionReader: async (path, _) =>
        {
            var text = (await File.ReadAllTextAsync(path)).Trim();
            return EngineUpdater.IsValidVersion(text) ? text : throw new EngineUpdateException(EngineUpdateErrorKind.ValidationFailed);
        });
        return (updater, engine, fetcher, storage);
    }

    internal static void SetLatest(FakeFetcher fetcher, string version, string? content = null)
    {
        var binary = Encoding.UTF8.GetBytes(content ?? version);
        fetcher.Responses[EngineUpdater.LatestReleaseApi.ToString()] = Encoding.UTF8.GetBytes($$"""
            {"tag_name":"{{version}}","assets":[
              {"name":"yt-dlp","browser_download_url":"{{Binary}}"},
              {"name":"SHA2-256SUMS","browser_download_url":"{{Sums}}"}]}
            """);
        fetcher.Responses[Binary] = binary;
        fetcher.Responses[Sums] = Encoding.UTF8.GetBytes($"{EngineUpdater.Sha256(Encoding.UTF8.GetBytes(version))}  yt-dlp\n0000  yt-dlp.exe\n");
    }

    [Theory]
    [InlineData("2026.10.26", true)]
    [InlineData("2026.10.26.1", true)]
    [InlineData("2026.10", false)]
    [InlineData("2026.10.x", false)]
    [InlineData("", false)]
    public void VersionFormat(string text, bool valid) => Assert.Equal(valid, EngineUpdater.IsValidVersion(text));

    [Theory]
    [InlineData("2026.11.2", "2026.10.26", true)]
    [InlineData("2026.10.26.1", "2026.10.26", true)]
    [InlineData("2026.10.26", "2026.10.26", false)]
    [InlineData("2026.9.30", "2026.10.1", false)]
    public void VersionOrder(string a, string b, bool newer) => Assert.Equal(newer, EngineUpdater.IsNewer(a, b));

    [Fact]
    public void ChecksumLookup()
    {
        var sums = Encoding.UTF8.GetBytes("ABC123  yt-dlp\r\ndef456 *yt-dlp.exe\n");
        Assert.Equal("abc123", EngineUpdater.Checksum("yt-dlp", sums));
        Assert.Equal("def456", EngineUpdater.Checksum("yt-dlp.exe", sums));
        Assert.Null(EngineUpdater.Checksum("yt-dlp_macos", sums));
    }

    [Fact]
    public async Task InstallsVerifiedRelease()
    {
        var (updater, engine, _, storage) = Make();
        Assert.Equal("2026.10.26", engine.BundledYtDlpVersion);
        var release = await updater.LatestReleaseAsync(TestContext.Current.CancellationToken);
        Assert.Equal("2026.11.20", release.Version);
        var path = await updater.InstallAsync(release, TestContext.Current.CancellationToken);
        Assert.Equal(Path.Combine(storage, "2026.11.20", "yt-dlp"), path);
        Assert.Equal(("2026.11.20", path), updater.Installed());
        Assert.DoesNotContain(Directory.EnumerateDirectories(storage), d => Path.GetFileName(d).StartsWith(".staging", StringComparison.Ordinal));
    }

    [Fact]
    public async Task RejectsChecksumMismatchAndWrongVersion()
    {
        var (updater, _, fetcher, _) = Make();
        SetLatest(fetcher, "2026.11.20", content: "변조된 파일");
        var release = await updater.LatestReleaseAsync(TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<EngineUpdateException>(() => updater.InstallAsync(release, TestContext.Current.CancellationToken));
        Assert.Equal(EngineUpdateErrorKind.ChecksumMismatch, error.Kind);

        // 체크섬은 맞지만 실행해 보니 다른 버전
        fetcher.Responses[Binary] = Encoding.UTF8.GetBytes("2026.11.19");
        fetcher.Responses[Sums] = Encoding.UTF8.GetBytes($"{EngineUpdater.Sha256(Encoding.UTF8.GetBytes("2026.11.19"))}  yt-dlp\n");
        error = await Assert.ThrowsAsync<EngineUpdateException>(() => updater.InstallAsync(release, TestContext.Current.CancellationToken));
        Assert.Equal(EngineUpdateErrorKind.ValidationFailed, error.Kind);
        Assert.Null(updater.Installed());
    }

    [Fact]
    public async Task InvalidReleaseJson()
    {
        var (updater, _, fetcher, _) = Make();
        fetcher.Responses[EngineUpdater.LatestReleaseApi.ToString()] = Encoding.UTF8.GetBytes("""{"tag_name":"nightly","assets":[]}""");
        var error = await Assert.ThrowsAsync<EngineUpdateException>(() => updater.LatestReleaseAsync(TestContext.Current.CancellationToken));
        Assert.Equal(EngineUpdateErrorKind.InvalidRelease, error.Kind);
    }
}

public class EngineUpdateServiceTests
{
    private static (EngineUpdateService Service, EngineUpdater Updater, EngineLocator Engine, FakeFetcher Fetcher, AppSettings Settings, Func<DateTimeOffset> Clock, Action<TimeSpan> Advance) Make(string latest = "2026.11.20")
    {
        var (updater, engine, fetcher, _) = EngineUpdaterTests.Make(latest);
        var settings = new AppSettings(new MemorySettingsStore(), "C:/out");
        var time = new DateTimeOffset(2026, 11, 26, 9, 0, 0, TimeSpan.Zero);
        var service = new EngineUpdateService(updater, engine, settings, () => time);
        return (service, updater, engine, fetcher, settings, () => time, d => time += d);
    }

    [Fact]
    public async Task AutoCheckInstallsOncePerDay()
    {
        var (service, _, engine, fetcher, settings, clock, advance) = Make();
        await service.ActivateInstalledAsync();
        Assert.Equal("2026.10.26", service.ActiveVersion);
        Assert.False(service.IsUsingDownloadedEngine);

        Assert.Null(await service.CheckAsync(manual: false, TestContext.Current.CancellationToken));
        Assert.Equal("2026.11.20", service.ActiveVersion);
        Assert.True(service.IsUsingDownloadedEngine);
        Assert.Equal(engine.YtDlpOverride, engine.YtDlp);
        Assert.Equal(clock(), settings.LastEngineCheck);

        // 하루가 안 지났으면 확인하지 않는다.
        var requests = fetcher.Requests;
        advance(TimeSpan.FromHours(23));
        await service.CheckAsync(manual: false, TestContext.Current.CancellationToken);
        Assert.Equal(requests, fetcher.Requests);

        // 직접 확인은 언제든: 최신이면 알린다.
        var result = await service.CheckAsync(manual: true, TestContext.Current.CancellationToken);
        Assert.Equal("추출 엔진이 최신 버전입니다.", result?.Title);
    }

    [Fact]
    public async Task FailedAutoCheckIsSilentAndRetried()
    {
        var (service, _, _, fetcher, settings, _, _) = Make();
        fetcher.Responses.Clear();
        await service.ActivateInstalledAsync();
        Assert.Null(await service.CheckAsync(manual: false, TestContext.Current.CancellationToken));
        Assert.Null(settings.LastEngineCheck);  // 다음 기회에 다시 시도
        var manual = await service.CheckAsync(manual: true, TestContext.Current.CancellationToken);
        Assert.True(manual?.IsError);
    }

    [Fact]
    public async Task RevertKeepsRejectedVersionFromReinstalling()
    {
        var (service, updater, engine, _, settings, _, _) = Make();
        await service.ActivateInstalledAsync();
        await service.CheckAsync(manual: true, TestContext.Current.CancellationToken);
        Assert.True(service.IsUsingDownloadedEngine);

        var reverted = service.RevertToBundled();
        Assert.Contains("2026.11.20 버전은 자동으로 다시 설치하지 않고", reverted.Detail);
        Assert.False(service.IsUsingDownloadedEngine);
        Assert.Equal(engine.BundledYtDlp, engine.YtDlp);
        Assert.Equal("2026.11.20", settings.RejectedEngineVersion);
        Assert.Null(updater.Installed());

        var result = await service.CheckAsync(manual: true, TestContext.Current.CancellationToken);
        Assert.Equal("새로 설치할 엔진이 없습니다.", result?.Title);
        Assert.False(service.IsUsingDownloadedEngine);
        Assert.Equal("앱에 들어 있는 엔진을 쓰고 있습니다.", service.RevertToBundled().Title);
    }

    [Fact]
    public async Task StartupUsesNewerInstalledEngineOnly()
    {
        var (first, updater, engine, _, settings, _, _) = Make();
        await first.ActivateInstalledAsync();
        await first.CheckAsync(manual: true, TestContext.Current.CancellationToken);

        // 다음 실행: 받아 둔 새 버전을 쓴다.
        engine.YtDlpOverride = null;
        var next = new EngineUpdateService(updater, engine, settings);
        await next.ActivateInstalledAsync();
        Assert.Equal("2026.11.20", next.ActiveVersion);
        Assert.True(next.IsUsingDownloadedEngine);

        // 앱 업데이트로 번들이 같거나 더 새로워지면 받아 둔 것을 지우고 번들을 쓴다.
        engine.YtDlpOverride = null;
        File.WriteAllText(Path.Combine(engine.Directory, "yt-dlp"), "2026.11.20");
        File.WriteAllText(Path.Combine(engine.Directory, "yt-dlp.version"), "2026.11.20");
        var afterAppUpdate = new EngineUpdateService(updater, engine, settings);
        await afterAppUpdate.ActivateInstalledAsync();
        Assert.False(afterAppUpdate.IsUsingDownloadedEngine);
        Assert.Null(updater.Installed());
        Assert.Empty(Directory.EnumerateDirectories(updater.Storage));
    }
}

/// <summary>Velopack 다운로더 대신: 주소별 응답</summary>
internal sealed class FakeDownloader : IFileDownloader
{
    public Dictionary<string, string> Strings { get; } = [];
    public List<string> Requested { get; } = [];

    public Task<string> DownloadString(string url, IDictionary<string, string>? headers = null, double timeout = 30)
    {
        Requested.Add(url);
        return Strings.TryGetValue(url, out var text) ? Task.FromResult(text) : throw new HttpRequestException(url);
    }

    public Task<byte[]> DownloadBytes(string url, IDictionary<string, string>? headers = null, double timeout = 30) =>
        DownloadString(url, headers, timeout).ContinueWith(t => Encoding.UTF8.GetBytes(t.Result), TaskScheduler.Default);

    public Task DownloadFile(string url, string targetFile, Action<int> progress, IDictionary<string, string>? headers = null,
        double timeout = 30, CancellationToken cancelToken = default) => throw new NotSupportedException();
}

public class WindowsReleaseSourceTests
{
    private const string ReleasesJson = """
        [
          {"tag_name":"v1.1.0","name":"Stow 1.1.0","draft":false,"prerelease":false,"published_at":"2026-12-05T00:00:00Z",
           "assets":[{"name":"appcast.xml","browser_download_url":"https://example.invalid/appcast.xml"}]},
          {"tag_name":"win-v0.3.0","name":"Stow for Windows 0.3.0","draft":true,"prerelease":true,"published_at":null,"assets":[]},
          {"tag_name":"win-v0.2.0","name":"Stow for Windows 0.2.0","draft":false,"prerelease":true,"published_at":"2026-12-01T00:00:00Z",
           "assets":[{"name":"releases.win-x64.json","url":"https://api.github.com/a/1","browser_download_url":"https://dl/win-v0.2.0/releases.win-x64.json"}]},
          {"tag_name":"win-v0.1.0","name":"Stow for Windows 0.1.0","draft":false,"prerelease":true,"published_at":"2026-11-26T00:00:00Z",
           "assets":[{"name":"releases.win-x64.json","url":"https://api.github.com/a/2","browser_download_url":"https://dl/win-v0.1.0/releases.win-x64.json"}]}
        ]
        """;

    [Fact]
    public void SelectsPublishedWindowsReleasesNewestFirst()
    {
        var releases = WindowsReleaseSource.Select(ReleasesJson, includePrereleases: true);
        Assert.Equal(["Stow for Windows 0.2.0", "Stow for Windows 0.1.0"], releases.Select(r => r.Name));
        Assert.Equal("https://dl/win-v0.2.0/releases.win-x64.json", releases[0].Assets[0].BrowserDownloadUrl);
        Assert.Empty(WindowsReleaseSource.Select(ReleasesJson, includePrereleases: false));  // Windows 릴리스는 사전 공개
    }

    [Fact]
    public async Task FeedReadsHundredReleasesAndOnlyWindowsFeeds()
    {
        var downloader = new FakeDownloader();
        downloader.Strings["https://api.github.com/repos/choitjddn0311/stow/releases?per_page=100&page=1"] = ReleasesJson;
        downloader.Strings["https://dl/win-v0.2.0/releases.win-x64.json"] =
            """{"Assets":[{"PackageId":"Stow","Version":"0.2.0","Type":"Full","FileName":"Stow-0.2.0-win-x64-full.nupkg","SHA1":"A","SHA256":"B","Size":1}]}""";
        downloader.Strings["https://dl/win-v0.1.0/releases.win-x64.json"] =
            """{"Assets":[{"PackageId":"Stow","Version":"0.1.0","Type":"Full","FileName":"Stow-0.1.0-win-x64-full.nupkg","SHA1":"C","SHA256":"D","Size":1}]}""";
        var source = new WindowsReleaseSource(WindowsReleaseSource.RepositoryUrl, downloader);

        var feed = await source.GetReleaseFeed(NullVelopackLogger.Instance, "Stow", "win-x64");
        Assert.Equal(["0.2.0", "0.1.0"], feed.Assets.Select(a => a.Version.ToString()));
        Assert.DoesNotContain(downloader.Requested, u => u.Contains("appcast", StringComparison.Ordinal));
    }
}
