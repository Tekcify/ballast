namespace Ballast.Core;

public sealed record KnownFolders(string Home, string LocalAppData, string RoamingAppData, string Temp)
{
    public static KnownFolders ForHome(string home) => new(
        home,
        WinPath.Join(home, "AppData", "Local"),
        WinPath.Join(home, "AppData", "Roaming"),
        WinPath.Join(home, "AppData", "Local", "Temp"));
}

public enum ShapeKind
{
    Directory,
    Children,
    Search,
    Contents,
    RecycleBin,
}

public sealed record CleanupTarget
{
    public required string Category { get; init; }
    public required string Title { get; init; }
    public required ShapeKind Shape { get; init; }
    public string Path { get; init; } = "";
    public IReadOnlyList<string> SearchNames { get; init; } = [];
    public int MaxDepth { get; init; }
    public required Risk Risk { get; init; }
    public required string Reason { get; init; }
    public bool GuardAgainstLiveProjects { get; init; }
    public IReadOnlyList<string> SearchSubpaths { get; init; } = [];
    public int? StaleAfterDays { get; init; }
    public TimeSpan? MinimumAge { get; init; }

    public static IReadOnlyList<CleanupTarget> All(KnownFolders f, bool includeDependencies = false)
    {
        string H(params string[] p) => WinPath.Join(f.Home, p);
        string L(params string[] p) => WinPath.Join(f.LocalAppData, p);

        var targets = new List<CleanupTarget>
        {
            Dir("Package managers", "npm cache", L("npm-cache", "_cacache"), Risk.Safe,
                "Tarball cache. npm refetches anything it needs."),
            Dir("Package managers", "pnpm store", L("pnpm", "store"), Risk.Review,
                "Shared package store. Existing installs relink from it, so expect a refetch."),
            Dir("Package managers", "Yarn cache", L("Yarn", "Cache"), Risk.Safe,
                "Yarn refetches on the next install."),
            Dir("Package managers", "Bun cache", H(".bun", "install", "cache"), Risk.Safe,
                "Bun refetches on the next install."),
            Dir("Package managers", "pip cache", L("pip", "cache"), Risk.Safe,
                "Wheel cache. pip refetches when needed."),
            Dir("Package managers", "uv cache", L("uv", "cache"), Risk.Safe,
                "uv refetches on the next sync."),
            Dir("Package managers", "Go build cache", L("go-build"), Risk.Safe,
                "Go rebuilds these objects on demand."),
            Dir("Package managers", "Go module downloads", H("go", "pkg", "mod", "cache", "download"), Risk.Review,
                "Module zips. Re-downloaded on the next build."),
            Dir("Package managers", "Cargo registry cache", H(".cargo", "registry", "cache"), Risk.Review,
                "Crate archives. Re-downloaded on the next build."),
            Dir("Package managers", "Gradle caches", H(".gradle", "caches"), Risk.Review,
                "Re-downloaded and rebuilt on the next Gradle run."),
            Dir("Package managers", "Maven repository", H(".m2", "repository"), Risk.Review,
                "Re-downloaded on the next Maven build."),
            Dir("Package managers", "NuGet packages", H(".nuget", "packages"), Risk.Review,
                "Restored again on the next dotnet build."),
            Dir("Package managers", "NuGet HTTP cache", L("NuGet", "v3-cache"), Risk.Safe,
                "Download cache. NuGet refetches what it needs."),
            Dir("Package managers", "Playwright browsers", L("ms-playwright"), Risk.Review,
                "Browser binaries. Reinstall with playwright install."),
            Dir("Package managers", "Puppeteer browsers", H(".cache", "puppeteer"), Risk.Review,
                "Browser binaries. Re-downloaded on the next install."),

            Search("Project builds", "Next.js cache", f.Home, [".next"], Risk.Safe,
                "Next.js rebuilds this. Covers both .next\\cache and .next\\dev\\cache.",
                subpaths: ["cache", "dev\\cache"]),
            Search("Project builds", "Turbo cache", f.Home, [".turbo"], Risk.Safe,
                "Turborepo task cache. Rebuilt on the next run."),
            Search("Project builds", "Vite and SvelteKit caches", f.Home,
                [".svelte-kit", ".vite", ".parcel-cache", ".nuxt"], Risk.Safe,
                "Dev server caches. Rebuilt on the next start."),
            Search("Project builds", "Angular cache", f.Home, [".angular"], Risk.Safe,
                "Angular rebuilds this cache."),

            new()
            {
                Category = "App caches", Title = "Temp files", Shape = ShapeKind.Contents, Path = f.Temp,
                Risk = Risk.Safe, MinimumAge = TimeSpan.FromDays(1),
                Reason = "Leftovers from installers and apps. Only files older than a day, and anything in use is skipped.",
            },
            Dir("App caches", "Crash dumps", L("CrashDumps"), Risk.Safe,
                "Memory dumps from apps that crashed. Only useful while chasing that crash."),
            Dir("App caches", "Error reports", L("Microsoft", "Windows", "WER", "ReportArchive"), Risk.Safe,
                "Crash reports Windows already handled."),
            Dir("App caches", "DirectX shader cache", L("D3DSCache"), Risk.Safe,
                "Compiled shaders. Games and apps rebuild them on the next launch."),
            Dir("App caches", "NVIDIA shader cache", L("NVIDIA", "DXCache"), Risk.Safe,
                "Compiled shaders. Rebuilt on the next launch."),

            new()
            {
                Category = "Reclaimable", Title = "Recycle Bin", Shape = ShapeKind.RecycleBin,
                Path = CleanupItem.RecycleBinPath, Risk = Risk.Caution,
                Reason = "Emptying this is final. Check it first.",
            },
            Dir("Reclaimable", "Downloads", H("Downloads"), Risk.ReportOnly,
                "Your own files. Shown so you know what the space is for."),
        };

        if (includeDependencies)
        {
            targets.Add(Search("Reclaimable", "Dependencies in dormant projects", f.Home, ["node_modules"],
                Risk.Caution, "Reinstall with your package manager before that project builds again.",
                maxDepth: 4, staleAfterDays: 45));
        }

        return targets;
    }

    private static CleanupTarget Dir(string category, string title, string path, Risk risk, string reason) => new()
    {
        Category = category, Title = title, Shape = ShapeKind.Directory, Path = path, Risk = risk, Reason = reason,
    };

    private static CleanupTarget Search(
        string category, string title, string root, string[] names, Risk risk, string reason,
        string[]? subpaths = null, int maxDepth = 6, int? staleAfterDays = null) => new()
    {
        Category = category,
        Title = title,
        Shape = ShapeKind.Search,
        Path = root,
        SearchNames = names,
        MaxDepth = maxDepth,
        Risk = risk,
        Reason = reason,
        GuardAgainstLiveProjects = true,
        SearchSubpaths = subpaths ?? [],
        StaleAfterDays = staleAfterDays,
    };
}
