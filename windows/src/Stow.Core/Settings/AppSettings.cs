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
}

public interface ISettingsStore
{
    SettingsData? Load();
    void Save(SettingsData data);
}

/// <summary><c>%LOCALAPPDATA%\Stow\settings.json</c>에 저장한다. 임시 파일에 쓴 뒤 바꿔 넣어 반쯤 쓴 파일이 남지 않게 한다.</summary>
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

/// <summary>테스트용(디스크에 쓰지 않음). 직렬화 왕복으로 실제 저장처럼 값을 복사한다.</summary>
public sealed class MemorySettingsStore : ISettingsStore
{
    private string? json;
    public SettingsData? Load() => json is null ? null : JsonSerializer.Deserialize<SettingsData>(json);
    public void Save(SettingsData data) => json = JsonSerializer.Serialize(data);
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
    }

    /// <summary>기본 저장 위치: 사용자 폴더의 "다운로드".</summary>
    public static string DefaultOutputDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    private string outputDirectory;
    public string OutputDirectory
    {
        get => outputDirectory;
        set
        {
            if (Set(ref outputDirectory, value)) { data.OutputDirectory = value; Save(); }
        }
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
        store.Save(data);
    }
}
