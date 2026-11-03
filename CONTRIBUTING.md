# Contributing to Ballast

Thanks for helping out. Ballast deletes files on people's machines, so the bar
for storage changes is higher than for most projects. This guide covers how to
get set up and what a good change looks like.

## Setting up

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

### On Windows

You need Windows 10 or 11 on x64 and the Swift 6.4 toolchain, installed as
described in [swift.org's Windows guide](https://www.swift.org/install/windows/).
Then in PowerShell:

```powershell
swift build
swift test
.\build.ps1 -Run    # release build into build\Ballast, then start the tray app
```

VS Code with the Swift extension works well for editing on Windows.

## Project layout

The code is split into a shared core and one app per platform. `BallastCore`
holds the rules and data types that do not touch the operating system, so both
apps build on the same logic. `Package.swift` only includes the Mac targets on
macOS and the Windows targets on Windows, so `swift build` builds the app for
the machine you are on.

| Folder | What lives there |
| --- | --- |
| `Sources/BallastCore/Advisor` | Scores apps and decides what to recommend |
| `Sources/BallastCore/Alerts` | `HeadsUpPolicy`, which decides when the heads-up appears |
| `Sources/BallastCore/Storage` | Cleanup targets, pick rules, `DeletionGuard` and the saved scan |
| `Sources/BallastCore/System` | Memory, disk and app group data types |
| `Sources/BallastCore/Model` | Preferences |
| `Sources/BallastCore/Support` | Formatting |
| `Sources/BallastMac/System` | macOS memory and process probes, app grouping, quitting |
| `Sources/BallastMac/Alerts` | The island, the card, and notification delivery |
| `Sources/BallastMac/Storage` | The scanner and the cleaner |
| `Sources/BallastMac/Model` | The `Monitor` that drives the UI, login item |
| `Sources/BallastMac/UI` | The SwiftUI panes and shared theme |
| `Sources/BallastMac/Support` | Diagnostics and the shell helper |
| `Sources/BallastWindowsKit` | Win32 probes, app grouping, quitting, login item and `WindowsMonitor` |
| `Sources/BallastWindows` | The tray app and its message loop |
| `Sources/BallastDiagnostic` | The Windows console diagnostic |

Core types the apps use are marked `package`, which makes them visible to
other targets in this package and nowhere else. A new core type or member an
app needs must be marked `package` too, including an explicit `init` for
structs, because Swift's automatic one stays internal to the core.

The package uses Swift 6 language mode with the main actor as the default
isolation. Plain data types read by actors need to be marked `nonisolated`, and
so does anything Win32 calls back into, like window procedures and
`EnumWindows` callbacks.

Some rules differ per platform, such as the processes Ballast must never
suggest quitting. Those sit behind `#if os(Windows)` in the core.

## Checking your change

`swift test` runs the core tests on both platforms, plus the Mac or Windows
tests for the machine you are on. The diagnostic modes cover what tests cannot,
and every pull request should say which ones you ran. CI builds and tests both
platforms on every push.

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

On Windows:

```powershell
.\build.ps1
.\build\Ballast\BallastDiagnostic.exe     # memory snapshot, app tags and advice
$env:BALLAST_SELFTEST = "1"; Start-Process .\build\Ballast\Ballast.exe -Wait
```

- For memory changes, compare the snapshot against Task Manager's Performance
  and Details tabs.
- For quitting changes, try an app with unsaved work and check it is left
  alone while it asks to save.

Tests for `DeletionGuard` and the advisor would be a very welcome
contribution.

## Adding a cleanup target

Targets live in `Sources/BallastCore/Storage/CleanupTarget.swift`. A new target
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
- Anything that is not regenerated automatically goes to the Trash, not straight
  to deletion.
- Every removal must be written to the cleanup log.

If you find a way to get Ballast to delete something it should not, report it
privately as described in [SECURITY.md](SECURITY.md) rather than in a public
issue.

## Pull requests

1. Fork the repo and create a branch named after the change, such as
   `fix/scan-timeout` or `feature/docker-cache`.
2. Keep each pull request to one change, and keep unrelated reformatting out of
   it.
3. Make sure `swift build -c release` passes without new warnings.
4. Fill in the pull request template, including which checks you ran and on
   which macOS version.

For anything large, such as a new pane or a change to how memory is measured,
open an issue first so we can agree on the approach before you put in the work.

## Code of conduct

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
