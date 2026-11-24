using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Stow.Core;
using Stow.Core.Engine;
using Stow.Core.Models;
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

    private CancellationTokenSource? downloadCancel;

    /// <summary>개발 확인용 다운로드: 주소 조회 → 고른 포맷으로 "다운로드" 폴더에 저장.</summary>
    private async void OnDownload(object sender, RoutedEventArgs e)
    {
        var engine = EngineLocator.Bundled();
        var client = new YtDlpClient(engine);
        OutputFormat format = FormatBox.SelectedIndex switch
        {
            0 => new OutputFormat.Mp3(Mp3Bitrate.Kbps320),
            1 => new OutputFormat.Wav(),
            2 => new OutputFormat.Flac(),
            3 => new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P1080),
            _ => new OutputFormat.Video(VideoFormat.Best, VideoResolution.Best),
        };
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        downloadCancel = new CancellationTokenSource();
        DownloadButton.IsEnabled = false;
        CancelButton.IsEnabled = true;
        DownloadProgress.Value = 0;
        try
        {
            var url = YouTubeUrl.Parse(UrlBox.Text);
            DownloadStatus.Text = "영상 정보를 불러오는 중…";
            var media = await client.FetchMediaAsync(url, downloadCancel.Token);
            var (target, title) = media switch
            {
                FetchedMedia.OfVideo v => (url, v.Metadata.Title),
                // 재생목록은 시험으로 첫 영상만 받는다.
                FetchedMedia.OfPlaylist p => (p.Playlist.Entries[0].Url, p.Playlist.Entries[0].Title),
                _ => throw new InvalidOperationException(),
            };
            var dispatcher = DispatcherQueue;
            var file = await client.ExtractAsync(target, new ExtractOptions(format, downloads), title, progress =>
                dispatcher.TryEnqueue(() => ShowProgress(progress, format)), downloadCancel.Token);
            DownloadProgress.Value = 1;
            DownloadStatus.Text = $"저장했습니다: {file}";
        }
        catch (OperationCanceledException)
        {
            DownloadStatus.Text = "취소했습니다.";
        }
        catch (EngineException error)
        {
            DownloadStatus.Text = "실패: " + error.Message + (error.Detail is { Length: > 0 } d ? $"\n({d})" : "");
        }
        catch (Exception error)
        {
            DownloadStatus.Text = "실패: " + error.Message;
        }
        finally
        {
            DownloadButton.IsEnabled = true;
            CancelButton.IsEnabled = false;
            downloadCancel.Dispose();
            downloadCancel = null;
        }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => downloadCancel?.Cancel();

    private void ShowProgress(ExtractProgress progress, OutputFormat format)
    {
        switch (progress)
        {
            case ExtractProgress.Downloading d:
                var verb = (format.IsVideo, d.Part) switch
                {
                    (true, DownloadPart.Video) => "영상 받는 중",
                    (true, DownloadPart.Audio) => "오디오 받는 중",
                    _ => "다운로드 중",
                };
                if (d.Fraction is { } f)
                {
                    DownloadProgress.Value = format.IsVideo ? ExtractProgress.Overall(f, d.Part) : f;
                    DownloadStatus.Text = $"{verb} {ExtractProgress.DisplayPercent(f)}%" + (d.SecondsRemaining is { } s ? $" · 약 {s}초 남음" : "");
                }
                break;
            case ExtractProgress.Converting:
                DownloadStatus.Text = "변환 중…";
                break;
            case ExtractProgress.Merging:
                DownloadStatus.Text = "영상과 오디오를 합치는 중…";
                break;
            case ExtractProgress.EmbeddingMetadata:
                DownloadStatus.Text = "제목 정보를 넣는 중…";
                break;
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
