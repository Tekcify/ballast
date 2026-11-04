using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;

namespace Ballast.UI;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class Command(Action<object?> run, Func<object?, bool>? canRun = null) : ICommand
{
    public Command(Action run) : this(_ => run()) { }

    public Command(Action run, Func<object?, bool> canRun) : this(_ => run(), canRun) { }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => canRun?.Invoke(parameter) ?? true;

    public void Execute(object? parameter) => run(parameter);
}

public static class CollectionSync
{
    public static void Sync<TVm, TModel>(
        ObservableCollection<TVm> target,
        IReadOnlyList<TModel> models,
        Func<TModel, string> modelKey,
        Func<TVm, string> vmKey,
        Func<TModel, TVm> create,
        Action<TVm, TModel> update)
    {
        var wanted = models.Select(modelKey).ToHashSet(StringComparer.Ordinal);
        for (var i = target.Count - 1; i >= 0; i--)
        {
            if (!wanted.Contains(vmKey(target[i]))) target.RemoveAt(i);
        }

        for (var index = 0; index < models.Count; index++)
        {
            var model = models[index];
            var key = modelKey(model);
            var existing = -1;
            for (var j = index; j < target.Count; j++)
            {
                if (vmKey(target[j]) == key)
                {
                    existing = j;
                    break;
                }
            }

            if (existing < 0)
            {
                target.Insert(index, create(model));
            }
            else
            {
                if (existing != index) target.Move(existing, index);
                update(target[index], model);
            }
        }
    }
}

public sealed class InverseVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class Visible : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        bool b => b ? Visibility.Visible : Visibility.Collapsed,
        string s => string.IsNullOrEmpty(s) ? Visibility.Collapsed : Visibility.Visible,
        int n => n > 0 ? Visibility.Visible : Visibility.Collapsed,
        null => Visibility.Collapsed,
        _ => Visibility.Visible,
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class EqualsParameter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value?.ToString() == parameter?.ToString()
        || (value is double d && double.TryParse(parameter?.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p) && Math.Abs(d - p) < 0.001);

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not true) return Binding.DoNothing;
        var text = parameter?.ToString() ?? "";
        if (targetType == typeof(double)) return double.Parse(text, CultureInfo.InvariantCulture);
        if (targetType == typeof(bool)) return bool.Parse(text);
        return text;
    }
}

public sealed class Not : IValueConverter
{
    public static readonly Not Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;
}
