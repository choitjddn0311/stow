using System.Diagnostics;
using System.Text;

namespace Stow.Core.Engine;

/// <summary>프로세스 출력 한 줄.</summary>
public readonly record struct OutputLine(bool IsError, string Text);

/// <summary>끝난 프로세스의 결과.</summary>
public sealed record ProcessResult(int ExitCode, IReadOnlyList<string> Stdout, IReadOnlyList<string> Stderr)
{
    public bool IsSuccess => ExitCode == 0;
}

/// <summary>
/// 외부 프로그램을 실행하고 출력을 줄 단위로 넘긴다.
/// - 인자는 <see cref="ProcessStartInfo.ArgumentList"/>로 넘긴다(셸 문자열을 만들지 않는다).
/// - 취소하면 자식 프로세스까지 모두 끝내고, 끝날 때까지 기다린 뒤 <see cref="OperationCanceledException"/>을 던진다.
/// - Windows에서는 Job Object에 넣어 앱이 비정상 종료돼도 자식 프로세스가 남지 않게 한다.
/// </summary>
public sealed class ProcessRunner
{
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
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            throw new ProcessLaunchException(command.Executable, error);
        }
        // 입력은 쓰지 않는다(프로그램이 입력을 기다리며 멈추지 않게 바로 닫는다).
        process.StandardInput.Close();
        using var job = OperatingSystem.IsWindows() ? JobObject.TryCreateFor(process) : null;

        var stdout = new List<string>();
        var stderr = new List<string>();
        var gate = new object();
        void Record(bool isError, string text)
        {
            lock (gate) (isError ? stderr : stdout).Add(text);
            onLine?.Invoke(new OutputLine(isError, text));
        }

        var readOut = PumpAsync(process.StandardOutput, text => Record(false, text));
        var readErr = PumpAsync(process.StandardError, text => Record(true, text));

        using (cancellationToken.Register(() => Kill(process)))
        {
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            await Task.WhenAll(readOut, readErr).ConfigureAwait(false);
        }
        cancellationToken.ThrowIfCancellationRequested();
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

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // 이미 끝났다.
        }
    }
}

/// <summary>프로그램을 실행하지 못했다(파일 없음, 실행 권한 없음 등).</summary>
public sealed class ProcessLaunchException(string executable, Exception inner)
    : Exception($"실행하지 못했습니다: {executable}", inner)
{
    public string Executable { get; } = executable;
}
