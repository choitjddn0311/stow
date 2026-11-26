using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Stow.Core.Engine;

namespace Stow;

public partial class App : Application
{
    private Window? window;
    private readonly WindowsNotifier notifier = new();

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // 알림을 먼저 등록해야 앱이 꺼진 뒤 누른 완료 알림으로 다시 켜졌을 때도 처리할 수 있다.
        notifier.Register();
        if (AppInstance.GetCurrent().GetActivatedEventArgs() is { Kind: ExtendedActivationKind.AppNotification, Data: AppNotificationActivatedEventArgs toast })
        {
            notifier.HandleActivation(toast);
        }
        // 지난 실행이 비정상 종료되며 남긴 작업 폴더 정리(하루 넘은 것만)
        YtDlpClient.CleanStaleWorkDirectories(Path.GetTempPath(), TimeSpan.FromDays(1));

        window = new MainWindow(notifier);
        window.Activate();
    }
}
