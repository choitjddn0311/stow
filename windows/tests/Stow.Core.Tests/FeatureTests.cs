using Stow.Core.Engine;
using Stow.Core.Features;
using Stow.Core.Models;
using Stow.Core.Settings;

namespace Stow.Core.Tests;

/// <summary>제목으로 동작을 정하는 가짜 엔진: "fail"은 네트워크 오류, "blocked"는 유튜브 차단, "gate"는 Release까지 대기.</summary>
internal sealed class FakeEngine : IExtractEngine
{
    public FetchedMedia? Media { get; set; }
    public EngineException? FetchError { get; set; }
    public TaskCompletionSource? FetchGate { get; set; }
    public TaskCompletionSource ExtractGate { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public List<string> Extracted { get; } = [];
    public int FetchCount;

    public async Task<FetchedMedia> FetchMediaAsync(Uri url, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref FetchCount);
        if (FetchGate is { } gate) await gate.Task.WaitAsync(cancellationToken);
        if (FetchError is { } error) throw error;
        return Media ?? throw new InvalidOperationException();
    }

    public async Task<string> ExtractAsync(Uri url, ExtractOptions options, string fileName,
        Action<ExtractProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        lock (Extracted) Extracted.Add(fileName);
        progress?.Invoke(new ExtractProgress.Downloading(0.5, null, 3));
        if (fileName.StartsWith("gate", StringComparison.Ordinal)) await ExtractGate.Task.WaitAsync(cancellationToken);
        if (fileName.StartsWith("fail", StringComparison.Ordinal)) throw new EngineException(EngineErrorKind.Network);
        if (fileName.StartsWith("blocked", StringComparison.Ordinal)) throw new EngineException(EngineErrorKind.BlockedByYouTube);
        return Path.Combine(options.OutputDirectory, fileName + "." + (options.Format.FileExtension ?? "mp4"));
    }
}

internal sealed class FakeNotifier : ICompletionNotifier
{
    public List<string> Titles { get; } = [];
    public List<string> Revealed { get; } = [];
    public void Prepare() { }
    public void NotifyCompleted(string title, string file) => Titles.Add(title);
    public void Reveal(string file) => Revealed.Add(file);
}

public class AppSettingsTests
{
    [Fact]
    public void DefaultsAndPersistence()
    {
        var store = new MemorySettingsStore();
        var first = new AppSettings(store, defaultOutputDirectory: @"C:\Users\me\Downloads");
        Assert.Equal(new OutputFormat.Mp3(Mp3Bitrate.Kbps320), first.Format);
        Assert.Equal(@"C:\Users\me\Downloads", first.OutputDirectory);
        Assert.Equal(0, first.AcceptedNoticeVersion);

        first.AudioFormatKind = AudioFormatKind.Flac;
        first.Mp3Bitrate = Mp3Bitrate.Kbps128;
        first.OutputDirectory = @"D:\음악";
        first.AcceptedNoticeVersion = 2;

        var second = new AppSettings(store);
        Assert.Equal(new OutputFormat.Flac(), second.Format);
        Assert.Equal(@"D:\음악", second.OutputDirectory);
        Assert.Equal(2, second.AcceptedNoticeVersion);
        second.AudioFormatKind = AudioFormatKind.Mp3;
        Assert.Equal(new OutputFormat.Mp3(Mp3Bitrate.Kbps128), second.Format);  // FLAC을 거쳐도 MP3 음질 기억
    }

    [Fact]
    public void RemembersFormatsPerKindAndClampsMp4()
    {
        var store = new MemorySettingsStore();
        var first = new AppSettings(store);
        first.Select(new OutputFormat.Flac());
        first.Select(new OutputFormat.Video(VideoFormat.Best, VideoResolution.P1440));
        first.Select(new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P720));

