using Stow.Core.Features;
using Stow.Core.Models;

namespace Stow.Core.Engine;

/// <summary>yt-dlp로 영상 정보를 조회하고 오디오를 추출하거나 영상을 받는다(Mac 앱 YtDlpClient와 같은 흐름).</summary>
public sealed class YtDlpClient(EngineLocator engine, ProcessRunner? runner = null) : IExtractEngine
{
    private readonly ProcessRunner runner = runner ?? new ProcessRunner();

    /// <summary>테스트용 추가 yt-dlp 인자(예: 로컬 파일용 <c>--enable-file-urls</c>).</summary>
    public IReadOnlyList<string> AdditionalArguments { get; init; } = [];

    /// <summary>작업 폴더를 만들 위치. null이면 시스템 임시 폴더.</summary>
    public string? WorkDirectoryRoot { get; init; }

    /// <summary>Windows 경로 길이 한도(긴 경로 설정이 꺼져 있을 때). 결과 경로가 넘으면 이름을 줄인다.</summary>
    private const int MaxPathLength = 259;

    private YtDlpArguments Arguments => new(engine, AdditionalArguments);

    /// <summary>주소를 조회한다. 진행 중·예정 라이브 방송, 빈 재생목록이면 오류를 던진다.</summary>
    public async Task<FetchedMedia> FetchMediaAsync(Uri url, CancellationToken cancellationToken = default)
    {
        var result = await RunAsync(engine.YtDlpCommand(Arguments.Metadata(url)), null, cancellationToken).ConfigureAwait(false);
        if (!result.IsSuccess) throw YtDlpErrorMapper.Map(result.Stderr);
        var media = FetchedMedia.Parse(string.Join("\n", result.Stdout));
        return media switch
        {
            FetchedMedia.OfVideo { Metadata.LiveStatus: "is_live" or "is_upcoming" } => throw new EngineException(EngineErrorKind.LiveNotSupported),
            FetchedMedia.OfPlaylist { Playlist.Entries.Count: 0 } => throw new EngineException(EngineErrorKind.EmptyPlaylist),
            _ => media,
        };
    }

