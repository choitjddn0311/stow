using System.Collections.ObjectModel;
using Stow.Core.Engine;
using Stow.Core.Models;
using Stow.Core.Settings;

namespace Stow.Core.Features;

public enum ExtractStage { Idle, Fetching, Video, Playlist, Failed }

/// <summary>재생목록의 영상 하나와 선택 여부.</summary>
public sealed class PlaylistEntryItem(PlaylistEntry entry, Action changed) : ObservableObject
{
    public PlaylistEntry Entry { get; } = entry;
    public string Title => Entry.Title;
    public string DurationText => Entry.Duration is { } d ? DisplayText.Duration(d) : "";
    public bool IsUnavailable => Entry.IsUnavailable;
    public bool IsAvailable => !Entry.IsUnavailable;

    private bool isSelected = !entry.IsUnavailable;
    public bool IsSelected
    {
        get => isSelected;
        set { if (Set(ref isSelected, value)) changed(); }
    }
}

/// <summary>
/// 주소 입력과 불러오기(영상 하나 또는 재생목록 선택)를 맡고, 고른 것을 대기열에 넣는다(Mac 앱 ExtractViewModel과 같은 동작).
/// 상태: 대기 → 조회 중 → 영상 / 재생목록 선택 → (대기열에 추가하면) 대기, 또는 실패. 화면 스레드에서만 부른다.
/// </summary>
public sealed class ExtractViewModel : ObservableObject
{
    private readonly IExtractEngine engine;
    private readonly TimeSpan autoFetchDelay;
    private string? loadedUrlText;
    private CancellationTokenSource? fetchCancel;
    private CancellationTokenSource? autoFetchCancel;
    private Task? fetchTask;

