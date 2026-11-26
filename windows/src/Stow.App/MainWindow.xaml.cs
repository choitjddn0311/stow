using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Stow.Core;
using Stow.Core.Engine;
using Stow.Core.Features;
using Stow.Core.Models;
using Stow.Core.Settings;
using Windows.Graphics;
using Windows.System;

namespace Stow;

public sealed partial class MainWindow : Window
{
    /// <summary>처음 열 때의 창 크기(배율 100% 기준). 두 칸이 보이는 너비.</summary>
    private const int InitialWidth = 1040;
    private const int InitialHeight = 760;

    private readonly EngineLocator engine = EngineLocator.Bundled();
    /// <summary>코드에서 컨트롤 값을 맞추는 동안 바뀜 이벤트를 무시한다.</summary>
    private bool updatingControls;
    /// <summary>컨트롤 다시 만들기를 한 번으로 모은다(설정 하나를 바꿔도 알림이 여러 개 온다).</summary>
    private bool rebuildPending;
    /// <summary>창을 닫으며 진행 중인 추출을 정리하는 중</summary>
    private bool closing;

    public ExtractViewModel ViewModel { get; }

    internal MainWindow(WindowsNotifier notifier)
    {
        var dataDirectory = AppInfo.DataDirectory(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        var settings = new AppSettings(new JsonFileSettingsStore(Path.Combine(dataDirectory, "settings.json")));
        var client = new YtDlpClient(engine);
        ViewModel = new ExtractViewModel(settings, client, new ExtractQueue(client, notifier));

        InitializeComponent();
        var informational = typeof(MainWindow).Assembly
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion ?? "0.0.0";
        Title = $"Stow {AppInfo.DisplayVersion(informational)}";
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Stow.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        ApplyBackdrop();
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)Math.Round(InitialWidth * scale), (int)Math.Round(InitialHeight * scale)));

        var missing = engine.MissingComponents();
        EngineInfoBar.IsOpen = missing.Count > 0;
        EngineInfoBar.Message = $"앱을 다시 설치해 주세요. 없는 구성 요소: {string.Join(", ", missing)}";

        // 종류·포맷이 바뀔 때만 컨트롤을 다시 만든다(음질·해상도는 고른 컨트롤이 이미 그 값이다).
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppSettings.MediaKind) or nameof(AppSettings.AudioFormatKind) or nameof(AppSettings.VideoFormat))
            {
                ScheduleRebuild();
            }
        };
        UpdateOutputControls();
        RootGrid.Loaded += OnLoaded;
        AppWindow.Closing += OnClosing;
    }

    /// <summary>클릭 처리가 끝난 뒤 한 번 다시 만든다(누른 버튼을 그 클릭 안에서 지우지 않게).</summary>
    private void ScheduleRebuild()
    {
        if (rebuildPending) return;
        rebuildPending = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            rebuildPending = false;
            UpdateOutputControls();
        });
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        RootGrid.Loaded -= OnLoaded;
        if (ViewModel.Settings.AcceptedNoticeVersion < UsageNotice.Version && !await ShowUsageNoticeAsync())
        {
            Application.Current.Exit();
            return;
        }
        UrlBox.Focus(FocusState.Programmatic);
        await CheckEngineAsync();
    }

    /// <summary>엔진이 이 PC에서 실행되는지 시작할 때 확인한다(파일은 있는데 실행이 안 되는 경우를 첫 추출 전에 알린다).</summary>
    private async Task CheckEngineAsync()
    {
        if (engine.MissingComponents().Count > 0) return;  // 이미 위에서 안내함
        try
        {
            var failed = (await Task.Run(() => EngineCheck.RunAsync(engine, new ProcessRunner()))).Where(r => !r.IsOk).ToList();
            if (failed.Count == 0) return;
            EngineInfoBar.Title = "추출 엔진을 실행하지 못했습니다";
            EngineInfoBar.Message = "앱을 다시 설치해 주세요. 백신 프로그램이 막았을 수도 있습니다. "
                + string.Join(" / ", failed.Select(r => $"{r.Name}: {r.Detail}"));
            EngineInfoBar.IsOpen = true;
        }
        catch (Exception)
        {
            // 확인 자체가 실패해도 앱은 쓸 수 있다(추출할 때 오류로 알린다).
        }
    }

    /// <summary>
    /// 창을 닫을 때 진행 중인 추출이 있으면 취소하고 정리(작업 폴더 삭제)가 끝날 때까지 잠깐(최대 5초) 기다린 뒤 닫는다.
    /// </summary>
    private async void OnClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (closing || !ViewModel.Queue.IsRunning) return;
        args.Cancel = true;
        closing = true;
        await Task.WhenAny(ViewModel.Queue.CancelAndWaitAsync(), Task.Delay(TimeSpan.FromSeconds(5)));
        Close();
    }

    /// <summary>첫 실행 이용 고지. 동의하면 true, "종료"면 false.</summary>
    private async Task<bool> ShowUsageNoticeAsync()
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 420 };
        for (var i = 0; i < UsageNotice.Paragraphs.Count; i++)
        {
            var text = new TextBlock { Text = UsageNotice.Paragraphs[i], TextWrapping = TextWrapping.Wrap };
            if (i > 0) text.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            body.Children.Add(text);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = UsageNotice.Title,
            Content = body,
            PrimaryButtonText = UsageNotice.AcceptButton,
            CloseButtonText = UsageNotice.QuitButton,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return false;
        ViewModel.Settings.AcceptedNoticeVersion = UsageNotice.Version;
        return true;
    }

    // MARK: 출력 설정 컨트롤

    /// <summary>설정에 맞춰 종류·포맷·음질(해상도) 컨트롤과 설명을 맞춘다.</summary>
    private void UpdateOutputControls()
    {
        updatingControls = true;
        try
        {
            var settings = ViewModel.Settings;
            var video = settings.MediaKind == MediaKind.Video;
            AudioKindButton.IsChecked = !video;
            VideoKindButton.IsChecked = video;
            KindIcon.Glyph = video ? "" : "";

            FormatButtons.Children.Clear();
            var options = video
                ? new[] { ("MP4", "mp4"), ("최고 화질", "best") }
                : new[] { ("MP3", "mp3"), ("WAV", "wav"), ("FLAC", "flac") };
            var current = video
                ? (settings.VideoFormat == VideoFormat.Mp4 ? "mp4" : "best")
                : settings.AudioFormatKind switch { AudioFormatKind.Wav => "wav", AudioFormatKind.Flac => "flac", _ => "mp3" };
            foreach (var (label, tag) in options)
            {
                var button = new ToggleButton { Content = label, Tag = tag, IsChecked = tag == current };
                button.Click += OnFormatClick;
                FormatButtons.Children.Add(button);
            }

            QualityBox.Items.Clear();
            if (video)
            {
                QualityLabel.Text = "해상도";
                QualityIcon.Glyph = "";
                QualityDescription.Text = "고른 해상도가 없으면 그보다 낮은 것 중 가장 높은 해상도";
                QualityBox.Visibility = Visibility.Visible;
                foreach (var resolution in settings.VideoFormat.Resolutions())
                {
                    QualityBox.Items.Add(new ComboBoxItem { Content = DisplayText.Name(resolution), Tag = resolution });
                }
                QualityBox.SelectedIndex = settings.VideoFormat.Resolutions().ToList().IndexOf(settings.VideoResolution);
            }
            else if (settings.AudioFormatKind == AudioFormatKind.Mp3)
            {
                QualityLabel.Text = "음질";
                QualityIcon.Glyph = "";
                QualityDescription.Text = "";
                QualityBox.Visibility = Visibility.Visible;
                foreach (var bitrate in new[] { Mp3Bitrate.Kbps320, Mp3Bitrate.Kbps192, Mp3Bitrate.Kbps128 })
                {
                    QualityBox.Items.Add(new ComboBoxItem { Content = $"{(int)bitrate} kbps", Tag = bitrate });
                }
                QualityBox.SelectedIndex = settings.Mp3Bitrate switch { Mp3Bitrate.Kbps192 => 1, Mp3Bitrate.Kbps128 => 2, _ => 0 };
            }
            else
            {
                QualityLabel.Text = "음질";
                QualityIcon.Glyph = "";
                QualityDescription.Text = "무손실(원본 샘플레이트 유지)";
                QualityBox.Visibility = Visibility.Collapsed;
            }

            FormatNote.Text = DisplayText.FormatNote(settings.Format)
                + (video ? " 대기열에 넣는 순간의 포맷·저장 위치로 받습니다." : " 대기열에 넣는 순간의 포맷·저장 위치로 추출합니다.");
        }
        finally
        {
            updatingControls = false;
        }
    }

    private void OnKindClick(object sender, RoutedEventArgs e)
    {
        var kind = (string)((FrameworkElement)sender).Tag == "video" ? MediaKind.Video : MediaKind.Audio;
        // 이미 고른 것을 다시 누르면 토글 버튼이 꺼지므로 상태를 되돌린다(바뀌면 설정 알림으로 다시 만든다).
        if (ViewModel.Settings.MediaKind == kind) ScheduleRebuild();
        else ViewModel.Settings.MediaKind = kind;
    }

    private void OnFormatClick(object sender, RoutedEventArgs e)
    {
        var settings = ViewModel.Settings;
        var before = settings.Format;
        switch ((string)((FrameworkElement)sender).Tag)
        {
            case "mp3": settings.AudioFormatKind = AudioFormatKind.Mp3; break;
            case "wav": settings.AudioFormatKind = AudioFormatKind.Wav; break;
            case "flac": settings.AudioFormatKind = AudioFormatKind.Flac; break;
            case "mp4": settings.VideoFormat = VideoFormat.Mp4; break;
            case "best": settings.VideoFormat = VideoFormat.Best; break;
        }
        if (settings.Format == before) ScheduleRebuild();  // 같은 것을 다시 눌러 꺼진 토글 되돌리기
    }

    private void OnQualityChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updatingControls || QualityBox.SelectedItem is not ComboBoxItem { Tag: { } tag }) return;
        switch (tag)
        {
            case Mp3Bitrate bitrate: ViewModel.Settings.Mp3Bitrate = bitrate; break;
            case VideoResolution resolution: ViewModel.Settings.VideoResolution = resolution; break;
        }
    }

    private async void OnChooseFolder(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) ViewModel.Settings.OutputDirectory = folder.Path;
    }

    // MARK: 주소·불러오기

    private void OnUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        ViewModel.Submit();
    }

    private void OnFetch(object sender, RoutedEventArgs e) => ViewModel.Fetch();
    private void OnCancelFetch(object sender, RoutedEventArgs e) => ViewModel.CancelFetch();
    private void OnRetryFetch(object sender, RoutedEventArgs e) => ViewModel.RetryFetch();
    private void OnSelectAll(object sender, RoutedEventArgs e) => ViewModel.SetAllEntriesSelected(true);
    private void OnSelectNone(object sender, RoutedEventArgs e) => ViewModel.SetAllEntriesSelected(false);

    private void OnAddToQueue(object sender, RoutedEventArgs e)
    {
        ViewModel.AddToQueue();
        UrlBox.Focus(FocusState.Programmatic);
    }

    // MARK: 대기열

    private void OnClearFinished(object sender, RoutedEventArgs e) => ViewModel.Queue.ClearFinished();
    private void OnCancelAll(object sender, RoutedEventArgs e) => ViewModel.Queue.CancelAll();
    private void OnResumeQueue(object sender, RoutedEventArgs e) => ViewModel.Queue.Resume();

    private static QueueItem ItemOf(object sender) => (QueueItem)((FrameworkElement)sender).Tag;
    private void OnRevealItem(object sender, RoutedEventArgs e) => ViewModel.Queue.Reveal(ItemOf(sender));
    private void OnRetryItem(object sender, RoutedEventArgs e) => ViewModel.Queue.Retry(ItemOf(sender));
    private void OnCancelItem(object sender, RoutedEventArgs e) => ViewModel.Queue.Cancel(ItemOf(sender));
    private void OnRemoveItem(object sender, RoutedEventArgs e) => ViewModel.Queue.Remove(ItemOf(sender));

    // MARK: 창

    /// <summary>Windows 11은 Mica, Mica를 쓸 수 없는 Windows 10은 테마에 맞는 단색 배경.</summary>
    private void ApplyBackdrop()
    {
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        else RootGrid.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
