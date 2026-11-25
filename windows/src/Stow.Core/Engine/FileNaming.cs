using System.Globalization;
using System.Text;

namespace Stow.Core.Engine;

/// <summary>
/// 영상 제목으로 파일 이름을 만든다. Mac 앱의 규칙(경로 문자 치환, 공백 정리, 200바이트, 앞의 점·공백 제거, 비면 "오디오")에
/// Windows 규칙을 더한다:
/// - 쓸 수 없는 문자: <c>/ \ :</c>는 <c>-</c>(Mac과 같음), <c>" * ? &lt; &gt; |</c>는 모양이 같은 전각 문자(뜻이 남게)
/// - 끝의 점·공백 제거(Windows가 조용히 지워 다른 이름이 된다)
/// - 예약 이름(<c>CON</c>, <c>NUL</c>, <c>COM1</c> 등, 확장자가 붙어도)이면 뒤에 <c>_</c>
/// </summary>
public static class FileNaming
{
    /// <summary>UTF-8 기준 최대 길이(Mac과 같음). 파일 이름 한도에서 <c> (999).flac</c> 여유를 뺐다.</summary>
    public const int MaxBytes = 200;

    public const string Fallback = "오디오";

    /// <summary>Windows 장치 이름(확장자가 붙어도 파일로 쓸 수 없다). 위 첨자 숫자 형태도 포함.</summary>
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    public static string Sanitize(string title)
    {
        var mapped = new StringBuilder(title.Length);
        foreach (var rune in title.EnumerateRunes())
        {
            if (Rune.IsControl(rune))
            {
                mapped.Append(' ');
                continue;
            }
            mapped.Append(rune.Value switch
            {
                '/' or '\\' or ':' => "-",
                '"' => "＂",
                '*' => "＊",
                '?' => "？",
                '<' => "＜",
                '>' => "＞",
                '|' => "｜",
                _ => rune.ToString(),
            });
        }
        var name = string.Join(' ', mapped.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        // 문자(그래핌) 단위로 잘라 한글·이모지가 중간에서 끊기지 않게 한다.
        name = TruncateToBytes(name, MaxBytes);
        // 자른 뒤에 정리해야 끝 공백이 남지 않는다. 앞은 점·공백(숨김 파일처럼 보임), 끝은 점·공백(Windows가 지움).
        name = name.TrimStart('.', ' ').TrimEnd('.', ' ');
        if (name.Length == 0) return Fallback;
        var stem = name.Split('.')[0].TrimEnd(' ');
        return ReservedNames.Contains(stem) ? stem + "_" + name[stem.Length..] : name;
    }

    /// <summary>UTF-8로 <paramref name="maxBytes"/> 이하가 될 때까지 끝에서 문자(그래핌)를 하나씩 뺀다.</summary>
    public static string TruncateToBytes(string text, int maxBytes) =>
        Truncate(text, maxBytes, Encoding.UTF8.GetByteCount);

    /// <summary>UTF-16 길이(Windows 경로 길이 단위)로 <paramref name="maxChars"/> 이하가 될 때까지 끝에서 문자(그래핌)를 뺀다.</summary>
    public static string TruncateToChars(string text, int maxChars) =>
        Truncate(text, maxChars, s => s.Length);

    private static string Truncate(string text, int limit, Func<string, int> measure)
    {
        if (measure(text) <= limit) return text;
        var elements = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) elements.Add((string)enumerator.Current);
        var size = measure(text);
        while (elements.Count > 0 && size > limit)
        {
            size -= measure(elements[^1]);
            elements.RemoveAt(elements.Count - 1);
        }
        return string.Concat(elements);
    }
}
