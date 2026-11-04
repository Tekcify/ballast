namespace Ballast.Core;

public sealed class DeletionGuard
{
    private static readonly StringComparer Ci = StringComparer.OrdinalIgnoreCase;

    private static readonly HashSet<string> ProtectedTop = new(Ci)
    {
        "Documents", "Desktop", "Pictures", "Videos", "Music", "Favorites", "Contacts", "Links",
        "Saved Games", "Searches", "OneDrive", "AppData", "Dropbox",
        ".ssh", ".gnupg", ".aws", ".config", ".kube", ".docker",
        ".codex", ".claude", ".cursor", ".agents", ".openai",
    };

    private static readonly HashSet<string> ForbiddenComponents = new(Ci)
    {
        ".git", ".ssh", ".gnupg", ".aws", ".kube",
        ".codex", ".claude", ".cursor", ".agents", ".openai",
    };

    private readonly string _home;
    private readonly HashSet<string> _exactRoots = new(Ci);
    private readonly HashSet<string> _childBases = new(Ci);
    private readonly List<string> _searchSuffixes = [];
    private readonly Func<string, bool> _isLink;

    public DeletionGuard(string home, IEnumerable<CleanupTarget> targets, Func<string, bool> isLink)
    {
        _home = WinPath.Normalize(home);
        _isLink = isLink;

        foreach (var target in targets.Where(t => t.Risk.IsSelectable()))
        {
            switch (target.Shape)
            {
                case ShapeKind.Directory:
                case ShapeKind.Contents:
                    _exactRoots.Add(WinPath.Normalize(target.Path));
                    break;
                case ShapeKind.Children:
                    _childBases.Add(WinPath.Normalize(target.Path));
                    break;
                case ShapeKind.Search:
                    foreach (var name in target.SearchNames)
                    {
                        if (target.SearchSubpaths.Count == 0)
                        {
                            _searchSuffixes.Add("\\" + name);
                        }
                        else
                        {
                            foreach (var sub in target.SearchSubpaths)
                            {
                                _searchSuffixes.Add(WinPath.Join("\\" + name, sub));
                            }
                        }
                    }
                    break;
            }
        }
    }

    public string? Rejection(string rawPath)
    {
        if (string.IsNullOrWhiteSpace(rawPath)) return "empty path";
        if (rawPath.StartsWith(@"\\", StringComparison.Ordinal) || rawPath.StartsWith("//", StringComparison.Ordinal))
            return "network or device paths are never cleaned";
        if (!WinPath.IsDriveRooted(rawPath)) return "not an absolute path";

        var path = WinPath.Normalize(rawPath);
        var parts = WinPath.Components(path);
        if (parts.Any(p => p is "." or "..")) return "contains a parent reference";
        if (parts.Skip(1).Any(p => p.Contains(':'))) return "contains a stream or drive marker";
        if (parts.Any(p => p.EndsWith('.') || p.EndsWith(' '))) return "has a name Windows would rewrite";

        if (WinPath.SameAs(path, _home)) return "the home folder itself";
        if (!WinPath.IsInside(path, _home)) return "outside the home folder";

        var relative = WinPath.RelativeComponents(path, _home);
        if (relative.Length < 2) return "too close to the top of the home folder";

        var first = relative[0];
        var protectedTop = ProtectedTop.Contains(first) || first.StartsWith("OneDrive", StringComparison.OrdinalIgnoreCase);
        if (protectedTop && !(first.Equals("AppData", StringComparison.OrdinalIgnoreCase) && IsKnownTarget(path)))
            return $"inside {first}, which Ballast never deletes from";

        var forbidden = relative.FirstOrDefault(ForbiddenComponents.Contains);
        if (forbidden is not null) return $"inside {forbidden}, which Ballast never deletes from";

        if (!IsKnownTarget(path)) return "not a path Ballast knows how to clean";

        var cursor = path;
        while (WinPath.IsInside(cursor, _home))
        {
            if (_isLink(cursor)) return "passes through a link or junction";
            cursor = WinPath.Parent(cursor);
        }
        return null;
    }

    private bool IsKnownTarget(string path)
    {
        if (_exactRoots.Contains(path)) return true;
        var parent = WinPath.Parent(path);
        if (_childBases.Contains(parent)) return true;
        if (_searchSuffixes.Any(s => path.EndsWith(s, StringComparison.OrdinalIgnoreCase))) return true;
        return _exactRoots.Contains(parent);
    }
}
