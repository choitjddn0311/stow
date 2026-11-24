using Microsoft.UI.Xaml;
using Stow.Core;
using Windows.Graphics;

namespace Stow;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        var version = typeof(MainWindow).Assembly.GetName().Version ?? new Version(0, 0, 0);
        VersionText.Text = $"Windows 버전 {AppInfo.DisplayVersion(version)} · 준비 중";
        // Mac 메인 창과 비슷한 크기(화면 배율은 Windows가 맞춘다)
        AppWindow.Resize(new SizeInt32(640, 800));
    }
}
