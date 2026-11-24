using Stow.Core;

namespace Stow.Core.Tests;

public class AppInfoTests
{
    [Fact]
    public void DataDirectoryIsUnderLocalAppData()
    {
        var root = Path.Combine("C:", "Users", "me", "AppData", "Local");
        Assert.Equal(Path.Combine(root, "Stow"), AppInfo.DataDirectory(root));
    }

    [Theory]
    [InlineData(0, 1, 0, 0, "0.1.0")]
    [InlineData(1, 2, 3, 45, "1.2.3")]
    public void DisplayVersionDropsRevision(int major, int minor, int build, int revision, string expected)
    {
        Assert.Equal(expected, AppInfo.DisplayVersion(new Version(major, minor, build, revision)));
    }

    [Fact]
    public void DisplayVersionWithoutBuildNumber()
    {
        Assert.Equal("0.1.0", AppInfo.DisplayVersion(new Version(0, 1)));
    }
}
