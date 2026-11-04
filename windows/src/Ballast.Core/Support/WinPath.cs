namespace Ballast.Core;

public static class WinPath
{
    public const char Separator = '\\';

    public static string Normalize(string path)
    {
        var p = path.Replace('/', Separator);
        while (p.Length > 3 && p.EndsWith(Separator)) p = p[..^1];
        return p;
    }

    public static string Join(string root, params string[] parts)
    {
        var result = Normalize(root);
        foreach (var part in parts)
        {
            var piece = part.Replace('/', Separator).Trim(Separator);
            if (piece.Length == 0) continue;
            result = result.EndsWith(Separator) ? result + piece : result + Separator + piece;
        }
        return result;
    }

    public static string Parent(string path)
    {
        var p = Normalize(path);
        var index = p.LastIndexOf(Separator);
        if (index <= 0) return p;
        return index == 2 && p[1] == ':' ? p[..3] : p[..index];
    }

    public static string Leaf(string path)
    {
        var p = Normalize(path);
        var index = p.LastIndexOf(Separator);
        return index < 0 ? p : p[(index + 1)..];
    }

    public static string[] Components(string path) =>
        Normalize(path).Split(Separator, StringSplitOptions.RemoveEmptyEntries);

    public static bool IsDriveRooted(string path)
    {
        var p = path.Replace('/', Separator);
        return p.Length >= 3 && char.IsAsciiLetter(p[0]) && p[1] == ':' && p[2] == Separator;
    }

    public static bool SameAs(string a, string b) =>
        string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    public static bool IsInside(string path, string root)
    {
        var p = Normalize(path);
        var r = Normalize(root);
        var prefix = r.EndsWith(Separator) ? r : r + Separator;
        return p.Length > prefix.Length && p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsSameOrInside(string path, string root) => SameAs(path, root) || IsInside(path, root);

    public static string[] RelativeComponents(string path, string root)
    {
        var p = Normalize(path);
        var r = Normalize(root);
        if (!IsInside(p, r)) return [];
        var start = r.EndsWith(Separator) ? r.Length : r.Length + 1;
        return p[start..].Split(Separator, StringSplitOptions.RemoveEmptyEntries);
    }
}
