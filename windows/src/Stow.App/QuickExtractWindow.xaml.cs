using System.Diagnostics;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Stow.Core.Features;
using Stow.Core.Models;
using Stow.Core.Settings;
using Windows.Foundation;
using Windows.Graphics;
using Windows.System;

namespace Stow;

/// <summary>
/// 빠른 추출 창(시안 A, 사용자 결정 2026-11-26). 마우스가 있는 화면의 위쪽 가운데에 떠서, 다른 앱 위에 있다가
/// Enter로 추가하거나 Esc·바깥 클릭으로 닫힌다. 한 번 만들어 숨겼다 보였다 하며 다시 쓴다.
/// </summary>
public sealed partial class QuickExtractWindow : Window
{
    /// <summary>창 너비(배율 100% 기준)</summary>
    private const double PanelWidth = 620;

    /// <summary>"다른 폴더…" 선택 창이 떠 있는 동안에는 창이 비활성이 되어도 닫지 않는다.</summary>
    private bool choosingFolder;
    private bool fitPending;
    private bool isShown;
    /// <summary>폴더 메뉴에 보일 최근 폴더(있는지 확인은 창을 열 때 화면 스레드 밖에서 한다: 끊긴 네트워크 드라이브가 메뉴를 멈추지 않게)</summary>
    private IReadOnlyList<string>? availableRecents;

    public QuickExtractModel Model { get; }

