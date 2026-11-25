using Stow.Core.Engine;
using Stow.Core.Models;

namespace Stow.Core.Tests;

public class YouTubeUrlTests
{
    [Theory]
    [InlineData("https://www.youtube.com/watch?v=abc123")]
    [InlineData("https://youtube.com/watch?v=abc123&list=PL1")]
    [InlineData("http://m.youtube.com/watch?v=abc123")]
    [InlineData("https://music.youtube.com/watch?v=abc123")]
    [InlineData("https://youtu.be/abc123")]
    [InlineData("youtu.be/abc123")]
    [InlineData("  https://www.youtube.com/shorts/abc123\n")]
    [InlineData("https://WWW.YOUTUBE.COM/watch?v=abc123")]
    [InlineData("youtube.com/watch?v=abc123&redirect=https://x")]  // 쿼리 안의 "://"는 스킴이 아니다
    [InlineData("https://youtu.be/playlist")]
    public void AcceptsYouTubeUrls(string input)
    {
        var url = YouTubeUrl.Parse(input);
        Assert.Contains(url.Scheme, new[] { "https", "http" });
    }

    [Theory]
    [InlineData("")]
    [InlineData("abc")]
    [InlineData("https://www.youtube.com/")]
    [InlineData("https://example.com/watch?v=abc123")]
    [InlineData("https://notyoutube.com/watch?v=abc123")]
    [InlineData("https://youtube.com.evil.com/watch?v=abc123")]
    [InlineData("ftp://youtube.com/watch?v=abc123")]
    [InlineData("file:///Users/me/youtube.com/a")]
    public void RejectsOtherInput(string input)
    {
        Assert.Equal(EngineErrorKind.InvalidUrl, Assert.Throws<EngineException>(() => YouTubeUrl.Parse(input)).Kind);
    }

    [Fact]
    public void AcceptsPlaylistUrl()
    {
        Assert.Equal("/playlist", YouTubeUrl.Parse("https://www.youtube.com/playlist?list=PL123").AbsolutePath);
    }

    [Theory]
    [InlineData("https://www.youtube.com/@channel")]
    [InlineData("https://www.youtube.com/@channel/videos")]
    [InlineData("https://www.youtube.com/channel/UC123")]
    [InlineData("https://www.youtube.com/c/name")]
    [InlineData("https://www.youtube.com/user/name")]
    [InlineData("https://www.youtube.com/Channel/UC123")]  // 대소문자 무관
    public void RejectsChannelPages(string input)
    {
        Assert.Equal(EngineErrorKind.ChannelNotSupported, Assert.Throws<EngineException>(() => YouTubeUrl.Parse(input)).Kind);
    }
}

public class MediaTests
{
    [Fact]
    public void ParsesVideo()
    {
        const string json = """
            {"id": "abc123", "title": "제목: 테스트", "duration": 212.5, "thumbnail": "https://i.ytimg.com/vi/abc123/maxresdefault.jpg",
             "uploader": "채널", "webpage_url": "https://www.youtube.com/watch?v=abc123", "live_status": "not_live",
             "formats": [{"format_id": "251"}], "_type": "video"}
            """;
        var video = Assert.IsType<FetchedMedia.OfVideo>(FetchedMedia.Parse(json)).Metadata;
        Assert.Equal(new VideoMetadata("abc123", "제목: 테스트", 212.5, new Uri("https://i.ytimg.com/vi/abc123/maxresdefault.jpg"),
            "채널", new Uri("https://www.youtube.com/watch?v=abc123"), "not_live"), video);
    }

    [Fact]
    public void ToleratesMissingOptionalFields()
    {
        var video = Assert.IsType<FetchedMedia.OfVideo>(FetchedMedia.Parse("""{"id": "x", "channel": "c", "thumbnail": "not a url"}""")).Metadata;
        Assert.Equal("x", video.Title);
        Assert.Null(video.Duration);
        Assert.Equal("c", video.Uploader);
        Assert.Null(video.ThumbnailUrl);
    }

    [Fact]
    public void ParsesPlaylistLeniently()
    {
        const string json = """
            {"id": "PL1", "title": "내 목록", "_type": "playlist", "entries": [
              {"_type": "url", "id": "dQw4w9WgXcQ", "title": "첫 곡", "duration": 212.0, "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
              {"_type": "url", "id": "abc_DEF-123", "title": "[Private video]", "duration": null},
              {"_type": "url", "title": "ID 없음"},
              {"_type": "url", "id": "../evil", "title": "이상한 ID"},
              {"_type": "url", "id": "zzz"},
              {"_type": "url", "id": "dQw4w9WgXcQ", "title": "중복"},
              {"_type": "url", "ie_key": "YoutubeTab", "id": "PLxxxxxxxxx", "title": "하위 재생목록"},
              {"_type": "playlist", "id": "UCxxxxxxxxx", "title": "채널 탭"},
              {"_type": "url", "ie_key": "Youtube", "id": "zzzzzzzzzzz"}
            ], "playlist_count": 900}
            """;
        var playlist = Assert.IsType<FetchedMedia.OfPlaylist>(FetchedMedia.Parse(json)).Playlist;
        Assert.Equal("내 목록", playlist.Title);
        Assert.Equal(["dQw4w9WgXcQ", "abc_DEF-123", "zzzzzzzzzzz"], playlist.Entries.Select(e => e.Id));
        Assert.Equal("첫 곡", playlist.Entries[0].Title);
        Assert.Equal(212, playlist.Entries[0].Duration);
        Assert.Equal(new Uri("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), playlist.Entries[0].Url);
        Assert.True(playlist.Entries[1].IsUnavailable);
        Assert.False(playlist.Entries[0].IsUnavailable);
        Assert.Equal("제목 없음", playlist.Entries[2].Title);
        Assert.Equal(900, playlist.TotalCount);
        Assert.True(playlist.IsTruncated);
    }

    [Fact]
    public void RejectsUnknownTypeAndBrokenJson()
    {
        Assert.Equal(EngineErrorKind.UnsupportedUrl,
            Assert.Throws<EngineException>(() => FetchedMedia.Parse("""{"id": "x", "_type": "multi_video"}""")).Kind);
        Assert.Equal(EngineErrorKind.MetadataUnreadable, Assert.Throws<EngineException>(() => FetchedMedia.Parse("{not json")).Kind);
    }
}

public class OutputFormatTests
{
    [Fact]
    public void FileExtensions()
    {
        Assert.Equal("mp3", new OutputFormat.Mp3(Mp3Bitrate.Kbps320).FileExtension);
        Assert.Equal("flac", new OutputFormat.Flac().FileExtension);
        Assert.Equal("mp4", new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P1080).FileExtension);
        Assert.Null(new OutputFormat.Video(VideoFormat.Best, VideoResolution.Best).FileExtension);  // 결과 파일 확장자를 쓴다
        Assert.True(new OutputFormat.Video(VideoFormat.Mp4, VideoResolution.P720).IsVideo);
        Assert.False(new OutputFormat.Wav().IsVideo);
    }

    [Theory]
    [InlineData(VideoFormat.Mp4, VideoResolution.P2160, VideoResolution.P1080)]
    [InlineData(VideoFormat.Mp4, VideoResolution.Best, VideoResolution.P1080)]
    [InlineData(VideoFormat.Mp4, VideoResolution.P720, VideoResolution.P720)]
    [InlineData(VideoFormat.Best, VideoResolution.P1440, VideoResolution.P1440)]
    public void SupportedResolution(VideoFormat format, VideoResolution requested, VideoResolution expected)
    {
        Assert.Equal(expected, format.SupportedResolution(requested));
    }
}