        var second = new AppSettings(store);
        Assert.Equal(new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P720), second.Format);
        second.VideoFormat = VideoFormat.Best;
        Assert.Equal(new OutputFormat.Video(VideoFormat.Best, VideoResolution.P1440), second.Format);
        second.MediaKind = MediaKind.Audio;
        Assert.Equal(new OutputFormat.Flac(), second.Format);

        second.Select(new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P2160));
        Assert.Equal(new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P1080), second.Format);
    }

    [Fact]
    public void JsonFileStoreRoundTripsAndToleratesBrokenFile()
    {
        var dir = Directory.CreateTempSubdirectory("stow-settings-");
        try
        {
            var path = Path.Combine(dir.FullName, "sub", "settings.json");
            var settings = new AppSettings(new JsonFileSettingsStore(path));
            settings.Select(new OutputFormat.Video(VideoFormat.Best, VideoResolution.P2160));
            Assert.Equal(new OutputFormat.Video(VideoFormat.Best, VideoResolution.P2160), new AppSettings(new JsonFileSettingsStore(path)).Format);

            File.WriteAllText(path, "{broken");
            Assert.Equal(new OutputFormat.Mp3(Mp3Bitrate.Kbps320), new AppSettings(new JsonFileSettingsStore(path)).Format);
        }
        finally { dir.Delete(true); }
    }
}

public class ExtractQueueTests
{
    private static string TempDir() => Directory.CreateTempSubdirectory("stow-queue-").FullName;
    private static QueueItem Item(string title, string dir, string? subfolder = null) =>
        new(new Uri("https://youtu.be/abcdefghijk"), title, new ExtractOptions(new OutputFormat.Mp3(Mp3Bitrate.Kbps320), dir), subfolder: subfolder);

