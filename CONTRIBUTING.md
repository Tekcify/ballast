# Contributing to Ballast

Thanks for helping out. Ballast deletes files on people's machines, so the bar
for storage changes is higher than for most projects. This guide covers how to
get set up and what a good change looks like.

Ballast is two native apps that follow the same rules: the Windows app in
`windows/` (.NET) and the Mac app at the repo root (Swift). Set up whichever
one you are changing. Storage rules should stay in step across both.

## The Windows app

The Windows version lives in `windows/`. It is a .NET 10 WPF tray app with no
third party runtime dependencies.

You need Windows 10 or 11 and the .NET 10 SDK.

```powershell
git clone https://github.com/tekcify/ballast.git
cd ballast\windows
.\build.ps1 -NoInstall
```

| Folder | What lives there |
| --- | --- |
| `windows/src/Ballast.Core` | The advisor, heads-up timing, cleanup targets, `DeletionGuard`, scanner and cleaner. Plain .NET, so it builds and tests on any OS |
| `windows/src/Ballast` | The tray app: native memory and process probes, the panel, the heads-up card |
| `windows/tests/Ballast.Core.Tests` | Unit tests for the guard, the cleaner, the advisor and smart pick |

You can build and test it from a Mac or Linux machine too, which is handy when
a change touches both apps:

```sh
dotnet test windows/tests/Ballast.Core.Tests
dotnet publish windows/src/Ballast/Ballast.csproj -c Release -r win-x64
```

On Windows, `windows\build.ps1 -NoInstall` builds without installing, and
`Ballast.exe --diagnostic snapshot`, `scan` and `headsup` are the same checks as
the Mac diagnostic modes. `--diagnostic quit` quits throwaway console processes
to check that Ctrl+C stops them cleanly and that a reused pid is never touched;
CI runs it on every push. Rules that decide what gets deleted belong in
`Ballast.Core` with a test next to them.

## The Mac app

You need macOS 14 or later and Xcode 26 or later (Swift 6.2). There are no
third party dependencies.

```sh
git clone https://github.com/tekcify/ballast.git
cd ballast
swift build
```

To run the app from your build:

```sh
./build.sh --no-install
open build/Ballast.app
```

`build.sh` signs ad-hoc when you have no Developer ID identity, which is fine for
development. Alerts then arrive as plain AppleScript notifications.

The project is a Swift package, so you can also open the folder in Xcode with
`xed .` and run the `Ballast` scheme.

### Mac project layout

| Folder | What lives there |
| --- | --- |
| `Sources/Ballast/System` | Memory and process probes, app grouping, quitting |
| `Sources/Ballast/Advisor` | Scores apps and decides what to recommend |
| `Sources/Ballast/Alerts` | Notification delivery and the fallback path |
| `Sources/Ballast/Storage` | Cleanup targets, the scanner, the cleaner and `DeletionGuard` |
| `Sources/Ballast/Model` | The `Monitor` that drives the UI, preferences, login item |
| `Sources/Ballast/UI` | The SwiftUI panes and shared theme |
| `Sources/Ballast/Support` | Diagnostics, formatting and the shell helper |

The package uses Swift 6 language mode with the main actor as the default
isolation. Plain data types read by actors need to be marked `nonisolated`.

### Checking a Mac change

The diagnostic modes are the main test harness for the Mac app, and every pull
request should say which ones you ran.

```sh
swift build -c release
BALLAST_DIAGNOSTIC=1      .build/release/Ballast   # memory snapshot and advice
BALLAST_DIAGNOSTIC=scan   .build/release/Ballast   # storage dry run, deletes nothing
BALLAST_DIAGNOSTIC=layout .build/release/Ballast   # fails if the popover collapses
BALLAST_DIAGNOSTIC=render .build/release/Ballast   # writes /tmp/ballast-*.png
BALLAST_DIAGNOSTIC=headsup .build/release/Ballast  # shows the heads-up card for ten seconds
BALLAST_DIAGNOSTIC=readme .build/release/Ballast   # re-renders the README screenshots into assets/
swift test                                          # heads-up timing, smart pick, saved scans
```

- For memory changes, compare the snapshot against `vm_stat`, Activity Monitor
  or `vmmap --summary <pid>`.
- For UI changes, run `layout` and look at the `render` images. Open the real
  popover too, since offscreen rendering does not draw scroll view contents.
- For storage changes, run the `scan` dry run and check every line it prints.

The Windows core has unit tests for its guard and advisor. A matching Swift test
target for the Mac guard would be a very welcome contribution.

## Adding a cleanup target

Targets live in `Sources/Ballast/Storage/CleanupTarget.swift` on the Mac and
`windows/src/Ballast.Core/Storage/CleanupTarget.cs` on Windows. A new target
needs:

- a **risk tier** that is honest about the cost of losing it. If removing it
  means a download or a rebuild, it is `review`, not `safe`. If it holds
  anything a person made, it is `caution` or `reportOnly`.
- a **reason** in plain words that tells the user what happens if they delete it.
- `guardAgainstLiveProjects` for anything inside a project folder, so a running
  dev server keeps its cache.
- a search depth that keeps the scan fast.

Then run the `scan` dry run and include the relevant lines in your pull request.

## Rules for anything that deletes

- Never loosen `DeletionGuard` to make a new target work. Fix the target instead.
- Nothing may be removed without the user selecting it and confirming.
- Anything that is not regenerated automatically goes to the Recycle Bin or
  Trash, not straight to deletion.
- Every removal must be written to the cleanup log.

If you find a way to get Ballast to delete something it should not, report it
privately as described in [SECURITY.md](SECURITY.md) rather than in a public
issue.

## Pull requests

1. Fork the repo and create a branch named after the change, such as
   `fix/scan-timeout` or `feature/docker-cache`.
2. Keep each pull request to one change, and keep unrelated reformatting out of
   it.
3. Make sure `swift build -c release` passes without new warnings, and for
   Windows changes that `dotnet build windows/Ballast.slnx -c Release` and
   `dotnet test windows/tests/Ballast.Core.Tests` pass.
4. Fill in the pull request template, including which checks you ran and on
   which Windows or macOS version.

For anything large, such as a new pane or a change to how memory is measured,
open an issue first so we can agree on the approach before you put in the work.

## Code of conduct

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
