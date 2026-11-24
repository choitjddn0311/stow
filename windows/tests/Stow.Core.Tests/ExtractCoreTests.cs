using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Tests;

public class ProgressParserTests
{
    [Fact]
    public void ParsesDownloadProgress()
    {
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(261120.0 / 529244.0, 256731519.09, 3)),
            ProgressParser.Parse("[stow:download] downloading 261120 529244 NA 256731519.09 3"));
    }

    [Fact]
    public void UsesEstimatedTotalAndHandlesUnknown()
    {
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(0.25, null, null)),
            ProgressParser.Parse("[stow:download] downloading 50 NA 200 NA NA"));
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(null, null, null)),
            ProgressParser.Parse("[stow:download] downloading 1024 NA NA NA NA"));
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(1, 327260832.4, null)),
            ProgressParser.Parse("[stow:download] finished 529244 529244 NA 327260832.4 NA"));
    }

    [Theory]
    [InlineData("avc1.640028 none", DownloadPart.Video)]
    [InlineData("none mp4a.40.2", DownloadPart.Audio)]
    [InlineData("avc1.42001E mp4a.40.2", DownloadPart.Combined)]
    public void DownloadPartFromCodecs(string codecs, DownloadPart part)
    {
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(0.5, null, null, part)),
            ProgressParser.Parse($"[stow:download] downloading 50 100 NA NA NA {codecs}"));
    }

    [Fact]
    public void ParsesPostprocessorsAndOutputFile()
    {
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Converting()), ProgressParser.Parse("[stow:postprocess] started ExtractAudio"));
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Merging()), ProgressParser.Parse("[stow:postprocess] started Merger"));
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.EmbeddingMetadata()), ProgressParser.Parse("[stow:postprocess] started Metadata"));
        Assert.Null(ProgressParser.Parse("[stow:postprocess] finished Merger"));
        Assert.Equal(new ProgressEvent.OutputFile(@"C:\work\abc.mp3"), ProgressParser.Parse(@"[stow:file] C:\work\abc.mp3"));
    }

    [Fact]
    public void HugeEtaIsUnknown()
    {
        Assert.Equal(new ProgressEvent.Progress(new ExtractProgress.Downloading(0.5, 1, null)),
            ProgressParser.Parse("[stow:download] downloading 50 100 NA 1 3000000000"));
    }

    [Theory]
    [InlineData("[download]  42.0% of 3.00MiB")]
    [InlineData("[stow:download] downloading 1 2")]
    [InlineData("[stow:file] ")]
    [InlineData("WARNING: something")]
    public void IgnoresOtherLines(string line)
    {
        Assert.Null(ProgressParser.Parse(line));
    }

    [Fact]
    public void OverallProgressFillsOneBarAcrossParts()
    {
        Assert.Equal(0, ExtractProgress.Overall(0, DownloadPart.Video));
        Assert.Equal(ExtractProgress.VideoShare, ExtractProgress.Overall(1, DownloadPart.Video));
        Assert.Equal(ExtractProgress.VideoShare, ExtractProgress.Overall(0, DownloadPart.Audio));
        Assert.Equal(1, ExtractProgress.Overall(1, DownloadPart.Audio), 9);
        Assert.Equal(0.3, ExtractProgress.Overall(0.3, DownloadPart.Combined));
        Assert.Equal(42, ExtractProgress.DisplayPercent(0.415));
    }
}

