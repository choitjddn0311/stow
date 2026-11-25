using System.Collections.ObjectModel;
using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Features;

/// <summary>조회와 추출을 하는 엔진(실제는 <see cref="YtDlpClient"/>, 테스트는 가짜).</summary>
public interface IExtractEngine
{
    Task<FetchedMedia> FetchMediaAsync(Uri url, CancellationToken cancellationToken = default);
    Task<string> ExtractAsync(Uri url, ExtractOptions options, string fileName,
        Action<ExtractProgress>? progress = null, CancellationToken cancellationToken = default);
}

/// <summary>완료 알림과 탐색기 표시(테스트는 가짜).</summary>
public interface ICompletionNotifier
{
    /// <summary>처음 추출을 시작할 때(알림 권한 준비 등).</summary>
    void Prepare();
    void NotifyCompleted(string title, string file);
    void Reveal(string file);
}

public enum QueueStatus { Waiting, Running, Completed, Failed, Cancelled }

/// <summary>대기열 항목. 포맷·저장 위치는 넣을 때 고정한다.</summary>
public sealed class QueueItem : ObservableObject
{
    public QueueItem(Uri url, string title, ExtractOptions options, double? duration = null, Uri? thumbnailUrl = null, string? subfolder = null)
    {
        Url = url;
        Title = title;
        Options = options;
        Duration = duration;
        ThumbnailUrl = thumbnailUrl;
        Subfolder = subfolder is null ? null : FileNaming.Sanitize(subfolder);
    }

    public Guid Id { get; } = Guid.NewGuid();
    public Uri Url { get; }
    public string Title { get; }
    public ExtractOptions Options { get; }
    public double? Duration { get; }
    public Uri? ThumbnailUrl { get; }
    /// <summary>재생목록 하위 폴더 이름(정리된 이름). null이면 저장 위치에 바로 저장한다.</summary>
    public string? Subfolder { get; }

    /// <summary>실제로 저장할 폴더</summary>
    public string Destination => Subfolder is null ? Options.OutputDirectory : Path.Combine(Options.OutputDirectory, Subfolder);

    private QueueStatus status;
    public QueueStatus Status
    {
        get => status;
        internal set => Set(ref status, value, alsoChanged: [nameof(StatusText), nameof(IsRunning), nameof(IsProgressIndeterminate),
            nameof(ProgressValue), nameof(CanRetry), nameof(CanReveal), nameof(CanCancel), nameof(CanRemove), nameof(IsFinished)]);
    }

    private ExtractProgress? progress;
    public ExtractProgress? Progress
    {
        get => progress;
        internal set => Set(ref progress, value, alsoChanged: [nameof(StatusText), nameof(ProgressValue), nameof(IsProgressIndeterminate)]);
    }

    private string? outputFile;
    public string? OutputFile { get => outputFile; internal set => Set(ref outputFile, value, alsoChanged: nameof(StatusText)); }

    private EngineException? error;
    public EngineException? Error { get => error; internal set => Set(ref error, value, alsoChanged: nameof(StatusText)); }

    public bool IsRunning => Status == QueueStatus.Running;
    public bool IsFinished => Status is QueueStatus.Completed or QueueStatus.Failed or QueueStatus.Cancelled;
    public bool CanRetry => Status is QueueStatus.Failed or QueueStatus.Cancelled;
    public bool CanReveal => Status == QueueStatus.Completed;
    public bool CanCancel => Status is QueueStatus.Waiting or QueueStatus.Running;
    public bool CanRemove => IsFinished;

    /// <summary>진행 막대 값(0~1). 영상은 영상·오디오 두 단계를 막대 하나에 이어서 채운다.</summary>
    public double ProgressValue => Progress is ExtractProgress.Downloading { Fraction: { } f } d
        ? (Options.Format.IsVideo ? ExtractProgress.Overall(f, d.Part) : f)
        : 0;

    /// <summary>진행률을 모를 때(준비·변환·합치기) 움직이는 막대.</summary>
    public bool IsProgressIndeterminate => IsRunning && Progress is not ExtractProgress.Downloading { Fraction: not null };

    public string StatusText => Status switch
    {
        QueueStatus.Waiting => $"대기 중 · {DisplayText.Name(Options.Format)}",
        QueueStatus.Running => DisplayText.Progress(Progress, Options.Format),
        QueueStatus.Completed => $"저장했습니다: {Path.GetFileName(OutputFile)}",
        QueueStatus.Failed => "실패: " + (Error?.Message ?? "오류가 발생했습니다."),
        _ => "취소했습니다.",
    };

