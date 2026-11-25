namespace Stow.Core.Features;

/// <summary>첫 실행 이용 고지(Mac 앱과 같은 문구·버전). 문구를 바꾸면 <see cref="Version"/>을 올려 다시 보여 준다.</summary>
public static class UsageNotice
{
    public const int Version = 2;
    public const string Title = "Stow 이용 안내";
    public static readonly IReadOnlyList<string> Paragraphs =
    [
        "Stow는 본인이 저작권을 가지고 있거나 사용 허락을 받은 영상과 그 오디오를 내려받는 도구입니다.",
        "다른 사람의 저작물을 허락 없이 내려받거나 배포하면 저작권법이나 YouTube 이용약관을 위반할 수 있으며, 그에 따른 책임은 사용자에게 있습니다.",
        "Stow 개발자는 사용자가 Stow로 내려받은 콘텐츠와 그 사용에 대해 어떠한 법적 책임도 지지 않습니다.",
    ];
    public const string AcceptButton = "동의하고 시작";
    public const string QuitButton = "종료";
}