public class YtDlpErrorMapperTests
{
    [Theory]
    [InlineData("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video", EngineErrorKind.PrivateVideo)]
    [InlineData("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", EngineErrorKind.AgeRestricted)]
    [InlineData("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser", EngineErrorKind.BlockedByYouTube)]
    [InlineData("ERROR: [youtube] abc: Join this channel to get access to members-only content like this video", EngineErrorKind.LoginRequired)]
    [InlineData("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader", EngineErrorKind.VideoUnavailable)]
    [InlineData("ERROR: [youtube] abc: The uploader has not made this video available in your country", EngineErrorKind.VideoUnavailable)]
    [InlineData("ERROR: [youtube] abc: This live event will begin in 3 hours.", EngineErrorKind.LiveNotSupported)]
    [InlineData("ERROR: Unsupported URL: https://www.youtube.com/about", EngineErrorKind.UnsupportedUrl)]
    [InlineData("ERROR: [youtube] abc: Requested format is not available. Use --list-formats", EngineErrorKind.NoAudioFormat)]
    [InlineData("ERROR: [youtube] abc: Unable to download webpage: <urlopen error [Errno 11001] getaddrinfo failed>", EngineErrorKind.Network)]
    [InlineData("ERROR: unable to write data: [Errno 28] No space left on device", EngineErrorKind.DiskFull)]
    [InlineData("ERROR: unable to open for writing: [Errno 13] Permission denied: 'C:\\x.part'", EngineErrorKind.PermissionDenied)]
    [InlineData("ERROR: Postprocessing: audio conversion failed: Error opening output files", EngineErrorKind.ConversionFailed)]
    [InlineData("ERROR: [youtube] abc: Unable to download webpage: HTTP Error 429: Too Many Requests", EngineErrorKind.BlockedByYouTube)]
    [InlineData("ERROR: unable to download video data: HTTP Error 403: Forbidden", EngineErrorKind.BlockedByYouTube)]
    [InlineData("ERROR: [youtube] abc: Video unavailable. This content isn’t available, try again later.", EngineErrorKind.BlockedByYouTube)]
    public void MapsKnownErrors(string line, EngineErrorKind expected)
    {
        Assert.Equal(expected, YtDlpErrorMapper.Map(["WARNING: ignored", line]).Kind);
    }

    [Fact]
    public void VideoFormatErrors()
    {
        string[] missing = ["ERROR: [youtube] abc: Requested format is not available. Use --list-formats"];
        Assert.Equal(EngineErrorKind.NoVideoFormat, YtDlpErrorMapper.Map(missing, video: true).Kind);
        Assert.Equal(EngineErrorKind.NoAudioFormat, YtDlpErrorMapper.Map(missing).Kind);
        Assert.Equal(EngineErrorKind.NoAudioFormat, YtDlpErrorMapper.Map(["ERROR: [youtube] abc: No video formats found!"], video: true).Kind);
    }

    [Fact]
    public void UnknownKeepsTheTail()
    {
        var error = YtDlpErrorMapper.Map(["[stow:download] x", "WARNING: w", "Traceback (most recent call last):", "KeyError: 'x'"]);
        Assert.Equal(EngineErrorKind.Unknown, error.Kind);
        Assert.Equal("Traceback (most recent call last):\nKeyError: 'x'", error.Detail);
        Assert.Equal("추출 중 알 수 없는 오류가 발생했습니다.", error.Message);
    }
}

public class YtDlpArgumentsTests
{
    private static readonly EngineLocator Engine = new(Path.Combine("C:", "Stow", "engine"));
    private static readonly Uri Url = new("https://youtu.be/abc");

    private static bool ContainsPair(IReadOnlyList<string> args, string a, string b) =>
        Enumerable.Range(0, args.Count - 1).Any(i => args[i] == a && args[i + 1] == b);

    [Fact]
    public void MetadataUsesCommonArgumentsAndEndsWithUrl()
    {
        var args = new YtDlpArguments(Engine).Metadata(Url);
        Assert.Contains("--ignore-config", args);
        Assert.Contains("--no-playlist", args);
        Assert.Contains("--dump-single-json", args);
        Assert.True(ContainsPair(args, "--playlist-end", "500"));
        Assert.True(ContainsPair(args, "--js-runtimes", "deno:" + Engine.Deno));
        Assert.True(ContainsPair(args, "--ffmpeg-location", Engine.FfmpegDirectory));
        Assert.Equal(["--", "https://youtu.be/abc"], args.TakeLast(2));
    }

