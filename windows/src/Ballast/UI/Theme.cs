using System.Windows;
using Microsoft.Win32;

namespace Ballast.UI;

public static class Theme
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static bool IsDark => ReadFlag("AppsUseLightTheme") == 0;

    public static bool TaskbarIsLight => ReadFlag("SystemUsesLightTheme") == 1;

    public static void Apply(Application app)
    {
        var file = IsDark ? "Dark.xaml" : "Light.xaml";
        var source = new Uri("pack://application:,,,/Ballast;component/UI/Themes/" + file, UriKind.Absolute);
        var merged = app.Resources.MergedDictionaries;
        if (merged.Count > 0 && merged[0].Source?.OriginalString.EndsWith("/" + file, StringComparison.OrdinalIgnoreCase) == true) return;
        var dictionary = new ResourceDictionary { Source = source };
        if (merged.Count > 0) merged[0] = dictionary;
        else merged.Add(dictionary);
    }

    private static int ReadFlag(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue(name) is int value ? value : 1;
        }
        catch (System.Security.SecurityException)
        {
            return 1;
        }
    }
}
