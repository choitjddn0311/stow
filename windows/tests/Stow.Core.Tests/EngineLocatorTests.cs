using Stow.Core.Engine;

namespace Stow.Core.Tests;

public class EngineLocatorTests
{
    [Fact]
    public void YtDlpRunsThroughBundledPythonInIsolatedMode()
    {
        var engine = new EngineLocator(Path.Combine("C:", "Stow", "engine"));
        var command = engine.YtDlpCommand(["--version"]);
        Assert.Equal(engine.Python, command.Executable);
        Assert.Equal(["-I", "-B", engine.YtDlp, "--version"], command.Arguments);
        Assert.Equal("1", command.Environment!["PYTHONUTF8"]);
        Assert.Equal(engine.Directory, engine.FfmpegDirectory);
    }

    [Fact]
    public void ReportsMissingComponents()
    {
        var directory = Directory.CreateTempSubdirectory("stow-engine-");
        try
        {
            var engine = new EngineLocator(directory.FullName);
            Assert.Equal(["Python", "yt-dlp", "deno", "ffmpeg", "ffprobe"], engine.MissingComponents());

            Directory.CreateDirectory(Path.Combine(directory.FullName, "python"));
            foreach (var path in new[] { engine.Python, engine.YtDlp, engine.Deno, engine.Ffmpeg }) File.WriteAllText(path, "");
            Assert.Equal(["ffprobe"], engine.MissingComponents());
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
