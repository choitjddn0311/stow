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
    [InlineData("0.1.0", "0.1.0")]
    [InlineData("0.1.0+4938ae6c1f", "0.1.0")]
    [InlineData("0.2.0-beta.1+abc", "0.2.0-beta.1")]  // 프리릴리스 표시는 남긴다
    public void DisplayVersionDropsBuildMetadata(string informational, string expected)
    {
        Assert.Equal(expected, AppInfo.DisplayVersion(informational));
    }
}
