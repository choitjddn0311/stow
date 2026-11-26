namespace Stow.Core.Models;

/// <summary>전역 단축키의 보조 키. 값은 Win32 <c>RegisterHotKey</c>의 MOD_ 값과 같다.</summary>
[Flags]
public enum HotKeyModifiers
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Windows = 8,
}

/// <summary>
/// 빠른 추출을 여는 전역 단축키(보조 키 + 가상 키 코드). 기본값 Ctrl+Alt+Y(사용자 결정 2026-11-26).
/// Shift만으로는 글자 입력과 겹치므로 Ctrl·Alt·Win 중 하나는 있어야 한다.
/// </summary>
public readonly record struct HotKey(HotKeyModifiers Modifiers, int Key)
{
    public static HotKey Default => new(HotKeyModifiers.Control | HotKeyModifiers.Alt, 'Y');

    public bool IsValid =>
        KeyName(Key) is not null
        && (Modifiers & (HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Windows)) != 0
        && (Modifiers & ~(HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift | HotKeyModifiers.Windows)) == 0;

    /// <summary>예: "Ctrl+Alt+Y". Windows 표기 순서(Win, Ctrl, Alt, Shift, 키).</summary>
    public override string ToString() => string.Join("+", Parts);

    /// <summary>키 하나씩: ["Ctrl", "Alt", "Y"](설정 화면의 키 모양 표시용)</summary>
    public IReadOnlyList<string> Parts
    {
        get
        {
            var parts = new List<string>();
            if (Modifiers.HasFlag(HotKeyModifiers.Windows)) parts.Add("Win");
            if (Modifiers.HasFlag(HotKeyModifiers.Control)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(HotKeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(HotKeyModifiers.Shift)) parts.Add("Shift");
            parts.Add(KeyName(Key) ?? $"0x{Key:X2}");
            return parts;
        }
    }

    /// <summary>설정 파일에 저장하는 모양: "보조키값:키코드" (예: "3:89")</summary>
    public string Serialize() => $"{(int)Modifiers}:{Key}";

    public static HotKey? Parse(string? text)
    {
        if (text?.Split(':') is not [var m, var k]) return null;
        if (!int.TryParse(m, out var modifiers) || !int.TryParse(k, out var key)) return null;
        var hotKey = new HotKey((HotKeyModifiers)modifiers, key);
        return hotKey.IsValid ? hotKey : null;
    }

    /// <summary>단축키로 쓸 수 있는 키의 이름. 쓸 수 없는 키(보조 키 자체, Enter·Esc 등)는 null.</summary>
    public static string? KeyName(int key) => key switch
    {
        >= 'A' and <= 'Z' => ((char)key).ToString(),
        >= '0' and <= '9' => ((char)key).ToString(),
        >= 0x70 and <= 0x87 => $"F{key - 0x6F}",
        0x20 => "Space",
        0x2D => "Insert",
        0x2E => "Delete",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "PageUp",
        0x22 => "PageDown",
        _ => null,
    };
}
