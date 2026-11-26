using Stow.Core.Engine;
using Stow.Core.Features;
using Stow.Core.Models;
using Stow.Core.Settings;

namespace Stow.Core.Tests;

internal sealed class FakeClipboard : IClipboardReader
{
    public string? Text { get; set; }
    public uint SequenceNumber { get; set; } = 1;
    /// <summary>읽는 도중 클립보드가 바뀌는 상황</summary>
    public bool ChangeWhileReading { get; set; }

    public Task<string?> ReadTextAsync()
    {
        if (ChangeWhileReading) SequenceNumber++;
        return Task.FromResult(Text);
    }
}

public class QuickExtractTests
{
    private static readonly VideoMetadata Sample = new("abcdefghijk", "여름밤", 325, null, "채널", new Uri("https://www.youtube.com/watch?v=abcdefghijk"), "not_live");

    private static (QuickExtractModel Model, FakeEngine Engine, ExtractQueue Queue, FakeClipboard Clipboard) Make()
    {
        var dir = Directory.CreateTempSubdirectory("stow-quick-").FullName;
        var engine = new FakeEngine { Media = new FetchedMedia.OfVideo(Sample) };
        var settings = new AppSettings(new MemorySettingsStore(), dir);
        var queue = new ExtractQueue(engine, new FakeNotifier());
        var clipboard = new FakeClipboard();
        // 자동 불러오기는 테스트에서 일어나지 않게 길게
        var extract = new ExtractViewModel(settings, engine, queue, TimeSpan.FromHours(1));
        return (new QuickExtractModel(extract, clipboard), engine, queue, clipboard);
    }

