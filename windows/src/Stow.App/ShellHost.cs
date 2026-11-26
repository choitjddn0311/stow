using System.Runtime.InteropServices;
using Stow.Core.Features;
using Stow.Core.Models;

namespace Stow;

/// <summary>
/// 화면에 보이지 않는 Win32 창 하나로 전역 단축키(<c>RegisterHotKey</c>)와 트레이 아이콘(<c>Shell_NotifyIcon</c>)을 맡는다.
/// WinUI에는 둘 다 없어서 직접 만든다. 화면 스레드에서 만들고 부른다(그 스레드의 메시지 루프가 메시지를 전달한다).
/// </summary>
internal sealed unsafe partial class ShellHost : IDisposable
{
    public enum TrayCommand { QuickExtract = 1, OpenMainWindow, CheckUpdates, Quit }

    private const int HotKeyId = 1;
    private const uint TrayIconId = 1;
    private const uint WM_HOTKEY = 0x0312;
    private const uint WM_APP_TRAY = 0x8000 + 1;
    private const uint WM_CONTEXTMENU = 0x007B;
    private const uint NIN_SELECT = 0x0400;
    private const uint NIN_KEYSELECT = 0x0401;
    private const uint MOD_NOREPEAT = 0x4000;

    private static ShellHost? current;
    private readonly IntPtr hwnd;
    private readonly uint taskbarCreatedMessage;
    private readonly IntPtr icon;
    private bool trayAdded;
    /// <summary>트레이 아이콘을 보이기로 했는지(처음 등록이 실패해도 작업 표시줄이 준비되면 다시 넣는다)</summary>
    private bool trayWanted;
    private bool hotKeyRegistered;
    private string toolTip = "Stow";
    private string quickExtractMenuText = "빠른 추출";

    /// <summary>등록한 단축키를 눌렀다.</summary>
    public event Action? HotKeyPressed;
    /// <summary>트레이 아이콘 왼쪽 클릭(또는 키보드로 선택)</summary>
    public event Action? TrayClicked;
    /// <summary>트레이 메뉴에서 고른 항목</summary>
    public event Action<TrayCommand>? TrayCommandChosen;

    public ShellHost(string iconPath)
    {
        current = this;
        var instance = GetModuleHandleW(null);
        delegate* unmanaged<IntPtr, uint, IntPtr, IntPtr, IntPtr> procedure = &WndProc;
        fixed (char* className = "StowShellHost")
        {
            var wc = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (IntPtr)(void*)procedure,
                hInstance = instance,
                lpszClassName = className,
            };
            RegisterClassExW(&wc);
            // 화면에 보이지 않는 팝업 창(메시지 전용 창은 작업 표시줄 재시작 알림을 받지 못하고 메뉴를 띄울 수 없다)
            hwnd = CreateWindowExW(0x00000080 /* WS_EX_TOOLWINDOW */, className, className, 0x80000000 /* WS_POPUP */,
                0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        }
        taskbarCreatedMessage = RegisterWindowMessageW("TaskbarCreated");
        var size = GetSystemMetrics(49 /* SM_CXSMICON */);
        icon = LoadImageW(IntPtr.Zero, iconPath, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */);
        AllowDarkMenus();
    }

    // MARK: 전역 단축키

    /// <summary>단축키를 (다시) 등록한다. 다른 앱이 이미 쓰고 있으면 false.</summary>
    public bool RegisterHotKey(HotKey hotKey)
    {
        UnregisterHotKey();
        hotKeyRegistered = RegisterHotKey(hwnd, HotKeyId, (uint)hotKey.Modifiers | MOD_NOREPEAT, (uint)hotKey.Key);
        return hotKeyRegistered;
    }

    public void UnregisterHotKey()
    {
        if (!hotKeyRegistered) return;
        UnregisterHotKey(hwnd, HotKeyId);
        hotKeyRegistered = false;
    }

    // MARK: 트레이

    public void ShowTrayIcon()
    {
        trayWanted = true;
        var data = NewIconData(0x1 | 0x2 | 0x4 | 0x80 /* NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP */);
        trayAdded = Shell_NotifyIconW(0 /* NIM_ADD */, &data);
        if (!trayAdded) return;
        data.uVersion = 4;  // NOTIFYICON_VERSION_4: 클릭 위치와 키보드 선택을 알려 준다
        Shell_NotifyIconW(4 /* NIM_SETVERSION */, &data);
    }

    /// <summary>트레이 아이콘에 마우스를 올렸을 때의 글자(예: "Stow · 추출 중 1 · 대기 2")</summary>
    public void SetToolTip(string text)
    {
        if (text == toolTip) return;
        toolTip = text;
        if (!trayAdded) return;
        var data = NewIconData(0x4 | 0x80 /* NIF_TIP | NIF_SHOWTIP */);
        Shell_NotifyIconW(1 /* NIM_MODIFY */, &data);
    }

