using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Stow.Core;
using Stow.Core.Engine;
using Stow.Core.Features;
using Stow.Core.Models;
using Stow.Core.Settings;

namespace Stow;

/// <summary>
/// 앱 전체: 설정·대기열을 메인 창과 빠른 추출 창이 함께 쓰고, 트레이 아이콘과 전역 단축키를 맡는다.
/// 창을 닫아도(설정에 따라) 트레이에 남고, 트레이 메뉴의 "종료"로 끝난다.
/// </summary>
public partial class App : Application
{
    private readonly WindowsNotifier notifier = new();
    private MainWindow? mainWindow;
    private QuickExtractWindow? quickWindow;
    private ShellHost? shell;
    private HotKeyController? hotKeys;
    private AppSettings? settings;
    private ExtractQueue? queue;
    private YtDlpClient? client;
    private AppUpdater? appUpdater;
    private EngineUpdateService? engineUpdates;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? updateTimer;
    private bool shuttingDown;
    /// <summary>시작하는 동안 다른 실행이 넘어왔으면 창을 만든 뒤 보인다.</summary>
    private bool showWhenReady;

    public App()
    {
        InitializeComponent();
        // 창을 모두 닫아도(트레이에 남을 때) 앱이 끝나지 않게 한다. 끝낼 때는 Shutdown을 부른다.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // 다른 곳에서 Stow를 다시 실행하면(시작 메뉴 등) 이미 실행 중인 이 앱의 창을 보인다(Program.Main이 넘긴다).
        // 시작 준비 중에 넘어온 것도 놓치지 않게 가장 먼저 연결한다.
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        AppInstance.GetCurrent().Activated += (_, _) => dispatcher.TryEnqueue(() =>
        {
            if (mainWindow is null) showWhenReady = true;
            else ShowMainWindow();
        });

        // 알림을 먼저 등록해야 앱이 꺼진 뒤 누른 완료 알림으로 다시 켜졌을 때도 처리할 수 있다.
        notifier.Register();
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        if (activation is { Kind: ExtendedActivationKind.AppNotification, Data: AppNotificationActivatedEventArgs toast })
        {
            notifier.HandleActivation(toast);
        }
        // 지난 실행이 비정상 종료되며 남긴 작업 폴더 정리(하루 넘은 것만)
        YtDlpClient.CleanStaleWorkDirectories(Path.GetTempPath(), TimeSpan.FromDays(1));

        var dataDirectory = AppInfo.DataDirectory(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData));
        var appSettings = settings = new AppSettings(new JsonFileSettingsStore(Path.Combine(dataDirectory, "settings.json")));
        var engine = EngineLocator.Bundled();
        var engineClient = client = new YtDlpClient(engine);
        var extractQueue = queue = new ExtractQueue(engineClient, notifier);

        var host = shell = new ShellHost(Path.Combine(AppContext.BaseDirectory, "Assets", "Stow.ico"));
        var hotKeyController = hotKeys = new HotKeyController(host, appSettings);
        host.HotKeyPressed += OpenQuickExtract;
        host.TrayClicked += ShowMainWindow;
        host.TrayCommandChosen += command =>
        {
            switch (command)
            {
                case ShellHost.TrayCommand.QuickExtract: OpenQuickExtract(); break;
                case ShellHost.TrayCommand.OpenMainWindow: ShowMainWindow(); break;
                case ShellHost.TrayCommand.CheckUpdates:
                    ShowMainWindow();
                    mainWindow?.CheckUpdatesNow();
                    break;
                case ShellHost.TrayCommand.Quit: Quit(); break;
            }
        };
        host.ShowTrayIcon();
        hotKeyController.Apply();
        extractQueue.PropertyChanged += (_, _) => host.SetToolTip(extractQueue.IsEmpty ? "Stow" : $"Stow · {extractQueue.SummaryText}");
        StartupRegistration.RefreshPathIfEnabled();

        var engineService = engineUpdates = new EngineUpdateService(
            new EngineUpdater(Path.Combine(dataDirectory, "engine", "yt-dlp"), engine), engine, appSettings);
        var updater = appUpdater = new AppUpdater();
        updater.UpdateReady += version =>
            notifier.NotifyInfo($"Stow {version} 업데이트를 받았습니다", "다시 시작하거나 종료할 때 설치됩니다. Stow 창 위쪽 안내에서 바로 설치할 수 있습니다.");

        var window = mainWindow = new MainWindow(new ExtractViewModel(appSettings, engineClient, extractQueue), engine, hotKeyController,
            updater, engineService);
        window.HiddenToTray += OnHiddenToTray;
        window.Closed += (_, _) => Shutdown();

