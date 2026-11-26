using System.Runtime.InteropServices;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Stow.Core.Features;

namespace Stow;

/// <summary>완료 알림(Windows 알림 센터)과 탐색기에서 파일 보여 주기.</summary>
internal sealed partial class WindowsNotifier : ICompletionNotifier
{
    private const string FileArgument = "file";
    private bool registered;

    /// <summary>앱 시작 때 한 번. 알림을 누르면 저장한 파일을 탐색기에서 보여 준다(앱이 꺼진 뒤 눌러도 앱이 켜지며 처리).</summary>
    public void Register()
    {
        if (registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) => HandleActivation(args);
            AppNotificationManager.Default.Register();
            registered = true;
        }
        catch (Exception)
        {
            // 알림을 쓸 수 없는 환경이면 알림 없이 계속한다.
        }
    }

    public void HandleActivation(AppNotificationActivatedEventArgs args)
    {
        if (args.Arguments.TryGetValue(FileArgument, out var file) && File.Exists(file)) Reveal(file);
    }

    public void Prepare() => Register();

    public void NotifyCompleted(string title, string file)
    {
        if (!registered) return;
        try
        {
            var notification = new AppNotificationBuilder()
                .AddArgument(FileArgument, file)
                .AddText(title)
                .AddText(Path.GetFileName(file))
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception)
        {
            // 알림 실패는 추출 결과에 영향이 없다.
        }
    }

    /// <summary>안내 알림(누르면 아무것도 하지 않는다). 예: 트레이에서 계속 실행 중. 띄웠으면 true.</summary>
    public bool NotifyInfo(string title, string body)
    {
        if (!registered) return false;
        try
        {
            AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification());
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>탐색기를 열어 파일을 선택한다(셸 API로 직접 열어 명령줄 문자열을 만들지 않는다).</summary>
    public void Reveal(string file)
    {
        var pidl = ILCreateFromPathW(file);
        if (pidl == IntPtr.Zero) return;
        try { _ = SHOpenFolderAndSelectItems(pidl, 0, IntPtr.Zero, 0); }
        finally { ILFree(pidl); }
    }

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr ILCreateFromPathW(string path);

    [LibraryImport("shell32.dll")]
    private static partial int SHOpenFolderAndSelectItems(IntPtr pidlFolder, uint cidl, IntPtr apidl, uint flags);

    [LibraryImport("shell32.dll")]
    private static partial void ILFree(IntPtr pidl);
}
