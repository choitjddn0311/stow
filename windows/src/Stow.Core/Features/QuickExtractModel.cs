using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Features;

/// <summary>클립보드 읽기(앱에서는 Windows 클립보드, 테스트에서는 가짜).</summary>
public interface IClipboardReader
{
    /// <summary>클립보드가 바뀔 때마다 바뀌는 번호(Windows <c>GetClipboardSequenceNumber</c>).</summary>
    uint SequenceNumber { get; }

    /// <summary>클립보드의 글자. 글자가 없거나 읽지 못하면 null.</summary>
    Task<string?> ReadTextAsync();
}

public static class ClipboardUrl
{
    /// <summary>클립보드 글자가 유튜브 영상·재생목록 주소 하나면 앞뒤 공백을 지워 돌려준다.</summary>
    public static string? YouTubeText(string? text)
    {
        if (text is null) return null;
        var trimmed = text.Trim();
        // 여러 줄이거나 너무 길면 주소 하나가 아니다.
        if (trimmed.Length == 0 || trimmed.Length > 2048 || trimmed.IndexOfAny(['\r', '\n']) >= 0) return null;
        try
        {
            YouTubeUrl.Parse(trimmed);
            return trimmed;
        }
        catch (EngineException)
        {
            return null;
        }
    }
}

/// <summary>
/// 빠른 추출 창의 동작(Mac 앱 QuickPanelModel과 같다).
/// <list type="bullet">
/// <item>열 때 클립보드가 유튜브 주소면 채우고 바로 불러온다. 이미 대기열에 넣은 같은 클립보드 내용은 다시 채우지 않는다.</item>
/// <item>Enter는 "대기열에 추가": 불러오는 중이면 끝난 뒤 추가하고, 아직 안 불러왔으면 불러온 뒤 추가한다.</item>
/// <item>추가하면 창을 닫는다(받기는 대기열이 뒤에서 이어 간다).</item>
/// </list>
/// 불러오기·대기열 추가는 메인 창과 같은 <see cref="ExtractViewModel"/>(빠른 추출 전용 인스턴스, 설정·대기열은 공유)가 한다.
/// 화면 스레드에서만 부른다.
/// </summary>
public sealed class QuickExtractModel(ExtractViewModel extract, IClipboardReader clipboard) : ObservableObject
{
    private (string Text, uint Sequence)? filledFromClipboard;
    private uint? consumedSequence;
    private int presentation;
    private CancellationTokenSource? pendingAdd;
    private Task? pendingAddTask;

    public ExtractViewModel Extract { get; } = extract;

    /// <summary>창을 닫아 달라는 요청</summary>
    public event Action? CloseRequested;

    /// <summary>주소를 메인 창에서 열어 달라는 요청(재생목록에서 영상을 고를 때)</summary>
    public event Action<string>? OpenInMainWindowRequested;

    private bool isPresented;
    /// <summary>창이 열려 있는지(닫힌 뒤 늦게 끝난 클립보드 읽기·조회 결과를 버리는 데 쓴다)</summary>
    public bool IsPresented { get => isPresented; private set => Set(ref isPresented, value); }

    private bool addWhenReady;
    /// <summary>Enter를 눌렀지만 아직 불러오는 중이라, 끝나면 바로 추가할 상태</summary>
    public bool AddWhenReady { get => addWhenReady; private set => Set(ref addWhenReady, value); }

    /// <summary>창을 열 때: 이전 입력을 지우고, 클립보드에 새 유튜브 주소가 있으면 채워서 불러온다.</summary>
    public async Task PrepareForPresentationAsync()
    {
        var current = ++presentation;
        IsPresented = true;
        CancelPendingAdd();
        // 주소를 비우면 진행 중인 조회도 멈추고 처음 상태로 돌아간다.
        Extract.UrlText = "";
        Extract.StartOver();
        filledFromClipboard = null;

        var sequence = clipboard.SequenceNumber;
        if (sequence == consumedSequence) return;
        var text = ClipboardUrl.YouTubeText(await clipboard.ReadTextAsync());
        // 읽는 동안 창이 닫혔거나 다시 열렸거나, 사용자가 직접 입력했으면 쓰지 않는다.
        if (text is null || !IsPresented || current != presentation || Extract.UrlText.Length > 0) return;
        // 읽는 동안 클립보드가 바뀌었으면 어느 내용을 읽었는지 알 수 없으므로 채우지 않는다.
        if (clipboard.SequenceNumber != sequence) return;
        filledFromClipboard = (text, sequence);
        Extract.UrlText = text;
        Extract.Fetch();
    }

    /// <summary>Enter 또는 "추가" 버튼.</summary>
    public void Submit()
    {
        switch (Extract.Stage)
        {
            case ExtractStage.Video or ExtractStage.Playlist:
                Add();
                break;
            case ExtractStage.Fetching:
                AddAfterFetch();
                break;
            default:
                if (!Extract.CanFetch) return;
                Extract.Fetch();
                // 주소가 잘못되어 바로 실패하면 기다리지 않는다.
                if (Extract.IsFetching) AddAfterFetch();
                break;
        }
    }

    /// <summary>재생목록에서 영상을 고르려고 메인 창으로 넘긴다.</summary>
    public void OpenInMainWindow()
    {
        var text = Extract.UrlText;
        Dismiss();
        OpenInMainWindowRequested?.Invoke(text);
    }

    /// <summary>Esc·바깥 클릭: 조회를 멈추고 닫는다.</summary>
    public void Dismiss()
    {
        IsPresented = false;
        CancelPendingAdd();
        Extract.CancelFetch();
        CloseRequested?.Invoke();
    }

    /// <summary>테스트에서 Enter 뒤 추가가 끝날 때까지 기다린다.</summary>
    public async Task WaitForPendingAddAsync()
    {
        if (pendingAddTask is { } task) await task;
    }

    private void AddAfterFetch()
    {
        if (pendingAdd is not null) return;
        AddWhenReady = true;
        var cancel = new CancellationTokenSource();
        pendingAdd = cancel;
        pendingAddTask = AddAfterFetchAsync(cancel);
    }

    private async Task AddAfterFetchAsync(CancellationTokenSource cancel)
    {
        // 기다리는 동안 주소가 바뀌어 새 조회가 시작될 수 있으므로 조회가 없을 때까지 기다린다.
        while (Extract.IsFetching && !cancel.IsCancellationRequested)
        {
            await Extract.WaitForFetchAsync();
            if (Extract.IsFetching) await Task.Yield();
        }
        if (cancel.IsCancellationRequested || pendingAdd != cancel) return;
        pendingAdd = null;
        if (Extract.Stage is ExtractStage.Video or ExtractStage.Playlist) Add();
        else AddWhenReady = false;
    }

    private void CancelPendingAdd()
    {
        pendingAdd?.Cancel();
        pendingAdd = null;
        AddWhenReady = false;
    }

    private void Add()
    {
        CancelPendingAdd();
        if (!Extract.CanAddToQueue) return;
        if (filledFromClipboard is { } filled && filled.Text.Trim() == Extract.UrlText.Trim()) consumedSequence = filled.Sequence;
        Extract.AddToQueue();
        IsPresented = false;
        CloseRequested?.Invoke();
    }
}