    [Theory]
    [InlineData("  https://youtu.be/abcdefghijk \n", "https://youtu.be/abcdefghijk")]
    [InlineData("https://www.youtube.com/playlist?list=PL123", "https://www.youtube.com/playlist?list=PL123")]
    [InlineData("https://example.com/watch?v=abcdefghijk", null)]
    [InlineData("https://youtu.be/abcdefghijk\nhttps://youtu.be/bbbbbbbbbbb", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void ClipboardUrlAcceptsOnlyOneYouTubeAddress(string? text, string? expected) =>
        Assert.Equal(expected, ClipboardUrl.YouTubeText(text));

    [Fact]
    public async Task FillsFromClipboardAndAddsOnEnter()
    {
        var (model, engine, queue, clipboard) = Make();
        var closed = 0;
        model.CloseRequested += () => closed++;
        clipboard.Text = "https://youtu.be/abcdefghijk";

        await model.PrepareForPresentationAsync();
        Assert.Equal("https://youtu.be/abcdefghijk", model.Extract.UrlText);
        await model.Extract.WaitForFetchAsync();
        Assert.Equal(ExtractStage.Video, model.Extract.Stage);

        model.Submit();
        Assert.Equal(1, closed);
        Assert.False(model.IsPresented);
        Assert.Single(queue.Items);
        await queue.WaitUntilIdleAsync();

        // 이미 넣은 클립보드 내용은 다시 채우지 않는다.
        await model.PrepareForPresentationAsync();
        Assert.Equal("", model.Extract.UrlText);
        Assert.Equal(1, engine.FetchCount);

        // 클립보드가 바뀌면 다시 채운다.
        clipboard.SequenceNumber++;
        await model.PrepareForPresentationAsync();
        Assert.Equal("https://youtu.be/abcdefghijk", model.Extract.UrlText);
        await model.Extract.WaitForFetchAsync();
    }

    [Fact]
    public async Task IgnoresNonYouTubeClipboardAndChangesWhileReading()
    {
        var (model, _, _, clipboard) = Make();
        clipboard.Text = "그냥 글자";
        await model.PrepareForPresentationAsync();
        Assert.Equal("", model.Extract.UrlText);

        clipboard.Text = "https://youtu.be/abcdefghijk";
        clipboard.ChangeWhileReading = true;
        await model.PrepareForPresentationAsync();
        Assert.Equal("", model.Extract.UrlText);
    }

    [Fact]
    public async Task EnterWhileFetchingAddsWhenReady()
    {
        var (model, engine, queue, _) = Make();
        engine.FetchGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var closed = 0;
        model.CloseRequested += () => closed++;
        await model.PrepareForPresentationAsync();

        model.Extract.UrlText = "https://youtu.be/abcdefghijk";
        model.Submit();  // 아직 안 불러왔으면 불러온 뒤 추가
        Assert.True(model.AddWhenReady);
        Assert.Equal(ExtractStage.Fetching, model.Extract.Stage);

        engine.FetchGate.SetResult();
        await model.WaitForPendingAddAsync();
        Assert.Equal(1, closed);
        Assert.False(model.AddWhenReady);
        Assert.Single(queue.Items);
        await queue.WaitUntilIdleAsync();
    }

    [Fact]
    public async Task DismissCancelsFetchAndPendingAdd()
    {
        var (model, engine, queue, _) = Make();
        engine.FetchGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await model.PrepareForPresentationAsync();
        model.Extract.UrlText = "https://youtu.be/abcdefghijk";
        model.Submit();

        model.Dismiss();
        await model.WaitForPendingAddAsync();
        await model.Extract.WaitForFetchAsync();
        Assert.False(model.AddWhenReady);
        Assert.Empty(queue.Items);
        Assert.NotEqual(ExtractStage.Fetching, model.Extract.Stage);
    }

    [Fact]
    public async Task InvalidAddressDoesNotWait()
    {
        var (model, _, queue, _) = Make();
        await model.PrepareForPresentationAsync();
        model.Extract.UrlText = "https://example.com/";
        model.Submit();
        Assert.False(model.AddWhenReady);
        Assert.Equal(ExtractStage.Failed, model.Extract.Stage);
        Assert.Empty(queue.Items);
    }

    [Fact]
    public async Task OpenInMainWindowPassesAddress()
    {
        var (model, _, _, _) = Make();
        string? opened = null;
        var closed = 0;
        model.OpenInMainWindowRequested += url => opened = url;
        model.CloseRequested += () => closed++;
        await model.PrepareForPresentationAsync();
        model.Extract.UrlText = "https://www.youtube.com/playlist?list=PL123";
        model.OpenInMainWindow();
        Assert.Equal("https://www.youtube.com/playlist?list=PL123", opened);
        Assert.Equal(1, closed);
    }
}

public class HotKeyAndTraySettingsTests
{
    [Fact]
    public void HotKeyDefaultsDisplayAndRoundTrip()
    {
        Assert.Equal("Ctrl+Alt+Y", HotKey.Default.ToString());
        var custom = new HotKey(HotKeyModifiers.Windows | HotKeyModifiers.Shift | HotKeyModifiers.Control, 0x70);
        Assert.Equal("Win+Ctrl+Shift+F1", custom.ToString());
        Assert.Equal(["Win", "Ctrl", "Shift", "F1"], custom.Parts);
        Assert.Equal(custom, HotKey.Parse(custom.Serialize()));
        Assert.Null(HotKey.Parse("garbage"));
        Assert.Null(HotKey.Parse("4:89"));  // Shift만
    }

    [Theory]
    [InlineData(HotKeyModifiers.Control, 'Y', true)]
    [InlineData(HotKeyModifiers.Shift, 'Y', false)]       // 글자 입력과 겹침
    [InlineData(HotKeyModifiers.None, 0x70, false)]
    [InlineData(HotKeyModifiers.Alt, 0x11, false)]        // Ctrl 키 자체
    [InlineData(HotKeyModifiers.Alt, 0x0D, false)]        // Enter
    [InlineData(HotKeyModifiers.Windows | HotKeyModifiers.Alt, ' ', true)]
    public void HotKeyValidation(HotKeyModifiers modifiers, int key, bool valid) =>
        Assert.Equal(valid, new HotKey(modifiers, key).IsValid);

    [Fact]
    public void SettingsStoreHotKeyAndTrayChoices()
    {
        var store = new MemorySettingsStore();
        var settings = new AppSettings(store, "C:/out");
        Assert.Equal(HotKey.Default, settings.QuickExtractHotKey);
        Assert.True(settings.KeepRunningInTray);
        Assert.False(settings.TrayNoticeShown);

        var custom = new HotKey(HotKeyModifiers.Control | HotKeyModifiers.Shift | HotKeyModifiers.Alt, 'Y');
        settings.QuickExtractHotKey = custom;
        settings.QuickExtractHotKey = new HotKey(HotKeyModifiers.Shift, 'Y');  // 쓸 수 없는 키는 무시
        settings.KeepRunningInTray = false;
        settings.TrayNoticeShown = true;

        var reloaded = new AppSettings(store, "C:/out");
        Assert.Equal(custom, reloaded.QuickExtractHotKey);
        Assert.False(reloaded.KeepRunningInTray);
        Assert.True(reloaded.TrayNoticeShown);
    }

    [Fact]
    public void RecentOutputDirectoriesKeepFiveUniqueNewestFirst()
    {
        var store = new MemorySettingsStore();
        var settings = new AppSettings(store, "C:/out");
        Assert.Equal(["C:/out"], settings.RecentOutputDirectories);
        foreach (var d in new[] { "C:/a", "C:/b", "C:/c", "C:/d", "C:/e" }) settings.OutputDirectory = d;
        Assert.Equal(["C:/e", "C:/d", "C:/c", "C:/b", "C:/a"], settings.RecentOutputDirectories);

        settings.OutputDirectory = "c:/B/";  // 대소문자·끝 구분자만 다른 같은 폴더는 앞으로 옮긴다
        Assert.Equal(["c:/B/", "C:/e", "C:/d", "C:/c", "C:/a"], settings.RecentOutputDirectories);

        var reloaded = new AppSettings(store, "C:/out");
        Assert.Equal(settings.RecentOutputDirectories, reloaded.RecentOutputDirectories);
    }

    [Fact]
    public void AvailableRecentsSkipMissingFolders()
    {
        var existing = Directory.CreateTempSubdirectory("stow-recent-").FullName;
        var missing = Path.Combine(existing, "없는 폴더");
        var settings = new AppSettings(new MemorySettingsStore(), existing);
        settings.OutputDirectory = missing;          // 지금 폴더는 없어도 보인다
        Assert.Equal([missing, existing], settings.AvailableRecentOutputDirectories);
        settings.OutputDirectory = existing;
        Assert.Equal([existing], settings.AvailableRecentOutputDirectories);
    }
}
