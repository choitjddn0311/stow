using Stow.Core.Features;
using Stow.Core.Updates;
using Velopack;

namespace Stow;

/// <summary>
/// 앱 자동 업데이트(Velopack). 앱을 켤 때와 켜져 있는 동안 1시간마다 Windows 릴리스를 확인하고,
/// 새 버전이 있으면 뒤에서 받아 둔다. 받아 두면 "다시 시작해 설치"를 보이고, 그냥 종료해도 끝날 때 설치한다.
/// 설치 도구로 설치하지 않은 실행(개발 빌드)에서는 동작하지 않는다. 화면 스레드에서 부른다.
/// </summary>
internal sealed class AppUpdater : ObservableObject
{
    private readonly UpdateManager? manager;
    private VelopackAsset? ready;

    public AppUpdater()
    {
        try
        {
            manager = new UpdateManager(new WindowsReleaseSource(WindowsReleaseSource.RepositoryUrl));
            if (!manager.IsInstalled) manager = null;
        }
        catch (Exception)
        {
            manager = null;
        }
        // 지난번에 받아 두고 아직 설치하지 않은 업데이트
        if (manager?.UpdatePendingRestart is { } pending && IsNewer(pending)) Ready = pending;
    }

    /// <summary>자동 업데이트를 쓸 수 있는지(설치 도구로 설치했거나 휴대용 zip일 때)</summary>
    public bool IsSupported => manager is not null;

    private VelopackAsset? Ready
    {
        get => ready;
        set
        {
            ready = value;
            Notify(nameof(ReadyVersion));
            Notify(nameof(IsReady));
            Notify(nameof(StatusText));
        }
    }

    /// <summary>받아 두어 설치할 준비가 된 버전(예: "0.2.1")</summary>
    public string? ReadyVersion => ready?.Version.ToString();
    public bool IsReady => ready is not null;

    private bool isChecking;
    public bool IsChecking
    {
        get => isChecking;
        private set { if (Set(ref isChecking, value)) Notify(nameof(StatusText)); }
    }

    private string? lastResult;
    /// <summary>설정 카드의 설명</summary>
    public string StatusText =>
        !IsSupported ? "설치 파일로 설치한 Stow에서만 자동으로 업데이트합니다."
        : IsReady ? $"Stow {ReadyVersion}을 설치할 준비가 됐습니다. 다시 시작하거나 종료할 때 설치됩니다."
        : IsChecking ? "업데이트를 확인하는 중…"
        : lastResult ?? "켤 때와 켜져 있는 동안 1시간마다 새 버전을 확인합니다.";

    /// <summary>새 버전을 받아 두었다(알림·안내 줄을 띄운다).</summary>
    public event Action<string>? UpdateReady;

    /// <summary>확인하고 새 버전이 있으면 받아 둔다. 직접 확인이면 결과 문구를 남긴다.</summary>
    public async Task CheckAsync(bool manual)
    {
        if (manager is null || IsChecking || IsReady) return;
        IsChecking = true;
        try
        {
            var info = await manager.CheckForUpdatesAsync();
            if (info is null)
            {
                if (manual) lastResult = $"최신 버전입니다(확인 {DateTime.Now:t}).";
                return;
            }
            await manager.DownloadUpdatesAsync(info);
            Ready = info.TargetFullRelease;
            UpdateReady?.Invoke(info.TargetFullRelease.Version.ToString());
        }
        catch (Exception)
        {
            // 자동 확인의 실패는 조용히 넘어간다(다음 확인 때 다시 시도).
            if (manual) lastResult = "업데이트를 확인하지 못했습니다. 인터넷 연결을 확인해 주세요.";
        }
        finally
        {
            IsChecking = false;
        }
    }

    /// <summary>받아 둔 업데이트를 설치하고 다시 시작한다(이 프로세스는 끝난다).</summary>
    public void ApplyAndRestart()
    {
        if (manager is null || ready is null) return;
        manager.ApplyUpdatesAndRestart(ready);
    }

    /// <summary>앱을 끝낼 때: 받아 둔 업데이트가 있으면 앱이 끝난 뒤 조용히 설치한다(다시 켜지 않는다).</summary>
    public void ApplyOnExit()
    {
        if (manager is null || ready is null) return;
        try { manager.WaitExitThenApplyUpdates(ready, silent: true, restart: false); } catch (Exception) { }
    }

    private bool IsNewer(VelopackAsset asset) => manager?.CurrentVersion is not { } current || asset.Version > current;
}
