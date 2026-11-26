using System.Text.Json;
using System.Text.Json.Serialization;
using Stow.Core.Features;
using Stow.Core.Models;

namespace Stow.Core.Settings;

public enum MediaKind { Audio, Video }

public enum AudioFormatKind { Mp3, Wav, Flac }

/// <summary>저장되는 값(JSON). 없는 값은 기본값을 쓴다(나중에 생긴 설정도 이전 파일에서 그대로 읽힌다).</summary>
public sealed class SettingsData
{
    public string? OutputDirectory { get; set; }
    public MediaKind? MediaKind { get; set; }
    public AudioFormatKind? AudioFormat { get; set; }
    public int? Mp3Bitrate { get; set; }
    public VideoFormat? VideoFormat { get; set; }
    public int? Mp4Resolution { get; set; }
    public int? BestResolution { get; set; }
    public int AcceptedNoticeVersion { get; set; }
    public List<string>? RecentOutputDirectories { get; set; }
    public string? QuickExtractHotKey { get; set; }
    public bool? KeepRunningInTray { get; set; }
    public bool TrayNoticeShown { get; set; }
}

public interface ISettingsStore
{
    SettingsData? Load();
    void Save(SettingsData data);
}

/// <summary><c>%APPDATA%\Stow\settings.json</c>에 저장한다. 임시 파일에 쓴 뒤 바꿔 넣어 반쯤 쓴 파일이 남지 않게 한다.</summary>
public sealed class JsonFileSettingsStore(string path) : ISettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public SettingsData? Load()
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(path), Options) : null;
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            return null;  // 읽을 수 없으면 기본값으로 시작한다.
        }
    }

    public void Save(SettingsData data)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(data, Options));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // 저장하지 못해도 앱은 계속 쓸 수 있다(다음 변경 때 다시 저장한다).
        }
    }
}

/// <summary>사용자 설정(Mac 앱 AppSettings와 같은 값). 바뀔 때마다 저장한다.</summary>
public sealed class AppSettings : ObservableObject
{
    private readonly ISettingsStore store;
    private readonly SettingsData data;

    public AppSettings(ISettingsStore store, string? defaultOutputDirectory = null)
    {
        this.store = store;
        data = store.Load() ?? new SettingsData();
        outputDirectory = data.OutputDirectory ?? defaultOutputDirectory ?? DefaultOutputDirectory;
        recentOutputDirectories = Recents(outputDirectory, data.RecentOutputDirectories ?? []);
    }

    /// <summary>빠른 추출 폴더 메뉴에 보일 최근 폴더 수</summary>
    public const int MaxRecentOutputDirectories = 5;

    /// <summary>기본 저장 위치: 사용자 폴더의 "다운로드".</summary>
    public static string DefaultOutputDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    private string outputDirectory;
    public string OutputDirectory
    {
        get => outputDirectory;
        set
        {
            // 같은 폴더(대소문자·끝 구분자만 다름)를 다시 고르면 아무것도 하지 않는다.
            if (SameDirectory(outputDirectory, value)) return;
            if (Set(ref outputDirectory, value))
            {
                data.OutputDirectory = value;
                recentOutputDirectories = Recents(value, recentOutputDirectories);
                Save();
                Notify(nameof(RecentOutputDirectories));
            }
        }
    }

    private IReadOnlyList<string> recentOutputDirectories;
    /// <summary>최근에 고른 저장 폴더(지금 폴더가 맨 앞, 최대 5개)</summary>
    public IReadOnlyList<string> RecentOutputDirectories => recentOutputDirectories;

    /// <summary>메뉴에 보일 최근 폴더: 지금 폴더와, 아직 있는 폴더만(지워졌거나 빠진 USB 등은 뺀다).</summary>
    public IReadOnlyList<string> AvailableRecentOutputDirectories =>
        recentOutputDirectories.Where(d => SameDirectory(d, outputDirectory) || Directory.Exists(d)).ToList();

    /// <summary>빠른 추출 전역 단축키(기본 Ctrl+Alt+Y)</summary>
    public HotKey QuickExtractHotKey
    {
        get => HotKey.Parse(data.QuickExtractHotKey) ?? HotKey.Default;
        set => Change(() => data.QuickExtractHotKey = value.Serialize(), QuickExtractHotKey != value && value.IsValid, nameof(QuickExtractHotKey));
    }

    /// <summary>창을 닫아도 트레이에 남아 단축키가 동작한다(기본 켬).</summary>
    public bool KeepRunningInTray
    {
        get => data.KeepRunningInTray ?? true;
        set => Change(() => data.KeepRunningInTray = value, KeepRunningInTray != value, nameof(KeepRunningInTray));
    }

    /// <summary>"트레이에서 계속 실행 중" 안내를 이미 보였는지(처음 한 번만 알린다)</summary>
    public bool TrayNoticeShown
    {
        get => data.TrayNoticeShown;
        set => Change(() => data.TrayNoticeShown = value, TrayNoticeShown != value, nameof(TrayNoticeShown));
    }

