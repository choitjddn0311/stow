using Stow.Core.Engine;

namespace Stow.Core.Models;

/// <summary>사용자가 붙여 넣은 문자열이 유튜브 영상·재생목록 주소인지 확인한다. 세부 검증은 yt-dlp에 맡긴다.</summary>
public static class YouTubeUrl
{
    private static readonly string[] Hosts = ["youtube.com", "youtu.be"];
    /// <summary>채널·피드 페이지 경로(영상 수가 정해지지 않아 받지 않는다). 재생목록(<c>/playlist?list=</c>)은 받는다.</summary>
    private static readonly string[] ChannelPathPrefixes = ["/@", "/channel/", "/c/", "/user/", "/feed/"];

    /// <summary>
    /// 유튜브 주소면 정규화한 <see cref="Uri"/>를 돌려준다. 스킴이 없으면(<c>youtu.be/abc</c>) https로 본다.
    /// 유튜브가 아니면 <see cref="EngineErrorKind.InvalidUrl"/>, 채널 페이지면 <see cref="EngineErrorKind.ChannelNotSupported"/>.
    /// </summary>
    public static Uri Parse(string input)
    {
        var trimmed = input.Trim();
        // 스킴은 맨 앞에서만 찾는다(쿼리 안의 "https://"는 스킴이 아니다).
        var hasScheme = System.Text.RegularExpressions.Regex.IsMatch(trimmed, "^[A-Za-z][A-Za-z0-9+.-]*://");
        var candidate = hasScheme ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("https" or "http")
            || !IsYouTubeHost(uri.Host.ToLowerInvariant())
            || uri.AbsolutePath.Length <= 1)
        {
            throw new EngineException(EngineErrorKind.InvalidUrl);
        }
        var path = uri.AbsolutePath.ToLowerInvariant();
        if (!uri.Host.Equals("youtu.be", StringComparison.OrdinalIgnoreCase)
            && ChannelPathPrefixes.Any(prefix => path.StartsWith(prefix, StringComparison.Ordinal)))
        {
            throw new EngineException(EngineErrorKind.ChannelNotSupported);
        }
        return uri;
    }

    /// <summary><c>youtube.com</c>, <c>youtu.be</c>와 그 하위 도메인(www, m, music 등).</summary>
    private static bool IsYouTubeHost(string host) =>
        Hosts.Any(h => host == h || host.EndsWith("." + h, StringComparison.Ordinal));
}
