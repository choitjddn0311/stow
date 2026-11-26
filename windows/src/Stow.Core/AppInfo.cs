namespace Stow.Core;

/// <summary>앱 이름·버전·데이터 폴더 같은 기본 정보.</summary>
public static class AppInfo
{
    public const string Name = "Stow";

    /// <summary>
    /// 설정을 두는 폴더: <c>%APPDATA%\Stow</c>(호출하는 쪽이 넘기는 기준 폴더 아래).
    /// 설치 패키지(MSIX) 없이 실행하는 앱이라 <c>ApplicationData</c>를 쓸 수 없어 직접 정한다.
    /// <c>%LOCALAPPDATA%\Stow</c>는 설치 도구(Velopack)가 앱을 설치하고 제거·복구할 때 통째로 지우는 곳이라 쓰지 않는다.
    /// </summary>
    public static string DataDirectory(string appData) => Path.Combine(appData, Name);

    /// <summary>
    /// 화면에 보일 버전. 프로젝트의 &lt;Version&gt; 그대로인 InformationalVersion에서 빌드 메타데이터(<c>+커밋</c>)만 뗀다.
    /// 예: "0.2.0-beta.1+abc123" → "0.2.0-beta.1"
    /// </summary>
    public static string DisplayVersion(string informationalVersion)
    {
        var plus = informationalVersion.IndexOf('+');
        return plus >= 0 ? informationalVersion[..plus] : informationalVersion;
    }
}
