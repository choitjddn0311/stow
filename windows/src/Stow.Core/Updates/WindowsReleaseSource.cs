using System.Text.Json;
using System.Text.Json.Serialization;
using Velopack.Sources;

namespace Stow.Core.Updates;

/// <summary>
/// 앱 업데이트를 찾는 곳: 이 저장소의 GitHub 릴리스 중 Windows 릴리스(태그 <c>win-v…</c>)만.
/// 같은 저장소에 Mac 릴리스가 섞여 있고, 기본 GithubSource는 최근 릴리스 10개만 보므로
/// Mac 릴리스가 이어지면 Windows 업데이트를 못 찾는다. 그래서 100개까지 읽고 Windows 태그만 남긴다.
/// Windows 릴리스는 사전 공개(pre-release)로 올리므로 사전 공개도 포함한다.
/// </summary>
public sealed class WindowsReleaseSource(string repoUrl, IFileDownloader? downloader = null)
    : GithubSource(repoUrl, accessToken: null, prerelease: true, downloader)
{
    public const string RepositoryUrl = "https://github.com/choitjddn0311/stow";
    public const string TagPrefix = "win-v";

    protected override async Task<GithubRelease[]> GetReleases(bool includePrereleases)
    {
        var url = new Uri(GetApiBaseUrl(RepoUri), $"repos{RepoUri.AbsolutePath}/releases?per_page=100&page=1");
        var json = await Downloader.DownloadString(url.ToString(), GetRequestHeaders("application/vnd.github.v3+json")).ConfigureAwait(false);
        return Select(json, includePrereleases);
    }

    /// <summary>GitHub 릴리스 목록(JSON)에서 공개된 Windows 릴리스만 최신순으로.</summary>
    public static GithubRelease[] Select(string json, bool includePrereleases)
    {
        var releases = JsonSerializer.Deserialize<List<Release>>(json) ?? [];
        return releases
            .Where(r => r.TagName?.StartsWith(TagPrefix, StringComparison.Ordinal) == true && !r.Draft && (includePrereleases || !r.Prerelease))
            .OrderByDescending(r => r.PublishedAt)
            .Select(r => new GithubRelease
            {
                Name = r.Name,
                Prerelease = r.Prerelease,
                PublishedAt = r.PublishedAt,
                Assets = (r.Assets ?? []).Select(a => new GithubReleaseAsset
                {
                    Name = a.Name,
                    Url = a.Url,
                    BrowserDownloadUrl = a.BrowserDownloadUrl,
                    ContentType = a.ContentType,
                }).ToArray(),
            })
            .ToArray();
    }

    private sealed class Release
    {
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("published_at")] public DateTime? PublishedAt { get; set; }
        [JsonPropertyName("assets")] public List<Asset>? Assets { get; set; }
    }

    private sealed class Asset
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("url")] public string? Url { get; set; }
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
        [JsonPropertyName("content_type")] public string? ContentType { get; set; }
    }
}
