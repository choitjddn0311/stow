using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace Stow.Core.Engine;

/// <summary>프로세스 출력 한 줄.</summary>
public readonly record struct OutputLine(bool IsError, string Text);

/// <summary>
/// 끝난 프로세스의 결과. 출력은 스트림마다 마지막 <see cref="ProcessRunner.MaxKeptLines"/>줄까지만 남는다
/// (긴 다운로드의 진행률 줄을 모두 쌓지 않는다. 전체 출력은 onLine으로 받는다).
/// </summary>
public sealed record ProcessResult(int ExitCode, IReadOnlyList<string> Stdout, IReadOnlyList<string> Stderr)
{
    public bool IsSuccess => ExitCode == 0;
}

/// <summary>
/// 외부 프로그램을 실행하고 출력을 줄 단위로 넘긴다.
/// - 인자는 <see cref="ProcessStartInfo.ArgumentList"/>로 넘긴다(셸 문자열을 만들지 않는다).
/// - onLine은 한 번에 하나씩 호출된다(표준 출력·오류를 읽는 두 스레드가 동시에 부르지 않는다).
/// - 취소하면 자식 프로세스까지 모두 끝내고, 끝날 때까지 기다린 뒤 <see cref="OperationCanceledException"/>을 던진다.
///   취소가 프로세스가 끝난 뒤에 도착하면 결과를 그대로 돌려준다.
/// - Windows에서는 Job Object에 넣어, 취소할 때 Job 전체를 한 번에 끝내고 앱이 비정상 종료돼도 자식이 남지 않게 한다.
/// </summary>
public sealed class ProcessRunner
{
    /// <summary>결과에 남기는 스트림별 최대 줄 수(오류 문구 판별에는 마지막 줄들이면 충분하다).</summary>
    public const int MaxKeptLines = 2000;

    /// <summary>프로세스가 끝난 뒤 출력 읽기를 기다리는 최대 시간(파이프를 물려받은 손자 프로세스가 남아도 멈추지 않게).</summary>
    private static readonly TimeSpan DrainTimeout = TimeSpan.FromSeconds(5);

    public async Task<ProcessResult> RunAsync(
        ProcessCommand command,
        Action<OutputLine>? onLine = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var info = new ProcessStartInfo(command.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in command.Arguments) info.ArgumentList.Add(argument);
        if (command.Environment is { } environment)
        {
            foreach (var (key, value) in environment) info.Environment[key] = value;
        }

        using var process = new Process { StartInfo = info };
        try
        {
            process.Start();
        }
        catch (Exception error) when (error is Win32Exception or FileNotFoundException)
        {
            throw new ProcessLaunchException(command.Executable, error);
        }
        // 시작 직후 바로 Job에 넣는다(실행된 프로그램이 자식을 띄우기 전에). 실패해도 실행은 막지 않는다.
        using var job = OperatingSystem.IsWindows() ? JobObject.TryCreateFor(process) : null;
        // 입력은 쓰지 않는다(프로그램이 입력을 기다리며 멈추지 않게 바로 닫는다).
        process.StandardInput.Close();

        var stdout = new Queue<string>();
        var stderr = new Queue<string>();
        var gate = new object();
        void Record(bool isError, string text)
        {
            lock (gate)
            {
                var lines = isError ? stderr : stdout;
                lines.Enqueue(text);
                if (lines.Count > MaxKeptLines) lines.Dequeue();
                onLine?.Invoke(new OutputLine(isError, text));
            }
        }

        var readOut = PumpAsync(process.StandardOutput, text => Record(false, text));
        var readErr = PumpAsync(process.StandardError, text => Record(true, text));

        var killed = false;
        using (cancellationToken.Register(() =>
        {
            killed = true;
            Kill(process, job);
        }))
        {
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        }
        try
        {
            await Task.WhenAll(readOut, readErr).WaitAsync(DrainTimeout).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // 파이프를 물려받은 프로세스가 남아 있다. 받은 데까지만 쓴다.
        }
        if (killed) throw new OperationCanceledException(cancellationToken);
        lock (gate) return new ProcessResult(process.ExitCode, stdout.ToArray(), stderr.ToArray());
    }

    private static async Task PumpAsync(StreamReader reader, Action<string> onLine)
    {
        // ReadLine은 \n, \r\n, \r 모두를 줄 끝으로 본다(진행률을 \r로 덮어쓰는 출력도 줄마다 나뉜다).
        while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            onLine(line);
        }
    }

    /// <summary>
    /// 프로세스와 자식을 모두 끝낸다. Windows에서 Job에 들어 있으면 Job 전체를 한 번에 끝내고(빠짐없이),
    /// 아니면 프로세스 트리를 찾아 끝낸다. 취소 콜백에서 불리므로 예외를 밖으로 내보내지 않는다.
    /// </summary>
    private static void Kill(Process process, JobObject? job)
    {
        try
        {
            if (job is not null && OperatingSystem.IsWindows() && job.Terminate()) return;
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or AggregateException or NotSupportedException)
        {
            // 이미 끝났거나 끝나는 중이다(일부만 끝낸 경우도 WaitForExit가 마저 기다린다).
        }
    }
}

/// <summary>프로그램을 실행하지 못했다(파일 없음, 실행 권한 없음 등).</summary>
public sealed class ProcessLaunchException(string executable, Exception inner)
    : Exception($"실행하지 못했습니다: {executable}", inner)
{
    public string Executable { get; } = executable;
}
