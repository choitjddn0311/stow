using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Stow.Core.Features;
using Stow.Core.Models;

namespace Stow;

/// <summary>XAML x:Bind에서 쓰는 변환 함수.</summary>
public static class Ui
{
    public static ImageSource? Thumbnail(VideoMetadata? video) =>
        video?.ThumbnailUrl is { } url ? new BitmapImage(url) : null;

    public static bool HasText(string? text) => !string.IsNullOrEmpty(text);

    /// <summary>Segoe Fluent Icons 글리프: 대기·받는 중·완료·실패·취소</summary>
    public static string StatusGlyph(QueueStatus status) => status switch
    {
        QueueStatus.Running => "",
        QueueStatus.Completed => "",
        QueueStatus.Failed => "",
        QueueStatus.Cancelled => "",
        _ => "",
    };

    public static Brush StatusBrush(QueueStatus status) => (Brush)Application.Current.Resources[status switch
    {
        QueueStatus.Running => "AccentTextFillColorPrimaryBrush",
        QueueStatus.Completed => "SystemFillColorSuccessBrush",
        QueueStatus.Failed => "SystemFillColorCriticalBrush",
        _ => "TextFillColorSecondaryBrush",
    }];
}
