using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;

namespace Stow;

/// <summary>
/// 직접 만든 진입점. Velopack이 가장 먼저 실행되어야 설치·업데이트·제거 때의 처리(바로 가기 등)를 하고 바로 끝낼 수 있다.
/// 그다음은 XAML이 만들던 Main과 같다.
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }
}