        // Windows 시작 때 실행되었으면 트레이에서 조용히 시작한다(이용 고지에 아직 동의하지 않았으면 창을 보인다).
        var background = Environment.GetCommandLineArgs().Contains(StartupRegistration.BackgroundArgument)
            && appSettings.AcceptedNoticeVersion >= UsageNotice.Version;
        if (!background || showWhenReady) window.Activate();
        StartUpdates(dispatcher, engineService, updater);
    }

    /// <summary>
    /// 엔진: 받아 둔 새 버전을 쓸지 정한 뒤 하루에 한 번 확인·설치. 앱: 켤 때와 1시간마다 확인해 받아 둔다.
    /// </summary>
    private async void StartUpdates(Microsoft.UI.Dispatching.DispatcherQueue dispatcher, EngineUpdateService engineService, AppUpdater updater)
    {
        var timer = updateTimer = dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromHours(1);
        timer.Tick += async (_, _) =>
        {
            await engineService.CheckAsync(manual: false);
            await updater.CheckAsync(manual: false);
        };
        try
        {
            await engineService.ActivateInstalledAsync();
            await engineService.CheckAsync(manual: false);
            await updater.CheckAsync(manual: false);
        }
        catch (Exception)
        {
            // 업데이트 확인이 실패해도 앱은 그대로 쓴다.
        }
        timer.Start();
    }

    private void OpenQuickExtract()
    {
        if (settings is null || client is null || queue is null || mainWindow is not { } window) return;
        // 이용 고지에 동의하기 전에는 메인 창(고지)을 연다.
        if (settings.AcceptedNoticeVersion < UsageNotice.Version)
        {
            ShowMainWindow();
            return;
        }
        if (quickWindow is null)
        {
            var model = new QuickExtractModel(new ExtractViewModel(settings, client, queue), new WindowsClipboard());
            model.OpenInMainWindowRequested += (url, playlist) =>
            {
                ShowMainWindow();
                window.ViewModel.Open(url, playlist);
            };
            quickWindow = new QuickExtractWindow(model);
        }
        quickWindow.Toggle();
    }

    private void ShowMainWindow()
    {
        if (mainWindow is null || shuttingDown) return;
        if (mainWindow.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        mainWindow.AppWindow.Show(true);
        mainWindow.Activate();
        mainWindow.BringToFront();
    }

    /// <summary>창을 닫아 트레이로 갔을 때: 처음 한 번 알린다.</summary>
    private void OnHiddenToTray()
    {
        if (settings is null || settings.TrayNoticeShown) return;
        var shortcut = hotKeys?.IsActive == true ? $"{settings.QuickExtractHotKey}로 빠른 추출을 열 수 있습니다. " : "";
        // 알림을 띄우지 못했으면(알림이 꺼져 있는 등) 다음에 다시 시도한다.
        if (notifier.NotifyInfo("Stow가 트레이에서 계속 실행됩니다", $"{shortcut}끝내려면 트레이 아이콘을 오른쪽 클릭해 종료하세요."))
        {
            settings.TrayNoticeShown = true;
        }
    }

    /// <summary>트레이 메뉴 "종료": 진행 중인 추출을 정리하고(메인 창 닫기 처리) 앱을 끝낸다.</summary>
    private void Quit()
    {
        if (mainWindow is null) { Shutdown(); return; }
        mainWindow.AllowClose = true;
        mainWindow.Close();
    }

    /// <summary>트레이 아이콘·단축키를 정리하고 끝낸다.</summary>
    internal void Shutdown()
    {
        if (shuttingDown) return;
        shuttingDown = true;
        updateTimer?.Stop();
        shell?.Dispose();
        // 받아 둔 앱 업데이트가 있으면 앱이 끝난 뒤 조용히 설치한다.
        appUpdater?.ApplyOnExit();
        Exit();
    }

    /// <summary>업데이트를 설치하려고 다시 시작하기 직전: 트레이 아이콘·단축키를 먼저 정리한다.</summary>
    internal void PrepareForRestart()
    {
        shuttingDown = true;
        updateTimer?.Stop();
        shell?.Dispose();
    }
}

/// <summary>빠른 추출 단축키 등록·변경(설정 화면과 트레이 메뉴 표시를 함께 맞춘다).</summary>
internal sealed class HotKeyController(ShellHost shell, AppSettings settings)
{
    /// <summary>단축키가 등록되어 동작하는지(다른 앱이 이미 쓰면 false)</summary>
    public bool IsActive { get; private set; }

    public event Action? Changed;

    /// <summary>설정의 단축키를 다시 등록한다.</summary>
    public bool Apply()
    {
        IsActive = shell.RegisterHotKey(settings.QuickExtractHotKey);
        shell.SetQuickExtractShortcutText(IsActive ? settings.QuickExtractHotKey.ToString() : null);
        Changed?.Invoke();
        return IsActive;
    }

    /// <summary>새 단축키로 바꾼다. 다른 앱이 쓰고 있으면 바꾸지 않고(이전 단축키를 다시 등록) false.</summary>
    public bool TryChange(HotKey hotKey)
    {
        if (!hotKey.IsValid) return false;
        if (!shell.RegisterHotKey(hotKey))
        {
            Apply();
            return false;
        }
        settings.QuickExtractHotKey = hotKey;
        IsActive = true;
        shell.SetQuickExtractShortcutText(hotKey.ToString());
        Changed?.Invoke();
        return true;
    }

    /// <summary>새 단축키를 입력받는 동안 잠시 끈다(지금 단축키도 입력받을 수 있게).</summary>
    public void Suspend() => shell.UnregisterHotKey();
}