    /// <summary>트레이 메뉴의 빠른 추출 항목 글자(단축키 표시)</summary>
    public void SetQuickExtractShortcutText(string? shortcut) =>
        quickExtractMenuText = shortcut is null ? "빠른 추출" : $"빠른 추출\t{shortcut}";

    private NOTIFYICONDATAW NewIconData(uint flags)
    {
        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = hwnd,
            uID = TrayIconId,
            uFlags = flags,
            uCallbackMessage = WM_APP_TRAY,
            hIcon = icon,
        };
        var tip = toolTip.Length > 127 ? toolTip[..127] : toolTip;
        tip.AsSpan().CopyTo(new Span<char>(data.szTip, 128));
        return data;
    }

    private void ShowTrayMenu(int x, int y)
    {
        var menu = CreatePopupMenu();
        AppendMenuW(menu, 0 /* MF_STRING */, (nuint)TrayCommand.QuickExtract, quickExtractMenuText);
        AppendMenuW(menu, 0, (nuint)TrayCommand.OpenMainWindow, "Stow 열기");
        AppendMenuW(menu, 0x800 /* MF_SEPARATOR */, 0, null);
        AppendMenuW(menu, 0, (nuint)TrayCommand.CheckUpdates, "업데이트 확인");
        AppendMenuW(menu, 0, (nuint)TrayCommand.Quit, "종료");
        // 메뉴 바깥을 누르면 닫히게 하려면 먼저 앞으로 가져와야 한다(Win32 메뉴의 알려진 요구 사항).
        NativeMethods.SetForegroundWindow(hwnd);
        var command = TrackPopupMenuEx(menu, 0x0100 | 0x0080 | 0x0002 /* TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON */, x, y, hwnd, IntPtr.Zero);
        PostMessageW(hwnd, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);
        if (command != 0) TrayCommandChosen?.Invoke((TrayCommand)command);
    }

    // MARK: 메시지

    [UnmanagedCallersOnly]
    private static IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (current is { } host && host.hwnd == hwnd && host.Handle(message, wParam, lParam)) return IntPtr.Zero;
        }
        catch (Exception)
        {
            // 창 프로시저 밖으로 예외를 내보내면 프로세스가 끝난다.
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private bool Handle(uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == WM_HOTKEY && (int)wParam == HotKeyId)
        {
            HotKeyPressed?.Invoke();
            return true;
        }
        if (message == taskbarCreatedMessage && taskbarCreatedMessage != 0)
        {
            // 탐색기가 다시 시작되거나(Windows 시작 직후 실행으로) 처음 등록이 실패했으면 작업 표시줄이 준비된 지금 넣는다.
            if (trayWanted) ShowTrayIcon();
            return false;
        }
        if (message != WM_APP_TRAY) return false;
        switch ((uint)(lParam.ToInt64() & 0xFFFF))
        {
            // 버전 4에서는 왼쪽 클릭이 WM_LBUTTONUP 뒤에 NIN_SELECT로 한 번 더 오므로 NIN_SELECT만 쓴다.
            case NIN_SELECT or NIN_KEYSELECT:
                TrayClicked?.Invoke();
                break;
            case WM_CONTEXTMENU:
                var x = (short)(wParam.ToInt64() & 0xFFFF);
                var y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
                ShowTrayMenu(x, y);
                break;
        }
        return true;
    }

    /// <summary>다크 모드에서 트레이 메뉴도 어둡게(uxtheme의 이름 없는 함수, 없으면 그냥 밝은 메뉴).</summary>
    private static void AllowDarkMenus()
    {
        try
        {
            var uxtheme = NativeLibrary.Load("uxtheme.dll");
            var setPreferredAppMode = GetProcAddress(uxtheme, 135);
            var flushMenuThemes = GetProcAddress(uxtheme, 136);
            if (setPreferredAppMode == IntPtr.Zero || flushMenuThemes == IntPtr.Zero) return;
            ((delegate* unmanaged<int, int>)(void*)setPreferredAppMode)(1 /* AllowDark: 시스템 설정을 따른다 */);
            ((delegate* unmanaged<void>)(void*)flushMenuThemes)();
        }
        catch (Exception)
        {
        }
    }

    public void Dispose()
    {
        UnregisterHotKey();
        if (trayAdded)
        {
            var data = NewIconData(0);
            Shell_NotifyIconW(2 /* NIM_DELETE */, &data);
            trayAdded = false;
        }
        if (icon != IntPtr.Zero) DestroyIcon(icon);
        DestroyWindow(hwnd);
        if (current == this) current = null;
    }

    // MARK: Win32

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASSEXW
    {
        public uint cbSize, style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public char* lpszMenuName, lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        public fixed char szTip[128];
        public uint dwState, dwStateMask;
        public fixed char szInfo[256];
        public uint uVersion;
        public fixed char szInfoTitle[64];
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr GetModuleHandleW(string? name);
    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetProcAddress(IntPtr module, nint ordinal);
    [LibraryImport("user32.dll")]
    private static partial ushort RegisterClassExW(WNDCLASSEXW* wc);
    [LibraryImport("user32.dll")]
    private static partial IntPtr CreateWindowExW(uint exStyle, char* className, char* windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);
    [LibraryImport("user32.dll")]
    private static partial IntPtr DefWindowProcW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint RegisterWindowMessageW(string name);
    [LibraryImport("user32.dll", EntryPoint = "RegisterHotKey")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [LibraryImport("user32.dll", EntryPoint = "UnregisterHotKey")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(IntPtr hwnd, int id);
    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int index);
    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr LoadImageW(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyIcon(IntPtr icon);
    [LibraryImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool Shell_NotifyIconW(uint message, NOTIFYICONDATAW* data);
    [LibraryImport("user32.dll")]
    private static partial IntPtr CreatePopupMenu();
    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AppendMenuW(IntPtr menu, uint flags, nuint id, string? text);
    [LibraryImport("user32.dll")]
    private static partial int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyMenu(IntPtr menu);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}

/// <summary>Windows 클립보드(Win32: 어느 창이 앞에 있든 읽을 수 있다).</summary>
internal sealed partial class WindowsClipboard : IClipboardReader
{
    public uint SequenceNumber => GetClipboardSequenceNumber();

    public async Task<string?> ReadTextAsync()
    {
        // 다른 앱이 잠깐 클립보드를 열고 있을 수 있어 몇 번 다시 시도한다.
        for (var attempt = 0; attempt < 5; attempt++)
        {
            if (TryRead(out var text)) return text;
            await Task.Delay(20);
        }
        return null;
    }

    private static unsafe bool TryRead(out string? text)
    {
        text = null;
        if (!IsClipboardFormatAvailable(13 /* CF_UNICODETEXT */)) return true;
        if (!OpenClipboard(IntPtr.Zero)) return false;
        try
        {
            var handle = GetClipboardData(13);
            if (handle == IntPtr.Zero) return true;
            var pointer = GlobalLock(handle);
            if (pointer == IntPtr.Zero) return true;
            try
            {
                // 주소는 2048자까지만 받으므로 그보다 길면 주소가 아니다(앞부분만 잘라 주소로 보지 않게 통째로 버린다).
                const int limit = ClipboardUrl.MaxLength + 1;
                var size = (int)Math.Min((long)GlobalSize(handle) / 2, limit + 1);
                var span = new ReadOnlySpan<char>((void*)pointer, size);
                var end = span.IndexOf('\0');
                var content = end >= 0 ? span[..end] : span;
                text = content.Length > ClipboardUrl.MaxLength ? null : new string(content);
            }
            finally
            {
                GlobalUnlock(handle);
            }
            return true;
        }
        finally
        {
            CloseClipboard();
        }
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetClipboardSequenceNumber();
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsClipboardFormatAvailable(uint format);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(IntPtr owner);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();
    [LibraryImport("user32.dll")]
    private static partial IntPtr GetClipboardData(uint format);
    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GlobalLock(IntPtr handle);
    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalUnlock(IntPtr handle);
    [LibraryImport("kernel32.dll")]
    private static partial nuint GlobalSize(IntPtr handle);
}

/// <summary>Windows를 시작할 때 실행(현재 사용자의 Run 레지스트리 값).</summary>
internal static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Stow";
    /// <summary>시작할 때 창을 띄우지 않고 트레이에서 조용히 시작한다.</summary>
    public const string BackgroundArgument = "--background";

    public static bool IsEnabled
    {
        get
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } exe) key.SetValue(ValueName, $"\"{exe}\" {BackgroundArgument}");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    /// <summary>등록된 경로가 지금 실행 파일과 다르면(앱을 옮겼거나 휴대용 버전) 지금 경로로 고친다.</summary>
    public static void RefreshPathIfEnabled()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            if (key?.GetValue(ValueName) is string value && Environment.ProcessPath is { } exe
                && !value.StartsWith($"\"{exe}\"", StringComparison.OrdinalIgnoreCase))
            {
                SetEnabled(true);
            }
        }
        catch (Exception)
        {
        }
    }
}
