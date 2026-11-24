using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Tests;

/// <summary>
/// 실제 엔진(yt-dlp·ffmpeg)으로 추출 흐름 전체를 확인한다. 엔진 폴더를 STOW_ENGINE_DIR로 줄 때만 실행한다
/// (Windows CI x64가 준다). 네트워크 없이 직접 만든 WAV를 file:// 주소로 넣는다.
/// </summary>
public class YtDlpClientIntegrationTests
{
    private static string? EngineDirectory => Environment.GetEnvironmentVariable("STOW_ENGINE_DIR");

    public static TheoryData<string> Formats => ["mp3", "wav", "flac"];

    [Theory]
    [MemberData(nameof(Formats))]
    public async Task ExtractsLocalFile(string name)
    {
        Assert.SkipUnless(EngineDirectory is not null, "STOW_ENGINE_DIR가 없어 건너뜀(Windows CI에서 실행)");
        OutputFormat format = name switch
        {
            "mp3" => new OutputFormat.Mp3(Mp3Bitrate.Kbps192),
            "wav" => new OutputFormat.Wav(),
            _ => new OutputFormat.Flac(),
        };
        var root = Directory.CreateTempSubdirectory("stow-it-");
        try
        {
            var source = Path.Combine(root.FullName, "tone source.wav");
            WriteToneWav(source, seconds: 3);
            var output = Directory.CreateDirectory(Path.Combine(root.FullName, "out")).FullName;
            var work = Directory.CreateDirectory(Path.Combine(root.FullName, "work")).FullName;
            var engine = new EngineLocator(EngineDirectory!);
            var client = new YtDlpClient(engine) { AdditionalArguments = ["--enable-file-urls"], WorkDirectoryRoot = work };
            var progress = new List<ExtractProgress>();

            var file = await client.ExtractAsync(new Uri(source), new ExtractOptions(format, output), "결과: 테스트",
                p => { lock (progress) progress.Add(p); }, TestContext.Current.CancellationToken);

            Assert.Equal(Path.Combine(output, $"결과- 테스트.{format.FileExtension}"), file);
            var probe = await new ProcessRunner().RunAsync(new ProcessCommand(engine.Ffprobe,
                ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name:format=duration:format_tags=title",
                 "-of", "default=noprint_wrappers=1", file]), cancellationToken: TestContext.Current.CancellationToken);
            Assert.True(probe.IsSuccess, string.Join("\n", probe.Stderr));
            var values = probe.Stdout.Select(l => l.Split('=', 2)).Where(p => p.Length == 2)
                .ToDictionary(p => p[0].ToLowerInvariant(), p => p[1]);
            Assert.Equal(name switch { "mp3" => "mp3", "wav" => "pcm_s16le", _ => "flac" }, values["codec_name"]);
            Assert.InRange(double.Parse(values["duration"], System.Globalization.CultureInfo.InvariantCulture), 2.8, 3.2);
            Assert.Equal("tone source", values["tag:title"]);  // --embed-metadata
            Assert.Contains(progress, p => p is ExtractProgress.Downloading { Fraction: 1 });
            Assert.Contains(progress, p => p is ExtractProgress.Converting);
            // 작업 폴더는 지워지고, 저장 위치에는 결과 파일만 있다.
            Assert.Empty(Directory.GetFileSystemEntries(work));
            Assert.Equal([file], Directory.GetFiles(output));
        }
        finally
        {
            root.Delete(true);
        }
    }

    [Fact]
    public async Task MissingEngineIsReportedAsMissingComponent()
    {
        var empty = Directory.CreateTempSubdirectory("stow-noengine-");
        try
        {
            var client = new YtDlpClient(new EngineLocator(empty.FullName));
            var error = await Assert.ThrowsAsync<EngineException>(() =>
                client.FetchMediaAsync(new Uri("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), TestContext.Current.CancellationToken));
            Assert.Equal(EngineErrorKind.MissingComponent, error.Kind);
        }
        finally { empty.Delete(true); }
    }

    [Fact]
    public async Task MissingYtDlpFileIsReportedBeforeRunning()
    {
        // python.exe 등은 있고 yt-dlp만 없을 때도 "다시 설치" 안내가 나와야 한다(알 수 없는 오류가 아니라).
        var dir = Directory.CreateTempSubdirectory("stow-partial-");
        try
        {
            var engine = new EngineLocator(dir.FullName);
            Directory.CreateDirectory(Path.Combine(dir.FullName, "python"));
            foreach (var path in new[] { engine.Python, engine.Deno, engine.Ffmpeg, engine.Ffprobe }) File.WriteAllText(path, "");
            var error = await Assert.ThrowsAsync<EngineException>(() =>
                new YtDlpClient(engine).FetchMediaAsync(new Uri("https://youtu.be/dQw4w9WgXcQ"), TestContext.Current.CancellationToken));
            Assert.Equal(EngineErrorKind.MissingComponent, error.Kind);
            Assert.Equal("yt-dlp", error.Detail);
        }
        finally { dir.Delete(true); }
    }

    /// <summary>스테레오 16비트 44.1kHz 사인파 WAV.</summary>
    private static void WriteToneWav(string path, int seconds)
    {
        const int rate = 44100, channels = 2, bits = 16;
        var samples = rate * seconds;
        using var writer = new BinaryWriter(File.Create(path));
        var dataSize = samples * channels * bits / 8;
        writer.Write("RIFF"u8); writer.Write(36 + dataSize); writer.Write("WAVE"u8);
        writer.Write("fmt "u8); writer.Write(16); writer.Write((short)1); writer.Write((short)channels);
        writer.Write(rate); writer.Write(rate * channels * bits / 8); writer.Write((short)(channels * bits / 8)); writer.Write((short)bits);
        writer.Write("data"u8); writer.Write(dataSize);
        for (var i = 0; i < samples; i++)
        {
            var value = (short)(Math.Sin(2 * Math.PI * 440 * i / rate) * 8000);
            writer.Write(value); writer.Write(value);
        }
    }
}
