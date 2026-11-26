using Stow.Core.Features;
using Stow.Core.Settings;

namespace Stow.Core.Engine;

/// <summary>직접 확인·되돌리기의 결과(화면에 그대로 보여 준다).</summary>
public sealed record EngineUpdateResult(string Title, string Detail, bool IsError = false);

/// <summary>
/// 앱 안 엔진(yt-dlp) 업데이트 흐름(Mac 앱 EngineUpdateCoordinator와 같다: 자동 확인 + 자동 설치, stable).
/// <list type="bullet">
/// <item>앱 시작(한 번): 받아 둔 버전이 번들보다 새롭고 실제로 실행되면 그것을 쓴다. 아니면 지우고 번들을 쓴다.
/// 옛 버전 파일은 이때만 지운다(추출 중 삭제 방지).</item>
/// <item>자동 확인: 마지막 확인 뒤 하루가 지났을 때만. 실패하면 확인 시각을 남기지 않아 다음 기회에 다시 시도한다.</item>
/// <item>"앱에 들어 있는 엔진으로 되돌리기": 그 버전은 자동으로 다시 설치하지 않는다.</item>
/// </list>
/// 새 엔진은 다음 추출부터 쓴다. 화면 스레드에서 부른다.
/// </summary>
public sealed class EngineUpdateService(EngineUpdater updater, EngineLocator engine, AppSettings settings, Func<DateTimeOffset>? now = null)
    : ObservableObject
{
    public static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);

    private readonly Func<DateTimeOffset> now = now ?? (() => DateTimeOffset.Now);
    private string? bundledVersion = engine.BundledYtDlpVersion;
    private bool activated;

    private string? activeVersion;
    /// <summary>지금 쓰는 yt-dlp 버전(알면)</summary>
    public string? ActiveVersion { get => activeVersion; private set => Set(ref activeVersion, value, alsoChanged: nameof(IsUsingDownloadedEngine)); }

    private bool isChecking;
    public bool IsChecking { get => isChecking; private set => Set(ref isChecking, value); }

    public bool IsUsingDownloadedEngine => engine.YtDlpOverride is not null;

    /// <summary>받아 둔 버전을 쓸지 정한다. 실행당 한 번만 한다.</summary>
    public async Task ActivateInstalledAsync()
    {
        if (activated) return;
        activated = true;
        var bundled = await ResolvedBundledVersionAsync();
        ActiveVersion = bundled;

        // 번들 버전을 모르거나, 받아 둔 버전이 더 새롭지 않거나, 되돌린 버전이거나, 실행되지 않으면 쓰지 않는다.
        if (updater.Installed() is not { } installed || bundled is null || !EngineUpdater.IsNewer(installed.Version, bundled)
            || installed.Version == settings.RejectedEngineVersion
            || await TryVersionAsync(installed.Path) != installed.Version)
        {
            updater.RemoveVersions(null);
            return;
        }
        updater.RemoveVersions(installed.Version);
        engine.YtDlpOverride = installed.Path;
        ActiveVersion = installed.Version;
        Notify(nameof(IsUsingDownloadedEngine));
    }

    /// <summary>확인하고 새 버전이 있으면 설치한다. 자동 확인(<paramref name="manual"/> false)은 하루에 한 번만, 결과는 null.</summary>
    public async Task<EngineUpdateResult?> CheckAsync(bool manual, CancellationToken cancellationToken = default)
    {
        if (IsChecking) return manual ? new("엔진 업데이트를 확인하는 중입니다.", "잠시 후 다시 시도해 주세요.") : null;
        if (!manual && settings.LastEngineCheck is { } last && now() - last < CheckInterval) return null;
        IsChecking = true;
        try
        {
            var current = await CurrentVersionAsync();
            var latest = await updater.LatestReleaseAsync(cancellationToken);
            if (latest.Version == settings.RejectedEngineVersion)
            {
                settings.LastEngineCheck = now();
                return manual ? new("새로 설치할 엔진이 없습니다.", $"최신 버전 {latest.Version}은 되돌린 버전이라 설치하지 않았습니다.") : null;
            }
            if (!EngineUpdater.IsNewer(latest.Version, current ?? "0"))
            {
                settings.LastEngineCheck = now();
                return manual ? new("추출 엔진이 최신 버전입니다.", $"yt-dlp {current ?? latest.Version}") : null;
            }
            var installed = await updater.InstallAsync(latest, cancellationToken);
            engine.YtDlpOverride = installed;
            ActiveVersion = latest.Version;
            Notify(nameof(IsUsingDownloadedEngine));
            // 성공했을 때만 기록한다(실패하면 다음 확인 때 다시 시도).
            settings.LastEngineCheck = now();
            return manual
                ? new("추출 엔진을 업데이트했습니다.", $"yt-dlp {(current is null ? "" : current + " → ")}{latest.Version}. 다음 추출부터 새 엔진을 씁니다.")
                : null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (EngineUpdateException error)
        {
            // 자동 확인의 실패는 조용히 넘어간다.
            return manual ? new("엔진 업데이트를 확인하지 못했습니다.", error.Message, IsError: true) : null;
        }
        finally
        {
            IsChecking = false;
        }
    }

    /// <summary>"앱에 들어 있는 엔진으로 되돌리기"</summary>
    public EngineUpdateResult RevertToBundled()
    {
        if (!IsUsingDownloadedEngine) return new("앱에 들어 있는 엔진을 쓰고 있습니다.", "되돌릴 업데이트가 없습니다.");
        var rejected = ActiveVersion;
        if (rejected is not null) settings.RejectedEngineVersion = rejected;
        updater.ClearCurrent();
        engine.YtDlpOverride = null;
        ActiveVersion = bundledVersion;
        Notify(nameof(IsUsingDownloadedEngine));
        return new("앱에 들어 있는 엔진으로 되돌렸습니다.",
            $"다음 추출부터 yt-dlp {bundledVersion}을 씁니다."
            + (rejected is null ? "" : $" {rejected} 버전은 자동으로 다시 설치하지 않고, 더 새 버전이 나오면 받습니다."));
    }

    /// <summary>지금 쓰는 버전. 모르면 실행해서 읽고, 받은 엔진이 실행되지 않으면 번들 엔진으로 돌아간다.</summary>
    private async Task<string?> CurrentVersionAsync()
    {
        if (ActiveVersion is { } known) return known;
        if (await TryVersionAsync(engine.YtDlp) is { } version)
        {
            ActiveVersion = version;
            return version;
        }
        if (IsUsingDownloadedEngine)
        {
            engine.YtDlpOverride = null;
            updater.ClearCurrent();
            ActiveVersion = await ResolvedBundledVersionAsync();
            Notify(nameof(IsUsingDownloadedEngine));
        }
        return ActiveVersion;
    }

    private async Task<string?> ResolvedBundledVersionAsync() =>
        bundledVersion ??= await TryVersionAsync(engine.BundledYtDlp);

    private async Task<string?> TryVersionAsync(string path)
    {
        try { return await updater.VersionOfAsync(path); }
        catch (EngineUpdateException) { return null; }
    }
}
