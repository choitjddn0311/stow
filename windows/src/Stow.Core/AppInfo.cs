namespace Stow.Core;

/// <summary>앱 이름·버전·데이터 폴더 같은 기본 정보.</summary>
public static class AppInfo
{
    public const string Name = "Stow";

    /// <summary>
    /// 설정·엔진 업데이트를 두는 폴더: <c>%LOCALAPPDATA%\Stow</c>.
    /// 설치 패키지(MSIX) 없이 실행하는 앱이라 <c>ApplicationData</c>를 쓸 수 없어 직접 정한다.
    /// </summary>
    public static string DataDirectory(string localAppData) => Path.Combine(localAppData, Name);

    /// <summary>화면에 보일 버전. 예: "0.1.0"(빌드 번호는 뺀다)</summary>
    public static string DisplayVersion(Version version) => $"{version.Major}.{version.Minor}.{Math.Max(version.Build, 0)}";
}