    /// <summary>진행률은 퍼센트·남은 시간·단계가 바뀔 때만 반영한다(화면을 너무 자주 다시 그리지 않게).</summary>
    internal void UpdateProgress(ExtractProgress value)
    {
        if (Progress is ExtractProgress.Downloading old && value is ExtractProgress.Downloading now
            && Percent(old.Fraction) == Percent(now.Fraction) && old.SecondsRemaining == now.SecondsRemaining && old.Part == now.Part)
        {
            return;
        }
        Progress = value;
    }

    private static int? Percent(double? fraction) => fraction is { } f ? ExtractProgress.DisplayPercent(f) : null;
}

/// <summary>
/// 추출 대기열(Mac 앱 ExtractQueue와 같은 동작).
/// - 한 번에 하나씩 순서대로 추출한다(유튜브 요청 차단 위험을 줄이려고).
/// - 재생목록 항목은 저장 위치 아래 재생목록 이름의 하위 폴더에 저장한다.
/// - 유튜브가 요청을 막으면 대기열을 멈추고 알린다. 항목을 추가하거나 "다시 시도"하면 이어 간다.
/// - 완료 알림은 대기열이 모두 끝났을 때 한 번 보낸다.
/// 화면 스레드에서만 부른다. 엔진의 진행률 콜백은 만들 때의 SynchronizationContext로 옮겨 반영한다.
/// </summary>
public sealed class ExtractQueue(IExtractEngine engine, ICompletionNotifier notifier) : ObservableObject
{
    private readonly SynchronizationContext? context = SynchronizationContext.Current;
    private Task? runTask;
    private CancellationTokenSource? runCancel;
    private QueueItem? running;
    private readonly List<string> completedInRun = [];

    public ObservableCollection<QueueItem> Items { get; } = [];

    private bool isPaused;
    /// <summary>유튜브 차단으로 멈춘 상태.</summary>
    public bool IsPaused { get => isPaused; private set => Set(ref isPaused, value); }

    private string? blockedMessage;
    /// <summary>차단으로 멈췄을 때 보여 줄 문구(없으면 null).</summary>
    public string? BlockedMessage { get => blockedMessage; private set => Set(ref blockedMessage, value); }

    public bool IsRunning => running is not null;
    public int WaitingCount => Items.Count(i => i.Status == QueueStatus.Waiting);
    public int CompletedCount => Items.Count(i => i.Status == QueueStatus.Completed);
    public int FailedCount => Items.Count(i => i.Status == QueueStatus.Failed);
    public bool HasFinishedItems => Items.Any(i => i.IsFinished);
    public bool HasPendingItems => Items.Any(i => !i.IsFinished);
    public bool IsEmpty => Items.Count == 0;

    /// <summary>예: "추출 중 1 · 대기 2 · 완료 1 · 실패 1"</summary>
    public string SummaryText
    {
        get
        {
            var parts = new List<string>();
            if (IsRunning) parts.Add("추출 중 1");
            if (WaitingCount > 0) parts.Add($"대기 {WaitingCount}");
            if (CompletedCount > 0) parts.Add($"완료 {CompletedCount}");
            if (FailedCount > 0) parts.Add($"실패 {FailedCount}");
            return parts.Count == 0 ? "대기열이 비어 있습니다" : string.Join(" · ", parts);
        }
    }

    public void Add(IEnumerable<QueueItem> newItems)
    {
        var list = newItems.ToList();
        if (list.Count == 0) return;
        notifier.Prepare();
        foreach (var item in list) Items.Add(item);
        if (IsPaused) Unpause();
        Changed();
        StartNextIfNeeded();
    }

    /// <summary>진행 중이면 취소하고, 대기 중이면 취소 상태로 둔다.</summary>
    public void Cancel(QueueItem item)
    {
        if (item == running) runCancel?.Cancel();
        else if (item.Status == QueueStatus.Waiting) { item.Status = QueueStatus.Cancelled; Changed(); }
    }

    /// <summary>진행 중이 아닌 항목을 목록에서 뺀다.</summary>
    public void Remove(QueueItem item)
    {
        if (item == running) return;
        Items.Remove(item);
        ResumeIfNothingBlocked();
        Changed();
    }

    /// <summary>실패·취소된 항목을 다시 대기열에 넣는다.</summary>
    public void Retry(QueueItem item)
    {
        if (!item.CanRetry) return;
        item.Error = null;
        item.Status = QueueStatus.Waiting;
        if (IsPaused) Unpause();
        Changed();
        StartNextIfNeeded();
    }

    public void CancelAll()
    {
        foreach (var item in Items.Where(i => i.Status == QueueStatus.Waiting)) item.Status = QueueStatus.Cancelled;
        runCancel?.Cancel();
        Changed();
    }

    public void ClearFinished()
    {
        foreach (var item in Items.Where(i => i.IsFinished).ToList()) Items.Remove(item);
        ResumeIfNothingBlocked();
        Changed();
    }

