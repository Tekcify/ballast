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

## Project layout

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

## Checking your change

There is no unit test target yet. The app's diagnostic modes are the test
harness, and every pull request should say which ones you ran.

```sh
swift build -c release
BALLAST_DIAGNOSTIC=1      .build/release/Ballast   # memory snapshot and advice
BALLAST_DIAGNOSTIC=scan   .build/release/Ballast   # storage dry run, deletes nothing
BALLAST_DIAGNOSTIC=layout .build/release/Ballast   # fails if the popover collapses
BALLAST_DIAGNOSTIC=render .build/release/Ballast   # writes /tmp/ballast-*.png
```

- For memory changes, compare the snapshot against `vm_stat`, Activity Monitor
  or `vmmap --summary <pid>`.
- For UI changes, run `layout` and look at the `render` images. Open the real
  popover too, since offscreen rendering does not draw scroll view contents.
- For storage changes, run the `scan` dry run and check every line it prints.

A test target for the guard and the advisor would be a very welcome
contribution.

## Adding a cleanup target

Targets live in `Sources/Ballast/Storage/CleanupTarget.swift`. A new target
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