    [Fact]
    public void Mp3UsesConstantBitrate()
    {
        var args = new YtDlpArguments(Engine).Extract(Url, new OutputFormat.Mp3(Mp3Bitrate.Kbps320), @"C:\w");
        Assert.True(ContainsPair(args, "--audio-format", "mp3"));
        Assert.True(ContainsPair(args, "--audio-quality", "320K"));
        Assert.True(ContainsPair(args, "--paths", @"home:C:\w"));
        Assert.Contains("--embed-metadata", args);
    }

    [Fact]
    public void LosslessFormatsHaveNoQuality()
    {
        foreach (OutputFormat format in new OutputFormat[] { new OutputFormat.Wav(), new OutputFormat.Flac() })
        {
            var args = new YtDlpArguments(Engine).Extract(Url, format, @"C:\w");
            Assert.True(ContainsPair(args, "--audio-format", format.FileExtension!));
            Assert.DoesNotContain("--audio-quality", args);
        }
    }

    [Fact]
    public void Mp4PicksH264AndMergesWithoutAudioExtraction()
    {
        var args = new YtDlpArguments(Engine).Extract(Url, new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P720), @"C:\w");
        Assert.True(ContainsPair(args, "--format", "bv[vcodec^=avc1][protocol!*=m3u8]+ba[ext=m4a][protocol!*=m3u8]/b[ext=mp4][protocol!*=m3u8]"));
        Assert.True(ContainsPair(args, "--format-sort", "res:720"));
        Assert.True(ContainsPair(args, "--merge-output-format", "mp4"));
        Assert.DoesNotContain("--extract-audio", args);
    }

    [Fact]
    public void BestQualityPrefersMp4Compatible()
    {
        var best = new YtDlpArguments(Engine).Extract(Url, new OutputFormat.Video(VideoFormat.Best, VideoResolution.Best), @"C:\w");
        Assert.True(ContainsPair(best, "--format-sort", "res,vcodec:av01"));
        Assert.True(ContainsPair(best, "--merge-output-format", "mp4/webm/mkv"));
        var limited = new YtDlpArguments(Engine).Extract(Url, new OutputFormat.Video(VideoFormat.Best, VideoResolution.P1440), @"C:\w");
        Assert.True(ContainsPair(limited, "--format-sort", "res:1440,vcodec:av01"));
    }
}

public class FileNamingTests
{
    [Theory]
    // Mac과 같은 규칙
    [InlineData("평범한 제목", "평범한 제목")]
    [InlineData("AC/DC: Live", "AC-DC- Live")]
    [InlineData("  앞뒤   공백\n줄바꿈\t탭  ", "앞뒤 공백 줄바꿈 탭")]
    [InlineData("...숨김 파일", "숨김 파일")]
    [InlineData("", "오디오")]
    [InlineData("///", "---")]
    [InlineData("...", "오디오")]
    [InlineData(". .숨김", "숨김")]
    [InlineData(" . . ", "오디오")]
    // Windows 규칙
    [InlineData("Why? \"Live\" <A|B> *1*", "Why？ ＂Live＂ ＜A｜B＞ ＊1＊")]
    [InlineData(@"C:\path\name", "C--path-name")]
    [InlineData("끝에 점...", "끝에 점")]
    [InlineData("끝 공백 . ", "끝 공백")]
    [InlineData("CON", "CON_")]
    [InlineData("nul", "nul_")]
    [InlineData("com1.final", "com1_.final")]
    [InlineData("CONSOLE", "CONSOLE")]
    [InlineData("COM¹", "COM¹_")]
    [InlineData("conin$.txt", "conin$_.txt")]
    [InlineData("LPT0", "LPT0_")]
    public void Sanitizes(string title, string expected)
    {
        Assert.Equal(expected, FileNaming.Sanitize(title));
    }

