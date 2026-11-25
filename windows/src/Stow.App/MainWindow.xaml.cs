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

    private readonly WindowsNotifier notifier = new();
    private readonly EngineLocator engine = EngineLocator.Bundled();
    /// <summary>코드에서 컨트롤 값을 맞추는 동안 바뀜 이벤트를 무시한다.</summary>
    private bool updatingControls;

    public ExtractViewModel ViewModel { get; }

    public MainWindow()
    {
        var dataDirectory = AppInfo.DataDirectory(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        var settings = new AppSettings(new JsonFileSettingsStore(Path.Combine(dataDirectory, "settings.json")));
        var client = new YtDlpClient(engine);
        ViewModel = new ExtractViewModel(settings, client, new ExtractQueue(client, notifier));

        InitializeComponent();
        ApplyBackdrop();
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)Math.Round(InitialWidth * scale), (int)Math.Round(InitialHeight * scale)));

        var missing = engine.MissingComponents();
        EngineInfoBar.IsOpen = missing.Count > 0;
        EngineInfoBar.Message = $"앱을 다시 설치해 주세요. 없는 구성 요소: {string.Join(", ", missing)}";

        settings.PropertyChanged += (_, _) => UpdateOutputControls();
        UpdateOutputControls();
        RootGrid.Loaded += OnLoaded;
        Closed += OnClosed;
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
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        // 진행 중인 추출을 끝낸다(엔진 프로세스는 Job Object로 함께 끝난다).
        ViewModel.Queue.CancelAll();
        WindowsNotifier.Unregister();
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
        ViewModel.Settings.MediaKind = (string)((FrameworkElement)sender).Tag == "video" ? MediaKind.Video : MediaKind.Audio;
        UpdateOutputControls();  // 같은 값을 다시 눌러도 버튼 상태를 되돌린다
    }

    private void OnFormatClick(object sender, RoutedEventArgs e)
    {
        var settings = ViewModel.Settings;
        switch ((string)((FrameworkElement)sender).Tag)
        {
            case "mp3": settings.AudioFormatKind = AudioFormatKind.Mp3; break;
            case "wav": settings.AudioFormatKind = AudioFormatKind.Wav; break;
            case "flac": settings.AudioFormatKind = AudioFormatKind.Flac; break;
            case "mp4": settings.VideoFormat = VideoFormat.Mp4; break;
            case "best": settings.VideoFormat = VideoFormat.Best; break;
        }
        UpdateOutputControls();
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
