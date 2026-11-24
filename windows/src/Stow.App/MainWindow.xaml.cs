using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Stow.Core;
using Stow.Core.Engine;
using Windows.Graphics;

namespace Stow;

public sealed partial class MainWindow : Window
{
    /// <summary>처음 열 때의 창 크기(배율 100% 기준). Mac 메인 창과 비슷하다.</summary>
    private const int InitialWidth = 640;
    private const int InitialHeight = 800;

    public MainWindow()
    {
        InitializeComponent();
        ApplyBackdrop();

        var informational = typeof(MainWindow).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
        VersionText.Text = $"Windows 버전 {AppInfo.DisplayVersion(informational)} · 준비 중";

        // AppWindow.Resize는 실제 픽셀 단위라 화면 배율(예: 150%)을 곱해야 같은 크기로 보인다.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)Math.Round(InitialWidth * scale), (int)Math.Round(InitialHeight * scale)));

        _ = CheckEngineAsync();
    }

    /// <summary>엔진 구성 요소를 하나씩 실행해 버전과 걸린 시간을 보여 준다.</summary>
    private async Task CheckEngineAsync()
    {
        try
        {
            await ShowEngineCheckAsync();
        }
        catch (Exception error)
        {
            // 실행 중 예상하지 못한 문제(파이프 오류 등)도 화면에 보여 준다.
            EngineResults.ItemsSource = new[] { $"✕ 엔진을 확인하지 못했습니다: {error.Message}" };
        }
        finally
        {
            EngineProgress.IsActive = false;
        }
    }

    private async Task ShowEngineCheckAsync()
    {
        var engine = EngineLocator.Bundled();
        var missing = engine.MissingComponents();
        if (missing.Count > 0)
        {
            EngineResults.ItemsSource = new[] { $"✕ 엔진 파일이 없습니다: {string.Join(", ", missing)}", $"위치: {engine.Directory}" };
            return;
        }
        var results = await EngineCheck.RunAsync(engine, new ProcessRunner());
        EngineResults.ItemsSource = results
            .Select(r => $"{(r.IsOk ? "✓" : "✕")} {r.Name} · {r.Elapsed.TotalSeconds:0.0}초 · {r.Detail}")
            .ToList();
    }

    /// <summary>Windows 11은 Mica, Mica를 쓸 수 없는 Windows 10은 테마에 맞는 단색 배경.</summary>
    private void ApplyBackdrop()
    {
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
        }
        else
        {
            RootGrid.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