    [Fact]
    public void TruncatesByBytesWithoutBreakingCharacters()
    {
        var name = FileNaming.Sanitize(string.Concat(Enumerable.Repeat("가👍🏽", 100)));
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(name) <= FileNaming.MaxBytes);
        Assert.StartsWith("가👍🏽가", name);
        Assert.False(name.EndsWith("👍", StringComparison.Ordinal));  // 피부색 조합 중간에서 끊기지 않음
    }
}

public class MoveToDestinationTests
{
    [Fact]
    public void NumbersDuplicatesInsteadOfOverwriting()
    {
        var dir = Directory.CreateTempSubdirectory("stow-move-");
        try
        {
            File.WriteAllText(Path.Combine(dir.FullName, "곡.mp3"), "old");
            var source = Path.Combine(dir.FullName, "src.tmp");
            File.WriteAllText(source, "new");
            var result = YtDlpClient.MoveToDestination(source, dir.FullName, "곡", "mp3");
            Assert.Equal(Path.Combine(dir.FullName, "곡 (2).mp3"), result);
            Assert.Equal("old", File.ReadAllText(Path.Combine(dir.FullName, "곡.mp3")));
            Assert.Equal("new", File.ReadAllText(result));
        }
        finally { dir.Delete(true); }
    }

    [Fact]
    public void ShortensNameToFitPathLimit()
    {
        var dir = Directory.CreateTempSubdirectory("stow-move-");
        try
        {
            var source = Path.Combine(dir.FullName, "src.tmp");
            File.WriteAllText(source, "x");
            var result = YtDlpClient.MoveToDestination(source, dir.FullName, new string('가', 300), "flac");
            Assert.True(result.Length <= 259, $"{result.Length}");
            Assert.EndsWith(".flac", result);
        }
        finally { dir.Delete(true); }
    }

    [Fact]
    public void KoreanNameKeepsItsFullCharacterBudget()
    {
        var dir = Directory.CreateTempSubdirectory("stow-move-");
        try
        {
            var source = Path.Combine(dir.FullName, "src.tmp");
            File.WriteAllText(source, "x");
            var directoryLength = Path.GetFullPath(dir.FullName).TrimEnd(Path.DirectorySeparatorChar).Length;
            var budget = 259 - directoryLength - 1 - " (1000).".Length - "mp3".Length;
            var result = YtDlpClient.MoveToDestination(source, dir.FullName, new string('가', budget + 50), "mp3");
            // 바이트가 아니라 문자 수로 잘라 한도를 꽉 채운다.
            Assert.Equal(new string('가', budget), Path.GetFileNameWithoutExtension(result));
        }
        finally { dir.Delete(true); }
    }

    [Fact]
    public void TooLongDirectoryIsPathTooLong()
    {
        // 폴더 경로를 정확히 250자로 만든다: 260자 안쪽이라 긴 경로 설정과 무관하게 만들 수 있지만,
        // 파일 이름(" (1000).mp3" 포함)을 붙일 자리가 없다. 임시 폴더 경로 길이는 OS마다 달라 남은 길이를 계산한다.
        var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), new string('d', 100)));
        var remaining = 250 - parent.Length - 1;
        Assert.SkipWhen(remaining < 1, "임시 폴더 경로가 너무 길어 이 시험을 만들 수 없음");
        var deep = Path.Combine(parent, new string('e', remaining));
        Directory.CreateDirectory(deep);
        try
        {
            Assert.Equal(EngineErrorKind.PathTooLong,
                Assert.Throws<EngineException>(() => YtDlpClient.MoveToDestination("x", deep, "a", "mp3")).Kind);
        }
        finally { Directory.Delete(Path.Combine(Path.GetTempPath(), new string('d', 100)), true); }
    }

    [Fact]
    public void MissingDirectoryIsReported()
    {
        var missing = Path.Combine(Path.GetTempPath(), "stow-missing-" + Guid.NewGuid());
        Assert.Equal(EngineErrorKind.OutputDirectoryMissing,
            Assert.Throws<EngineException>(() => YtDlpClient.MoveToDestination("x", missing, "a", "mp3")).Kind);
    }
}