    public MediaKind MediaKind
    {
        get => data.MediaKind ?? MediaKind.Audio;
        set => Change(() => data.MediaKind = value, MediaKind != value, nameof(MediaKind));
    }

    public AudioFormatKind AudioFormatKind
    {
        get => data.AudioFormat ?? AudioFormatKind.Mp3;
        set => Change(() => data.AudioFormat = value, AudioFormatKind != value, nameof(AudioFormatKind));
    }

    /// <summary>MP3를 고를 때 쓸 음질. WAV·FLAC을 골랐다가 MP3로 돌아와도 유지한다.</summary>
    public Mp3Bitrate Mp3Bitrate
    {
        get => data.Mp3Bitrate is { } b && Enum.IsDefined((Mp3Bitrate)b) ? (Mp3Bitrate)b : Mp3Bitrate.Kbps320;
        set => Change(() => data.Mp3Bitrate = (int)value, Mp3Bitrate != value, nameof(Mp3Bitrate));
    }

    public VideoFormat VideoFormat
    {
        get => data.VideoFormat ?? VideoFormat.Mp4;
        set => Change(() => data.VideoFormat = value, VideoFormat != value, nameof(VideoFormat));
    }

    /// <summary>지금 고른 영상 포맷의 해상도(포맷마다 따로 기억한다). 포맷에 없는 해상도는 가장 가까운 아래 해상도로 맞춘다.</summary>
    public VideoResolution VideoResolution
    {
        get
        {
            var stored = VideoFormat == VideoFormat.Mp4 ? data.Mp4Resolution : data.BestResolution;
            return stored is { } r && Enum.IsDefined((VideoResolution)r)
                ? VideoFormat.SupportedResolution((VideoResolution)r)
                : VideoFormat.DefaultResolution();
        }
        set
        {
            var supported = (int)VideoFormat.SupportedResolution(value);
            Change(() =>
            {
                if (VideoFormat == VideoFormat.Mp4) data.Mp4Resolution = supported; else data.BestResolution = supported;
            }, (int)VideoResolution != supported, nameof(VideoResolution));
        }
    }

    /// <summary>동의한 이용 고지 버전. 0이면 아직 동의하지 않았다.</summary>
    public int AcceptedNoticeVersion
    {
        get => data.AcceptedNoticeVersion;
        set => Change(() => data.AcceptedNoticeVersion = value, AcceptedNoticeVersion != value, nameof(AcceptedNoticeVersion));
    }

    /// <summary>종류와 관계없이 지금 고른 오디오 포맷.</summary>
    public OutputFormat AudioFormat => AudioFormatKind switch
    {
        AudioFormatKind.Wav => new OutputFormat.Wav(),
        AudioFormatKind.Flac => new OutputFormat.Flac(),
        _ => new OutputFormat.Mp3(Mp3Bitrate),
    };

    /// <summary>선택한 포맷.</summary>
    public OutputFormat Format => MediaKind == MediaKind.Audio ? AudioFormat : new OutputFormat.Video(VideoFormat, VideoResolution);

    public ExtractOptions ExtractOptions => new(Format, OutputDirectory);

    /// <summary>포맷을 한 번에 고른다(종류·MP3 음질·영상 해상도도 함께 바뀐다).</summary>
    public void Select(OutputFormat format)
    {
        switch (format)
        {
            case OutputFormat.Mp3 mp3: Mp3Bitrate = mp3.Bitrate; AudioFormatKind = AudioFormatKind.Mp3; break;
            case OutputFormat.Wav: AudioFormatKind = AudioFormatKind.Wav; break;
            case OutputFormat.Flac: AudioFormatKind = AudioFormatKind.Flac; break;
            case OutputFormat.Video v: VideoFormat = v.Format; VideoResolution = v.Resolution; break;
        }
        MediaKind = format.IsVideo ? MediaKind.Video : MediaKind.Audio;
    }

    private void Change(Action apply, bool changed, string name)
    {
        if (!changed) return;
        apply();
        Save();
        Notify(name);
        // 포맷에 따라 달라지는 값들
        Notify(nameof(VideoResolution));
        Notify(nameof(AudioFormat));
        Notify(nameof(Format));
    }

    private void Save()
    {
        data.OutputDirectory = outputDirectory;
        data.RecentOutputDirectories = [.. recentOutputDirectories];
        store.Save(data);
    }

    /// <summary>Windows 경로는 대소문자를 구분하지 않고, 끝의 구분자는 무시한다.</summary>
    public static bool SameDirectory(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(a), Path.TrimEndingDirectorySeparator(b), StringComparison.OrdinalIgnoreCase);

    /// <summary><paramref name="directory"/>를 맨 앞에 두고 같은 폴더는 한 번만, 최대 개수까지.</summary>
    private static List<string> Recents(string directory, IEnumerable<string> list)
    {
        var result = new List<string> { directory };
        foreach (var d in list)
        {
            if (result.Count >= MaxRecentOutputDirectories) break;
            if (!string.IsNullOrWhiteSpace(d) && !result.Any(r => SameDirectory(r, d))) result.Add(d);
        }
        return result;
    }
}
