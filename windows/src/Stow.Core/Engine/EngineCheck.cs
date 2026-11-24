using System.Diagnostics;

namespace Stow.Core.Engine;

/// <summary>엔진 구성 요소 하나를 실행해 본 결과.</summary>
public sealed record EngineCheckResult(string Name, bool IsOk, string Detail, TimeSpan Elapsed);

/// <summary>앱에 넣은 엔진이 이 PC에서 실행되는지 확인한다(버전 출력).</summary>
public static class EngineCheck
{
    public static async Task<IReadOnlyList<EngineCheckResult>> RunAsync(
        EngineLocator engine, ProcessRunner runner, CancellationToken cancellationToken = default)
    {
        var checks = new (string Name, ProcessCommand Command)[]
        {
            ("yt-dlp", engine.YtDlpCommand(["--version"])),
            ("ffmpeg", new ProcessCommand(engine.Ffmpeg, ["-hide_banner", "-version"])),
            ("ffprobe", new ProcessCommand(engine.Ffprobe, ["-hide_banner", "-version"])),
            ("deno", new ProcessCommand(engine.Deno, ["--version"])),
        };
        var results = new List<EngineCheckResult>();
        foreach (var (name, command) in checks)
        {
            var watch = Stopwatch.StartNew();
            try
            {
                var result = await runner.RunAsync(command, cancellationToken: cancellationToken).ConfigureAwait(false);
                var first = result.Stdout.FirstOrDefault(line => line.Length > 0) ?? "";
                results.Add(result.IsSuccess
                    ? new EngineCheckResult(name, true, first, watch.Elapsed)
                    : new EngineCheckResult(name, false, $"종료 코드 {result.ExitCode}: {string.Join(" ", result.Stderr.TakeLast(3))}", watch.Elapsed));
            }
            catch (ProcessLaunchException error)
            {
                results.Add(new EngineCheckResult(name, false, error.Message, watch.Elapsed));
            }
        }
        return results;
    }
}