    /// <summary>차단으로 멈춘 뒤 막힌 항목을 모두 지웠으면 멈춤을 풀고 남은 항목을 이어 간다(빈 경고가 남지 않게).</summary>
    private void ResumeIfNothingBlocked()
    {
        if (!IsPaused || Items.Any(i => i.Error?.Kind == EngineErrorKind.BlockedByYouTube)) return;
        Unpause();
        StartNextIfNeeded();
    }

    /// <summary>차단으로 멈춘 대기열을 이어 간다.</summary>
    public void Resume()
    {
        Unpause();
        Changed();
        StartNextIfNeeded();
    }

    public void Reveal(QueueItem item)
    {
        if (item.OutputFile is { } file) notifier.Reveal(file);
    }

    /// <summary>앱을 종료할 때: 대기 항목은 두고 진행 중인 추출만 취소한 뒤 엔진 프로세스가 끝날 때까지 기다린다.</summary>
    public async Task CancelAndWaitAsync()
    {
        IsPaused = true;
        runCancel?.Cancel();
        if (runTask is { } task) await task.ConfigureAwait(false);
    }

    /// <summary>테스트에서 대기열이 빌 때까지 기다린다.</summary>
    public async Task WaitUntilIdleAsync()
    {
        while (runTask is { IsCompleted: false } task) await task;
    }

    private void Unpause()
    {
        BlockedMessage = null;
        foreach (var item in Items.Where(i => i.Status == QueueStatus.Failed && i.Error?.Kind == EngineErrorKind.BlockedByYouTube))
        {
            item.Error = null;
            item.Status = QueueStatus.Waiting;
        }
        IsPaused = false;
    }

    private void StartNextIfNeeded()
    {
        if (runTask is not null || IsPaused) return;
        var next = Items.FirstOrDefault(i => i.Status == QueueStatus.Waiting);
        if (next is null)
        {
            FinishRun();
            return;
        }
        running = next;
        next.Progress = null;
        next.Status = QueueStatus.Running;
        Changed();
        runCancel = new CancellationTokenSource();
        var task = RunAsync(next, runCancel.Token);
        // 추출이 기다림 없이 바로 끝나면 RunAsync가 이미 정리하고 다음 항목까지 시작했다.
        // 끝난 작업을 '진행 중'으로 남기지 않도록, 아직 진행 중일 때만 기록한다.
        if (!task.IsCompleted) runTask = task;
    }

    private async Task RunAsync(QueueItem item, CancellationToken cancellationToken)
    {
        try
        {
            PrepareDestination(item);
            var file = await engine.ExtractAsync(item.Url, item.Options with { OutputDirectory = item.Destination }, item.Title,
                progress => Post(() => { if (running == item) item.UpdateProgress(progress); }), cancellationToken);
            item.OutputFile = file;
            item.Status = QueueStatus.Completed;
            completedInRun.Add(file);
        }
        catch (OperationCanceledException)
        {
            item.Status = QueueStatus.Cancelled;
        }
        catch (Exception error)
        {
            var engineError = error as EngineException ?? new EngineException(EngineErrorKind.Unknown, error.Message, error);
            item.Error = engineError;
            item.Status = QueueStatus.Failed;
            if (engineError.Kind == EngineErrorKind.BlockedByYouTube)
            {
                IsPaused = true;
                BlockedMessage = engineError.Message;
            }
        }
        running = null;
        runCancel?.Dispose();
        runCancel = null;
        runTask = null;
        Changed();
        StartNextIfNeeded();
    }

    /// <summary>저장 폴더를 확인하고, 재생목록 하위 폴더는 만든다.</summary>
    private static void PrepareDestination(QueueItem item)
    {
        if (!Directory.Exists(item.Options.OutputDirectory)) throw new EngineException(EngineErrorKind.OutputDirectoryMissing);
        if (item.Subfolder is null) return;
        try
        {
            Directory.CreateDirectory(item.Destination);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new EngineException(EngineErrorKind.PermissionDenied, error.Message, error);
        }
    }

    /// <summary>대기열이 비면 이번에 완료한 것을 한 번 알린다.</summary>
    private void FinishRun()
    {
        if (completedInRun.Count == 0) return;
        var title = completedInRun.Count == 1 ? "1개 저장 완료" : $"{completedInRun.Count}개 저장 완료";
        notifier.NotifyCompleted(title, completedInRun[^1]);
        completedInRun.Clear();
    }

    private void Post(Action action)
    {
        if (context is null) action();
        else context.Post(_ => action(), null);
    }

    private void Changed()
    {
        Notify(nameof(IsRunning));
        Notify(nameof(WaitingCount));
        Notify(nameof(CompletedCount));
        Notify(nameof(FailedCount));
        Notify(nameof(HasFinishedItems));
        Notify(nameof(HasPendingItems));
        Notify(nameof(IsEmpty));
        Notify(nameof(SummaryText));
    }
}