    internal QuickExtractWindow(QuickExtractModel model)
    {
        Model = model;
        InitializeComponent();

        AppWindow.IsShownInSwitchers = false;
        AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(true, false);
        }
        if (DesktopAcrylicController.IsSupported()) SystemBackdrop = new DesktopAcrylicBackdrop();
        else RootGrid.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];

        Activated += OnActivated;
        AppWindow.Closing += (_, args) =>
        {
            // Alt+F4도 닫기와 같다(창은 다음에 다시 쓴다).
            args.Cancel = true;
            Model.Dismiss();
        };
        Model.CloseRequested += HidePanel;
        Model.PropertyChanged += (_, _) => UpdateChrome();
        Model.Extract.PropertyChanged += (_, _) => UpdateChrome();
        Model.Extract.Settings.PropertyChanged += (_, _) => UpdateChips();
        UpdateChips();
        UpdateChrome();
    }

    /// <summary>단축키·트레이 메뉴에서: 마우스가 있는 화면 위쪽 가운데에 띄우고 클립보드 주소를 채운다. 이미 떠 있으면 닫는다.</summary>
    public async void Toggle()
    {
        if (isShown)
        {
            Model.Dismiss();
            return;
        }
        isShown = true;
        var settings = Model.Extract.Settings;
        availableRecents = null;
        _ = Task.Run(() => settings.AvailableRecentOutputDirectories).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully) DispatcherQueue.TryEnqueue(() => availableRecents = t.Result);
        }, TaskScheduler.Default);
        PlaceOnCursorScreen();
        AppWindow.Show(true);
        Activate();
        NativeMethods.SetForegroundWindow(Handle);
        UrlBox.Focus(FocusState.Programmatic);
        await Model.PrepareForPresentationAsync();
        UrlBox.SelectAll();
        FitToContent();
    }

    private IntPtr Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    private void HidePanel()
    {
        isShown = false;
        AppWindow.Hide();
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        // 다른 곳을 누르면(바깥 클릭) 닫는다.
        if (args.WindowActivationState == WindowActivationState.Deactivated && isShown && !choosingFolder) Model.Dismiss();
    }

    private void OnRootKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                Model.Dismiss();
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                Model.Submit();
                break;
        }
    }

    private void OnAdd(object sender, RoutedEventArgs e) => Model.Submit();
    private void OnOpenInMainWindow(object sender, RoutedEventArgs e) => Model.OpenInMainWindow();

    // MARK: 안내·버튼

    private void UpdateChrome()
    {
        var extract = Model.Extract;
        HintText.Text = extract.Stage switch
        {
            ExtractStage.Fetching => Model.AddWhenReady ? "불러오는 대로 대기열에 추가합니다…" : "영상 정보를 불러오는 중…",
            ExtractStage.Idle when extract.UrlText.Trim().Length == 0 => "유튜브 주소를 복사해 두면 열 때 자동으로 채웁니다.",
            ExtractStage.Idle => "Enter를 누르면 불러와서 바로 대기열에 넣습니다.",
            _ => "",
        };
        HintText.Visibility = HintText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        AddButton.IsEnabled = !Model.AddWhenReady && (extract.CanAddToQueue || extract.CanFetch || extract.IsFetching);
        ScheduleFit();
    }

    private void UpdateChips()
    {
        var settings = Model.Extract.Settings;
        FormatButton.Content = $"{(settings.Format.IsVideo ? "영상" : "오디오")} · {DisplayText.Name(settings.Format)}";
        FolderButton.Content = FolderName(settings.OutputDirectory);
        ToolTipService.SetToolTip(FolderButton, settings.OutputDirectory);
        ScheduleFit();
    }

    private static string FolderName(string path)
    {
        var trimmed = Path.TrimEndingDirectorySeparator(path);
        var name = Path.GetFileName(trimmed);
        return name.Length > 0 ? name : path;  // 드라이브 바로 아래(D:\)는 경로 그대로
    }

    // MARK: 포맷 칩

    private void OnFormatMenuOpening(object? sender, object e)
    {
        var settings = Model.Extract.Settings;
        FormatMenu.Items.Clear();
        foreach (var format in FormatChoices.Audio) FormatMenu.Items.Add(FormatItem(format, settings.Format));
        FormatMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var videoFormat in FormatChoices.VideoFormats)
        {
            var sub = new MenuFlyoutSubItem { Text = DisplayText.Name(videoFormat) };
            foreach (var resolution in videoFormat.Resolutions())
            {
                var item = FormatItem(new OutputFormat.Video(videoFormat, resolution), settings.Format);
                item.Text = DisplayText.Name(resolution);
                sub.Items.Add(item);
            }
            FormatMenu.Items.Add(sub);
        }
    }

    private RadioMenuFlyoutItem FormatItem(OutputFormat format, OutputFormat current)
    {
        var item = new RadioMenuFlyoutItem { Text = DisplayText.Name(format), GroupName = "format", IsChecked = format == current };
        item.Click += (_, _) => Model.Extract.Settings.Select(format);
        return item;
    }

    // MARK: 폴더 칩

    private void OnFolderMenuOpening(object? sender, object e)
    {
        var settings = Model.Extract.Settings;
        FolderMenu.Items.Clear();
        // 확인이 아직 안 끝났으면 저장된 목록 그대로(지금 폴더가 맨 앞)
        foreach (var directory in availableRecents ?? settings.RecentOutputDirectories)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = FolderName(directory),
                GroupName = "folder",
                IsChecked = AppSettings.SameDirectory(directory, settings.OutputDirectory),
            };
            ToolTipService.SetToolTip(item, directory);
            item.Click += (_, _) => settings.OutputDirectory = directory;
            FolderMenu.Items.Add(item);
        }
        FolderMenu.Items.Add(new MenuFlyoutSeparator());
        var other = new MenuFlyoutItem { Text = "다른 폴더…" };
        other.Click += OnChooseOtherFolder;
        FolderMenu.Items.Add(other);
        var reveal = new MenuFlyoutItem { Text = "탐색기에서 열기" };
        reveal.Click += (_, _) =>
        {
            var directory = settings.OutputDirectory;
            if (!Directory.Exists(directory)) return;
            Model.Dismiss();
            try
            {
                // 폴더 경로를 그대로 열게 한다(명령줄 문자열을 만들지 않는다).
                Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true });
            }
            catch (Exception)
            {
                // 폴더를 열지 못해도(빠진 USB 등) 앱은 계속한다.
            }
        };
        FolderMenu.Items.Add(reveal);
    }

    private async void OnChooseOtherFolder(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Handle);
        choosingFolder = true;
        try
        {
            if (await picker.PickSingleFolderAsync() is { } folder) Model.Extract.Settings.OutputDirectory = folder.Path;
        }
        finally
        {
            choosingFolder = false;
        }
        if (!isShown) return;
        Activate();
        UrlBox.Focus(FocusState.Programmatic);
    }

    // MARK: 위치·크기

    /// <summary>마우스가 있는 화면의 작업 영역 위쪽 가운데(위에서 1/6 지점)로 옮긴다.</summary>
    private void PlaceOnCursorScreen()
    {
        NativeMethods.GetCursorPos(out var cursor);
        var area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Nearest).WorkArea;
        // 먼저 그 화면으로 옮겨야 그 화면의 배율로 크기를 잰다.
        AppWindow.Move(new PointInt32(area.X + area.Width / 3, area.Y + area.Height / 6));
        FitToContent();
        AppWindow.Move(new PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + area.Height / 6));
    }

    private void ScheduleFit()
    {
        if (fitPending) return;
        fitPending = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            fitPending = false;
            FitToContent();
        });
    }

    /// <summary>창 높이를 내용에 맞춘다(위쪽 위치는 그대로).</summary>
    private void FitToContent()
    {
        var scale = NativeMethods.GetDpiForWindow(Handle) / 96.0;
        RootGrid.Measure(new Size(PanelWidth, double.PositiveInfinity));
        var height = Math.Ceiling(RootGrid.DesiredSize.Height);
        if (height <= 0) height = 120;
        AppWindow.ResizeClient(new SizeInt32((int)Math.Round(PanelWidth * scale), (int)Math.Round(height * scale)));
    }

}
