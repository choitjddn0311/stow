using System.Diagnostics;
using Stow.Core.Engine;

namespace Stow.Core.Tests;

/// <summary>Mac·Linux(sh)와 Windows(PowerShell) 양쪽에서 도는 프로세스 실행 테스트.</summary>
public class ProcessRunnerTests
{
    private static ProcessCommand Script(string unix, string windows) => OperatingSystem.IsWindows()
        ? new ProcessCommand("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", windows])
        : new ProcessCommand("/bin/sh", ["-c", unix]);

    [Fact]
    public async Task CapturesLinesAndExitCode()
    {
        var lines = new List<OutputLine>();
        var result = await new ProcessRunner().RunAsync(
            Script(
                "printf 'one\\ntwo\\n'; printf 'oops\\n' >&2; exit 3",
                "[Console]::Out.WriteLine('one'); [Console]::Out.WriteLine('two'); [Console]::Error.WriteLine('oops'); exit 3"),
            line => { lock (lines) lines.Add(line); },
            TestContext.Current.CancellationToken);

        Assert.Equal(3, result.ExitCode);
        Assert.False(result.IsSuccess);
        Assert.Equal(["one", "two"], result.Stdout);
        Assert.Equal(["oops"], result.Stderr);
        Assert.Contains(new OutputLine(true, "oops"), lines);
    }

    [Fact]
    public async Task ArgumentsArePassedAsIsWithoutShellParsing()
    {
        // 공백·따옴표·셸 특수 문자가 든 인자가 한 덩어리로 그대로 전달된다.
        const string tricky = "a b \"c\" $HOME & | ; 한글";
        string? script = null;
        try
        {
            ProcessCommand command;
            if (OperatingSystem.IsWindows())
            {
                // -Command 뒤의 인자는 $args로 오지 않으므로 스크립트 파일(-File)로 받는다. 한글이 깨지지 않게 UTF-8로 출력한다.
                script = Path.Combine(Path.GetTempPath(), $"stow-echo-{Guid.NewGuid()}.ps1");
                File.WriteAllText(script, "[Console]::OutputEncoding = [Text.Encoding]::UTF8\n[Console]::Out.WriteLine($args[0])\n");
                command = new ProcessCommand("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, tricky]);
            }
            else
            {
                command = new ProcessCommand("/bin/sh", ["-c", "printf '%s\\n' \"$1\"", "sh", tricky]);
            }
            var result = await new ProcessRunner().RunAsync(command, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Equal([tricky], result.Stdout);
        }
        finally
        {
            if (script is not null) File.Delete(script);
        }
    }

    [Fact]
    public async Task CarriageReturnsSplitLines()
    {
        var result = await new ProcessRunner().RunAsync(
            Script("printf '10%%\\r50%%\\r100%%\\n'", "[Console]::Out.Write(\"10%`r50%`r100%`n\")"),
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(["10%", "50%", "100%"], result.Stdout);
    }

    [Fact]
    public async Task CallbacksNeverOverlapAcrossStreams()
    {
        var active = 0;
        var overlapped = false;
        var count = 0;
        await new ProcessRunner().RunAsync(
            Script(
                "i=0; while [ $i -lt 300 ]; do echo out$i; echo err$i >&2; i=$((i+1)); done",
                "for ($i = 0; $i -lt 300; $i++) { [Console]::Out.WriteLine(\"out$i\"); [Console]::Error.WriteLine(\"err$i\") }"),
            _ =>
            {
                if (Interlocked.Increment(ref active) > 1) overlapped = true;
                Thread.SpinWait(200);
                count++;
                Interlocked.Decrement(ref active);
            },
            TestContext.Current.CancellationToken);
        Assert.False(overlapped, "onLine이 동시에 호출됨");
        Assert.Equal(600, count);
    }

    [Fact]
    public async Task KeepsOnlyTheLastLinesInResult()
    {
        var total = ProcessRunner.MaxKeptLines + 100;
        var seen = 0;
        var result = await new ProcessRunner().RunAsync(
            Script($"i=0; while [ $i -lt {total} ]; do echo $i; i=$((i+1)); done",
                   $"for ($i = 0; $i -lt {total}; $i++) {{ [Console]::Out.WriteLine($i) }}"),
            _ => seen++,
            TestContext.Current.CancellationToken);
        Assert.Equal(total, seen);  // 줄 단위 전달은 모두
        Assert.Equal(ProcessRunner.MaxKeptLines, result.Stdout.Count);  // 결과에는 마지막 줄들만
        Assert.Equal((total - 1).ToString(), result.Stdout[^1]);
    }

    [Fact]
    public async Task MissingExecutableThrowsLaunchError()
    {
        var command = new ProcessCommand(Path.Combine(Path.GetTempPath(), "no-such-program-" + Guid.NewGuid()), []);
        await Assert.ThrowsAsync<ProcessLaunchException>(() =>
            new ProcessRunner().RunAsync(command, cancellationToken: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CancelKillsChildProcessesToo()
    {
        // 자식 프로세스를 띄우고 그 PID를 출력한 뒤 기다리는 스크립트
        var command = Script(
            "sleep 30 & echo $!; wait",
            "$p = Start-Process -FilePath ping -ArgumentList '-n','60','127.0.0.1' -PassThru -WindowStyle Hidden; " +
            "[Console]::Out.WriteLine($p.Id); [Console]::Out.Flush(); $p.WaitForExit()");
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var childPid = new TaskCompletionSource<int>();
        var run = new ProcessRunner().RunAsync(command, line =>
        {
            if (!line.IsError && int.TryParse(line.Text.Trim(), out var pid)) childPid.TrySetResult(pid);
        }, cancel.Token);

        var pid = await childPid.Task.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
        var started = Stopwatch.StartNew();
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
        Assert.True(started.Elapsed < TimeSpan.FromSeconds(10), $"취소가 늦음: {started.Elapsed}");

        // 자식도 끝나 있어야 한다(조금 기다려 준다).
        for (var i = 0; i < 50 && IsRunning(pid); i++) await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(IsRunning(pid), $"자식 프로세스 {pid}가 남아 있음");
    }

    private static bool IsRunning(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}