    /// <summary>
    /// 추출해 <c>options.OutputDirectory</c>에 <c>&lt;파일 이름&gt;.&lt;확장자&gt;</c>로 저장하고 최종 경로를 돌려준다.
    /// - 작업마다 따로 만든 임시 폴더에서 받고 변환한 뒤 결과만 옮긴다(성공·실패·취소 모두 임시 폴더를 지운다).
    /// - 같은 이름이 있으면 덮어쓰지 않고 <c>이름 (2).mp3</c>처럼 번호를 붙인다.
    /// </summary>
    public async Task<string> ExtractAsync(
        Uri url, ExtractOptions options, string fileName,
        Action<ExtractProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(options.OutputDirectory)) throw new EngineException(EngineErrorKind.OutputDirectoryMissing);
        var work = CreateWorkDirectory(options.OutputDirectory);
        try
        {
            string? output = null;
            var command = engine.YtDlpCommand(Arguments.Extract(url, options.Format, work));
            var result = await RunAsync(command, line =>
            {
                switch (ProgressParser.Parse(line.Text))
                {
                    case ProgressEvent.Progress p: progress?.Invoke(p.Value); break;
                    case ProgressEvent.OutputFile f: output = f.Path; break;
                }
            }, cancellationToken).ConfigureAwait(false);
            if (!result.IsSuccess) throw YtDlpErrorMapper.Map(result.Stderr, video: options.Format.IsVideo);
            if (output is null || !File.Exists(output)) throw new EngineException(EngineErrorKind.OutputMissing);
            // 최고 화질 영상은 받은 스트림에 따라 형식이 정해지므로 결과 파일의 확장자를 쓴다.
            var extension = options.Format.FileExtension ?? Path.GetExtension(output).TrimStart('.');
            return MoveToDestination(output, options.OutputDirectory, FileNaming.Sanitize(fileName), extension);
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// 작업 폴더: 저장 위치와 같은 드라이브에 만든다(옮길 때 복사 없이 이름만 바뀌고, 큰 영상이 다른 드라이브의 공간을 쓰지 않게).
    /// 임시 폴더가 같은 드라이브면 임시 폴더에, 아니면 저장 위치 안에 숨김 폴더로. 테스트는 <see cref="WorkDirectoryRoot"/>로 정한다.
    /// </summary>
    private string CreateWorkDirectory(string outputDirectory)
    {
        var name = "stow-" + Guid.NewGuid().ToString("N");
        if (WorkDirectoryRoot is { } root) return Directory.CreateDirectory(Path.Combine(root, name)).FullName;
        var temp = Path.GetTempPath();
        if (string.Equals(Path.GetPathRoot(Path.GetFullPath(temp)), Path.GetPathRoot(Path.GetFullPath(outputDirectory)),
                StringComparison.OrdinalIgnoreCase))
        {
            return Directory.CreateDirectory(Path.Combine(temp, name)).FullName;
        }
        try
        {
            var directory = Directory.CreateDirectory(Path.Combine(outputDirectory, "." + name));
            directory.Attributes |= FileAttributes.Hidden;
            return directory.FullName;
        }
        catch (UnauthorizedAccessException error)
        {
            throw new EngineException(EngineErrorKind.PermissionDenied, error.Message, error);
        }
    }

    private async Task<ProcessResult> RunAsync(ProcessCommand command, Action<OutputLine>? onLine, CancellationToken cancellationToken)
    {
        // 엔진 파일이 빠져 있으면 실행하기 전에 알린다(python.exe가 있어도 yt-dlp·ffmpeg가 없으면 알 수 없는 오류가 된다).
        var missing = engine.MissingComponents();
        if (missing.Count > 0) throw new EngineException(EngineErrorKind.MissingComponent, string.Join(", ", missing));
        try
        {
            return await runner.RunAsync(command, onLine, cancellationToken).ConfigureAwait(false);
        }
        catch (ProcessLaunchException error)
        {
            throw new EngineException(EngineErrorKind.LaunchFailed, error.Executable, error);
        }
    }

    /// <summary>결과 파일을 저장 위치로 옮긴다. 같은 이름이 있으면 번호를 붙이고, 경로가 너무 길면 이름을 줄인다.</summary>
    internal static string MoveToDestination(string source, string directory, string baseName, string extension)
    {
        if (!Directory.Exists(directory)) throw new EngineException(EngineErrorKind.OutputDirectoryMissing);
        // 가장 긴 번호 " (1000)."과 확장자를 붙여도 한도를 넘지 않게 이름 길이(UTF-16 문자 수)를 맞춘다.
        var budget = MaxPathLength - Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar).Length - 1 - " (1000).".Length - extension.Length;
        if (budget < 1) throw new EngineException(EngineErrorKind.PathTooLong);
        if (baseName.Length > budget) baseName = FileNaming.TruncateToChars(baseName, budget).TrimEnd('.', ' ');
        if (baseName.Length == 0) baseName = FileNaming.Fallback;

        for (var index = 1; index <= 1000; index++)
        {
            var name = index == 1 ? baseName : $"{baseName} ({index})";
            var destination = Path.Combine(directory, $"{name}.{extension}");
            if (File.Exists(destination) || Directory.Exists(destination)) continue;
            try
            {
                File.Move(source, destination, overwrite: false);
                return destination;
            }
            catch (IOException error) when (IsDiskFull(error))
            {
                // 다른 드라이브로 복사하다 공간이 모자라면 대상에 반쯤 쓴 파일이 남는다(바로 위에서 없음을 확인한 이름이다).
                TryDelete(destination);
                throw new EngineException(EngineErrorKind.DiskFull, error.Message, error);
            }
            catch (PathTooLongException error)
            {
                throw new EngineException(EngineErrorKind.PathTooLong, error.Message, error);
            }
            catch (DirectoryNotFoundException error)
            {
                throw new EngineException(EngineErrorKind.OutputDirectoryMissing, error.Message, error);
            }
            catch (IOException) when (File.Exists(destination) && File.Exists(source))
            {
                // 동시에 끝난 다른 작업이 먼저 같은 이름을 썼다(원본은 그대로 있다). 다음 번호로.
            }
            catch (UnauthorizedAccessException error)
            {
                throw new EngineException(EngineErrorKind.PermissionDenied, error.Message, error);
            }
            catch (IOException error)
            {
                // 다른 프로그램(백신 등)이 파일을 쓰고 있음, 네트워크 드라이브 오류 등
                throw new EngineException(EngineErrorKind.Unknown, error.Message, error);
            }
        }
        throw new EngineException(EngineErrorKind.Unknown, $"같은 이름의 파일이 너무 많습니다: {baseName}.{extension}");
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    /// <summary>ERROR_DISK_FULL(112), ERROR_HANDLE_DISK_FULL(39), ENOSPC(28).</summary>
    private static bool IsDiskFull(IOException error) => (error.HResult & 0xFFFF) is 112 or 39 or 28;
}