    [Fact]
    public async Task RunsInOrderAndNotifiesOnce()
    {
        var dir = TempDir();
        var engine = new FakeEngine();
        var notifier = new FakeNotifier();
        var queue = new ExtractQueue(engine, notifier);
        queue.Add([Item("a", dir), Item("fail b", dir), Item("c", dir)]);
        await queue.WaitUntilIdleAsync();

        Assert.Equal(["a", "fail b", "c"], engine.Extracted);
        Assert.Equal([QueueStatus.Completed, QueueStatus.Failed, QueueStatus.Completed], queue.Items.Select(i => i.Status));
        Assert.Equal("실패: 네트워크에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요.", queue.Items[1].StatusText);
        Assert.Equal("저장했습니다: a.mp3", queue.Items[0].StatusText);
        Assert.Equal(["2개 저장 완료"], notifier.Titles);
        Assert.Equal("완료 2 · 실패 1", queue.SummaryText);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task CancelRunningAndWaiting()
    {
        var dir = TempDir();
        var engine = new FakeEngine();
        var queue = new ExtractQueue(engine, new FakeNotifier());
        queue.Add([Item("gate a", dir), Item("b", dir)]);
        Assert.Equal(QueueStatus.Running, queue.Items[0].Status);
        Assert.Equal("다운로드 중 50% · 약 3초 남음", queue.Items[0].StatusText);
        Assert.Equal(0.5, queue.Items[0].ProgressValue);
        Assert.Equal("대기 중 · MP3 320kbps", queue.Items[1].StatusText);

        queue.Cancel(queue.Items[1]);
        queue.Cancel(queue.Items[0]);
        await queue.WaitUntilIdleAsync();
        Assert.Equal([QueueStatus.Cancelled, QueueStatus.Cancelled], queue.Items.Select(i => i.Status));
        Assert.Equal(["gate a"], engine.Extracted);

        queue.Retry(queue.Items[1]);
        await queue.WaitUntilIdleAsync();
        Assert.Equal(QueueStatus.Completed, queue.Items[1].Status);
        queue.ClearFinished();
        Assert.True(queue.IsEmpty);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task BlockedPausesUntilResumed()
    {
        var dir = TempDir();
        var engine = new FakeEngine();
        var queue = new ExtractQueue(engine, new FakeNotifier());
        queue.Add([Item("blocked a", dir), Item("b", dir)]);
        await queue.WaitUntilIdleAsync();
        Assert.True(queue.IsPaused);
        Assert.Equal("유튜브가 요청을 일시적으로 막았습니다. 잠시 후 다시 시도해 주세요.", queue.BlockedMessage);
        Assert.Equal(QueueStatus.Waiting, queue.Items[1].Status);  // 멈춘 동안 다음 항목은 기다린다

        queue.Resume();
        await queue.WaitUntilIdleAsync();
        // 차단으로 실패한 항목도 다시 시도한다(이번에도 막히면 다시 멈춤).
        Assert.Equal(["blocked a", "blocked a"], engine.Extracted);
        Assert.True(queue.IsPaused);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task PlaylistItemsGoToSubfolderAndMissingDirectoryFails()
    {
        var dir = TempDir();
        var queue = new ExtractQueue(new FakeEngine(), new FakeNotifier());
        queue.Add([Item("a", dir, subfolder: "내 목록: 여름"), Item("b", Path.Combine(dir, "없는 폴더"))]);
        await queue.WaitUntilIdleAsync();
        Assert.True(Directory.Exists(Path.Combine(dir, "내 목록- 여름")));
        Assert.Equal(Path.Combine(dir, "내 목록- 여름", "a.mp3"), queue.Items[0].OutputFile);
        Assert.Equal(EngineErrorKind.OutputDirectoryMissing, queue.Items[1].Error?.Kind);
        Directory.Delete(dir, true);
    }
}

public class ExtractViewModelTests
{
    private static readonly VideoMetadata Sample = new("abcdefghijk", "여름밤", 325, null, "채널", new Uri("https://www.youtube.com/watch?v=abcdefghijk"), "not_live");

    private static (ExtractViewModel Model, FakeEngine Engine, ExtractQueue Queue, string Dir) Make()
    {
        var dir = Directory.CreateTempSubdirectory("stow-vm-").FullName;
        var engine = new FakeEngine { Media = new FetchedMedia.OfVideo(Sample) };
        var settings = new AppSettings(new MemorySettingsStore(), dir);
        var queue = new ExtractQueue(engine, new FakeNotifier());
        return (new ExtractViewModel(settings, engine, queue, TimeSpan.FromMilliseconds(20)), engine, queue, dir);
    }

    [Fact]
    public async Task FetchesVideoAndAddsToQueue()
    {
        var (model, engine, queue, dir) = Make();
        model.UrlText = "https://youtu.be/abcdefghijk";
        model.Fetch();
        await model.WaitForFetchAsync();
        Assert.Equal(ExtractStage.Video, model.Stage);
        Assert.Equal("채널 · 5:25", model.VideoSubtitle);
        Assert.Equal("MP3로 추출", model.AddButtonTitle);

        model.Settings.MediaKind = MediaKind.Video;
        Assert.Equal("MP4로 받기", model.AddButtonTitle);
        model.Settings.MediaKind = MediaKind.Audio;

        model.AddToQueue();
        Assert.Equal(ExtractStage.Idle, model.Stage);
        Assert.Equal("", model.UrlText);
        await queue.WaitUntilIdleAsync();
        Assert.Equal(["여름밤"], engine.Extracted);
        Directory.Delete(dir, true);
    }

    [Fact]
    public void InvalidAndChannelUrlsShowErrors()
    {
        var (model, _, _, dir) = Make();
        model.UrlText = "https://example.com/x";
        model.Fetch();
        Assert.Equal(ExtractStage.Failed, model.Stage);
        Assert.Equal("유튜브 영상 주소가 아닙니다. 주소를 확인해 주세요.", model.ErrorMessage);
        Assert.False(model.CanRetryFetch);  // 주소가 틀린 건 다시 해도 같다
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task TransientFetchErrorCanBeRetried()
    {
        var (model, engine, _, dir) = Make();
        engine.FetchError = new EngineException(EngineErrorKind.Network);
        model.UrlText = "https://youtu.be/abcdefghijk";
        model.Fetch();
        await model.WaitForFetchAsync();
        Assert.True(model.CanRetryFetch);
        engine.FetchError = null;
        model.RetryFetch();
        await model.WaitForFetchAsync();
        Assert.Equal(ExtractStage.Video, model.Stage);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task PlaylistSelectsAvailableEntries()
    {
        var (model, engine, queue, dir) = Make();
        engine.Media = new FetchedMedia.OfPlaylist(new Playlist("PL1", "목록", [
            new PlaylistEntry("aaaaaaaaaaa", "첫 곡", 10), new PlaylistEntry("bbbbbbbbbbb", "[Private video]", null),
            new PlaylistEntry("ccccccccccc", "셋째", 20)], 900));
        model.UrlText = "https://www.youtube.com/playlist?list=PL1";
        model.Fetch();
        await model.WaitForFetchAsync();
        Assert.Equal(ExtractStage.Playlist, model.Stage);
        Assert.Equal(2, model.PendingAddCount);
        Assert.Equal("2개 추출", model.AddButtonTitle);
        Assert.Equal("영상 900개 중 처음 3개", model.PlaylistSummary);
        model.PlaylistEntries[0].IsSelected = false;
        Assert.Equal("1개 추출", model.AddButtonTitle);
        model.AddToQueue();
        Assert.Equal(["셋째"], queue.Items.Select(i => i.Title));
        Assert.Equal("목록", queue.Items[0].Subfolder);
        await queue.WaitUntilIdleAsync();
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task TypingAutoFetchesAndChangingUrlDropsResult()
    {
        var (model, engine, _, dir) = Make();
        model.UrlText = "https://youtu.be/abcdefghijk";
        for (var i = 0; i < 100 && model.Stage != ExtractStage.Video; i++) await Task.Delay(10, TestContext.Current.CancellationToken);
        Assert.Equal(ExtractStage.Video, model.Stage);
        Assert.Equal(1, engine.FetchCount);

        model.UrlText = " https://youtu.be/abcdefghijk ";  // 앞뒤 공백만 바뀌면 그대로
        Assert.Equal(ExtractStage.Video, model.Stage);
        model.UrlText = "https://youtu.be/zzzzzzzzzzz";
        Assert.Equal(ExtractStage.Idle, model.Stage);
        Assert.Null(model.Video);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task QueueBusyChangesButtonTitle()
    {
        var (model, engine, queue, dir) = Make();
        queue.Add([new QueueItem(new Uri("https://youtu.be/x"), "gate", model.Settings.ExtractOptions)]);
        model.UrlText = "https://youtu.be/abcdefghijk";
        model.Fetch();
        await model.WaitForFetchAsync();
        Assert.Equal("대기열에 추가", model.AddButtonTitle);
        engine.ExtractGate.SetResult();
        await queue.WaitUntilIdleAsync();
        Assert.Equal("MP3로 추출", model.AddButtonTitle);
        Directory.Delete(dir, true);
    }
}

public class DisplayTextTests
{
    [Fact]
    public void NamesAndDurations()
    {
        Assert.Equal("최고 화질 1440p", DisplayText.Name(new OutputFormat.Video(VideoFormat.Best, VideoResolution.P1440)));
        Assert.Equal("FLAC으로 추출", DisplayText.ActionTitle(new OutputFormat.Flac()));
        Assert.Equal("최고 화질로 받기", DisplayText.ActionTitle(new OutputFormat.Video(VideoFormat.Best, VideoResolution.Best)));
        Assert.Equal("1:02:03", DisplayText.Duration(3723));
        Assert.Equal("5분 25초", DisplayText.SpokenDuration(325));
        Assert.Equal("영상 받는 중 42% · 약 8초 남음",
            DisplayText.Progress(new ExtractProgress.Downloading(0.42, null, 8, DownloadPart.Video), new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P1080)));
        Assert.Equal("영상과 오디오를 합치는 중…", DisplayText.Progress(new ExtractProgress.Merging(), new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P1080)));
    }
}