    public ExtractViewModel(AppSettings settings, IExtractEngine engine, ExtractQueue queue, TimeSpan? autoFetchDelay = null)
    {
        Settings = settings;
        this.engine = engine;
        Queue = queue;
        this.autoFetchDelay = autoFetchDelay ?? TimeSpan.FromMilliseconds(500);
        settings.PropertyChanged += (_, _) => Notify(nameof(AddButtonTitle));
        queue.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(ExtractQueue.IsRunning) or nameof(ExtractQueue.WaitingCount)) Notify(nameof(AddButtonTitle)); };
    }

    public AppSettings Settings { get; }
    public ExtractQueue Queue { get; }

    private string urlText = "";
    /// <summary>주소 입력란. 붙여 넣거나 입력을 멈추면 잠시 뒤 자동으로 불러온다. 불러온 뒤 바꾸면 처음 상태로 돌아간다.</summary>
    public string UrlText
    {
        get => urlText;
        set
        {
            var old = urlText;
            if (Set(ref urlText, value, alsoChanged: nameof(CanFetch))) UrlTextChanged(old);
        }
    }

    private ExtractStage stage;
    public ExtractStage Stage
    {
        get => stage;
        private set => Set(ref stage, value, alsoChanged: [nameof(IsFetching), nameof(CanFetch), nameof(PendingAddCount),
            nameof(CanAddToQueue), nameof(AddButtonTitle), nameof(HasVideo), nameof(HasPlaylist), nameof(HasError)]);
    }

    private VideoMetadata? video;
    public VideoMetadata? Video { get => video; private set => Set(ref video, value, alsoChanged: [nameof(VideoSubtitle)]); }

    /// <summary>예: "채널 · 47:27"</summary>
    public string VideoSubtitle => Video is null ? "" : string.Join(" · ",
        new[] { Video.Uploader, Video.Duration is { } d ? DisplayText.Duration(d) : null }.Where(s => !string.IsNullOrEmpty(s)));

    private Playlist? playlist;
    public Playlist? Playlist { get => playlist; private set => Set(ref playlist, value, alsoChanged: nameof(PlaylistSummary)); }
    public ObservableCollection<PlaylistEntryItem> PlaylistEntries { get; } = [];

    /// <summary>예: "영상 24개" 또는 "영상 900개 중 처음 500개"</summary>
    public string PlaylistSummary => Playlist is null ? ""
        : Playlist.IsTruncated ? $"영상 {Playlist.TotalCount}개 중 처음 {Playlist.Entries.Count}개" : $"영상 {Playlist.Entries.Count}개";

    private EngineException? error;
    public EngineException? Error { get => error; private set => Set(ref error, value, alsoChanged: [nameof(ErrorMessage), nameof(CanRetryFetch)]); }
    public string ErrorMessage => Error?.Message ?? "";
    /// <summary>일시적인 오류(네트워크·유튜브 차단 등)에만 "다시 시도"를 보인다.</summary>
    public bool CanRetryFetch => Error?.IsWorthRetrying == true && loadedUrlText is not null;

    public bool IsFetching => Stage == ExtractStage.Fetching;
    public bool HasVideo => Stage == ExtractStage.Video;
    public bool HasPlaylist => Stage == ExtractStage.Playlist;
    public bool HasError => Stage == ExtractStage.Failed;
    public bool CanFetch => !IsFetching && UrlText.Trim().Length > 0;

    /// <summary>대기열에 넣을 영상 수(영상이면 1, 재생목록이면 고른 수).</summary>
    public int PendingAddCount => Stage switch
    {
        ExtractStage.Video => 1,
        ExtractStage.Playlist => PlaylistEntries.Count(e => e.IsSelected),
        _ => 0,
    };

    public bool CanAddToQueue => PendingAddCount > 0;

    /// <summary>
    /// 추가 버튼 이름. 바로 시작하면(진행 중·대기 중 없음) "MP3로 추출"·"MP4로 받기"·"12개 추출",
    /// 다른 항목 뒤에 줄을 서면 "대기열에 추가"·"12개 대기열에 추가".
    /// </summary>
    public string AddButtonTitle
    {
        get
        {
            var startsNow = !Queue.IsRunning && Queue.WaitingCount == 0;
            var count = Stage == ExtractStage.Playlist ? $"{PendingAddCount}개" : null;
            return (startsNow, count) switch
            {
                (true, { } c) => Settings.Format.IsVideo ? $"{c} 받기" : $"{c} 추출",
                (true, null) => DisplayText.ActionTitle(Settings.Format),
                (false, { } c) => $"{c} 대기열에 추가",
                _ => "대기열에 추가",
            };
        }
    }

    /// <summary>주소를 검증하고 영상 정보(또는 재생목록)를 불러온다.</summary>
    public void Fetch()
    {
        autoFetchCancel?.Cancel();
        if (!CanFetch) return;
        var text = UrlText;
        Uri url;
        try
        {
            url = YouTubeUrl.Parse(text);
        }
        catch (EngineException parseError)
        {
            loadedUrlText = null;
            ShowError(parseError);
            return;
        }
        loadedUrlText = text;
        Error = null;
        Stage = ExtractStage.Fetching;
        fetchCancel = new CancellationTokenSource();
        fetchTask = FetchAsync(url, fetchCancel);
    }

    private async Task FetchAsync(Uri url, CancellationTokenSource cancel)
    {
        try
        {
            var media = await engine.FetchMediaAsync(url, cancel.Token);
            if (fetchCancel != cancel) return;  // 주소를 바꿔 다른 조회가 시작되었으면 버린다.
            switch (media)
            {
                case FetchedMedia.OfVideo v:
                    Video = v.Metadata;
                    Stage = ExtractStage.Video;
                    break;
                case FetchedMedia.OfPlaylist p:
                    ShowPlaylist(p.Playlist);
                    break;
            }
        }
        catch (OperationCanceledException)
        {
            if (fetchCancel == cancel) Stage = ExtractStage.Idle;
        }
        catch (Exception failure)
        {
            if (fetchCancel != cancel) return;
            ShowError(failure as EngineException ?? new EngineException(EngineErrorKind.Unknown, failure.Message, failure));
        }
        finally
        {
            if (fetchCancel == cancel) fetchCancel = null;
            cancel.Dispose();
        }
    }

    /// <summary>주소 입력란에서 Enter: 불러온 주소 그대로면 대기열에 추가, 아니면 불러오기.</summary>
    public void Submit()
    {
        // 앞뒤 공백만 다르면 같은 주소로 본다(주소 변경 처리와 같은 기준).
        if (CanAddToQueue && loadedUrlText is not null && UrlText.Trim() == loadedUrlText.Trim()) AddToQueue();
        else Fetch();
    }

    /// <summary>불러온 영상(또는 재생목록에서 고른 영상)을 지금 설정으로 대기열에 넣고 주소란을 비운다.</summary>
    public void AddToQueue()
    {
        var options = Settings.ExtractOptions;
        switch (Stage)
        {
            case ExtractStage.Video when Video is { } v:
                var url = v.WebpageUrl ?? (loadedUrlText is null ? null : YouTubeUrl.Parse(loadedUrlText));
                if (url is null) return;
                Queue.Add([new QueueItem(url, v.Title, options, v.Duration, v.ThumbnailUrl)]);
                break;
            case ExtractStage.Playlist when Playlist is { } p:
                var items = PlaylistEntries.Where(e => e.IsSelected)
                    .Select(e => new QueueItem(e.Entry.Url, e.Entry.Title, options, e.Entry.Duration, subfolder: p.Title)).ToList();
                if (items.Count == 0) return;
                Queue.Add(items);
                break;
            default:
                return;
        }
        StartOver();
    }

    /// <summary>
    /// 다른 곳(빠른 추출 창)에서 이미 불러온 재생목록을 그대로 보인다(다시 조회하지 않는다).
    /// 재생목록이 없으면 주소만 넣는다(잠시 뒤 자동으로 불러온다).
    /// </summary>
    public void Open(string text, Playlist? loaded)
    {
        if (loaded is null)
        {
            UrlText = text;
            return;
        }
        autoFetchCancel?.Cancel();
        if (IsFetching)
        {
            var cancel = fetchCancel;
            fetchCancel = null;
            cancel?.Cancel();
        }
        // 불러온 주소로 먼저 정해 두면 주소란을 바꿔도 결과를 지우거나 다시 불러오지 않는다.
        loadedUrlText = text;
        UrlText = text;
        ClearResult();
        ShowPlaylist(loaded);
    }

    /// <summary>오류 안내의 "다시 시도".</summary>
    public void RetryFetch()
    {
        if (loadedUrlText is null) return;
        Fetch();
    }

    public void CancelFetch() => fetchCancel?.Cancel();

    /// <summary>"모두 선택"·"모두 해제". 받을 수 없는 영상(비공개·삭제)은 고르지 않는다.</summary>
    public void SetAllEntriesSelected(bool selected)
    {
        foreach (var entry in PlaylistEntries) entry.IsSelected = selected && !entry.IsUnavailable;
    }

    /// <summary>처음 상태로 돌아간다(주소란 비움).</summary>
    public void StartOver()
    {
        if (IsFetching) return;
        loadedUrlText = null;
        UrlText = "";
        ClearResult();
        Stage = ExtractStage.Idle;
    }

    /// <summary>테스트에서 진행 중인 조회가 끝날 때까지 기다린다.</summary>
    public async Task WaitForFetchAsync()
    {
        if (fetchTask is { } task) await task;
    }

    private void ShowPlaylist(Playlist value)
    {
        PlaylistEntries.Clear();
        foreach (var entry in value.Entries) PlaylistEntries.Add(new PlaylistEntryItem(entry, SelectionChanged));
        Playlist = value;
        Stage = ExtractStage.Playlist;
        SelectionChanged();
    }

    private void SelectionChanged()
    {
        Notify(nameof(PendingAddCount));
        Notify(nameof(CanAddToQueue));
        Notify(nameof(AddButtonTitle));
    }

    private void ShowError(EngineException failure)
    {
        ClearResult();
        Error = failure;
        Stage = ExtractStage.Failed;
    }

    private void ClearResult()
    {
        Video = null;
        Playlist = null;
        PlaylistEntries.Clear();
        Error = null;
    }

    /// <summary>주소가 바뀌었을 때: 이전 결과를 지우고, 잠시 뒤 새 주소를 자동으로 불러온다.</summary>
    private void UrlTextChanged(string old)
    {
        autoFetchCancel?.Cancel();
        var trimmed = UrlText.Trim();
        // 불러온 주소와 같으면(앞뒤 공백만 바뀐 경우 포함) 그대로 둔다.
        if (loadedUrlText is not null && trimmed == loadedUrlText.Trim()) return;
        if (IsFetching)
        {
            var cancel = fetchCancel;
            fetchCancel = null;
            cancel?.Cancel();
        }
        loadedUrlText = null;
        ClearResult();
        Stage = ExtractStage.Idle;
        if (trimmed.Length == 0) return;
        var autoCancel = new CancellationTokenSource();
        autoFetchCancel = autoCancel;
        _ = AutoFetchAsync(autoCancel.Token);
    }

    private async Task AutoFetchAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(autoFetchDelay, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        // 입력 중인 미완성 주소는 조용히 기다린다(오류는 직접 "불러오기"·Enter 때만 보인다).
        try { YouTubeUrl.Parse(UrlText); } catch (EngineException) { return; }
        Fetch();
    }
}
