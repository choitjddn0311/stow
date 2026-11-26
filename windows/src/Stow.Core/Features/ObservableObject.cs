using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Stow.Core.Features;

/// <summary>화면 바인딩용 변경 알림. 값이 바뀔 때만 알리고, 함께 바뀌는 계산 속성 이름도 알릴 수 있다.</summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null, params string[] alsoChanged)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Notify(name);
        foreach (var other in alsoChanged) Notify(other);
        return true;
    }

    protected void Notify([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
