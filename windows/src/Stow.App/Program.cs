using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Velopack;

namespace Stow;

/// <summary>
/// 직접 만든 진입점. Velopack이 가장 먼저 실행되어야 설치·업데이트·제거 때의 처리(바로 가기 등)를 하고 바로 끝낼 수 있다.
/// 그다음은 XAML이 만들던 Main과 같다(실행 요건 확인 → COM 준비 → 앱 시작).
/// </summary>
public static partial class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build()
            // 제거할 때 완료 알림 등록(알림 센터의 앱 정보)과 "Windows를 시작할 때 실행" 등록도 지운다.
            .OnBeforeUninstallFastCallback(_ =>
            {
                try { AppNotificationManager.Default.UnregisterAll(); } catch (Exception) { }
                try { StartupRegistration.SetEnabled(false); } catch (Exception) { }
            })
            .Run();
        XamlCheckProcessRequirements();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        // 이미 실행 중이면(트레이에 있을 때 다시 실행) 그 앱에 넘기고 끝낸다. 그쪽이 메인 창을 보인다.
        var mainInstance = AppInstance.FindOrRegisterForKey("Stow.Main");
        if (!mainInstance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            // 화면 스레드(STA)에서 기다리면 막힐 수 있어 다른 스레드에서 넘긴다.
            Task.Run(() => mainInstance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return;
        }
        Application.Start(callbackParams =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
    }

    /// <summary>WinUI 실행 요건 확인(맞지 않으면 알아볼 수 있는 오류로 바로 끝난다). XAML이 만드는 Main과 같다.</summary>
    [LibraryImport("Microsoft.ui.xaml.dll")]
    private static partial void XamlCheckProcessRequirements();
}
