# Ballast

[![CI](https://github.com/tekcify/ballast/actions/workflows/ci.yml/badge.svg)](https://github.com/tekcify/ballast/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)

Ballast is a small macOS menu bar app for developers whose Mac keeps running out
of memory or disk. It shows where your memory is actually going, tells you which
apps are worth quitting, and clears caches and build output you can safely lose.

It is written in Swift and SwiftUI, has no dependencies, and never deletes
anything you have not ticked and confirmed.

## What it does

**Memory**

- Shows memory in use, split into app, wired, compressed and cached memory, with
  figures that match `vm_stat` and Activity Monitor.
- Lists apps by their real footprint, grouping helper processes under the app
  they belong to. Chrome's dozens of helpers show up as one row, and two dev
  servers in different projects stay separate.
- Recommends what to quit, based on footprint, how long since you last used the
  app, whether it is hidden, and whether its memory keeps growing.
- Alerts you when one app gets too large, swap grows, an app looks like it is
  leaking, or free disk space runs low.

**Storage**

- Scans Xcode data, package manager caches (npm, pnpm, Yarn, Bun, SwiftPM,
  Homebrew, pip, uv, Go, Cargo, Gradle, Maven, Playwright, Puppeteer), project
  build caches (Next.js, Turbo, Vite, SvelteKit, Angular), app caches, logs and
  the Trash.
- Sorts every item into a risk tier and only pre-selects the ones that rebuild
  themselves.
- Leaves a project alone while a process is running inside it, so a live dev
  server keeps its cache.
- Reports device backups, build archives and Downloads, but never offers to
  delete them.

## Install

You need macOS 14 or later and Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/tekcify/ballast.git
cd ballast
./build.sh
```

`build.sh` compiles a release build, assembles `Ballast.app`, signs it and copies
it to `/Applications` (or `~/Applications` if `/Applications` is not writable).
Open it from Applications and it lives in your menu bar from then on. Use
`./build.sh --no-install` to leave the app in `build/` instead.

### Signing and notifications

The script signs with the first `Developer ID Application` identity in your
keychain. Without one it signs ad-hoc, which works fine except for one thing:
macOS refuses system notifications to ad-hoc signed apps, so Ballast falls back
to plain AppleScript notifications without action buttons.

To pick a specific identity:

```sh
BALLAST_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

macOS remembers a notification denial per bundle identifier, and signing again
later does not clear it. If you plan to use a real identity, sign with it before
the first launch.

### Font

Ballast uses the [Aspekta](https://github.com/ivodolenc/aspekta) typeface when
`AspektaVF.ttf` is installed in `~/Library/Fonts`, and the system font otherwise.
The build bundles it automatically when it is present.

## How it works

### Memory readings

System figures come from `host_statistics64`. Per app memory is `phys_footprint`
from `proc_pid_rusage`, the same number as Activity Monitor's Memory column.

Processes owned by root refuse `proc_pid_rusage` without elevated privileges.
For those, Ballast falls back to resident size from `ps` and labels the figure as
approximate.

Summed per app figures read higher than the system total, because shared
framework pages are counted once in every process that maps them.

### What it will and will not suggest

Processes macOS depends on are never suggested. Neither is the app you are
currently using, unless memory pressure is critical. Virtual machines and
container runtimes get a note to shut them down from inside rather than a plain
quit.

Quitting asks the app politely, the way the Dock does, so it can save. Ballast
only sends `SIGKILL` if the app is still running after a grace period.

### Storage tiers

| Tier | Meaning | How it is removed |
| --- | --- | --- |
| Safe | Regenerated automatically | Deleted, and selected for you |
| Rebuilds | Costs a download or a rebuild | Moved to the Trash, not selected |
| Careful | Real content | Moved to the Trash, not selected |
| Kept | Measured only | Never deleted |

`node_modules` folders are off by default. There are usually hundreds of them
and measuring them dominates the scan, so they sit behind a toggle on the Storage
pane.

Every deletion is appended to
`~/Library/Application Support/Ballast/cleanup-log.jsonl`.

### The deletion guard

`DeletionGuard` is the last check before anything is removed. It is built from
the same target list the scanner uses, so a path that no target could have
produced is refused even if it reaches the cleaner some other way. It also
refuses:

- anything outside your home folder, or the home folder itself
- anything less than two levels deep
- anything inside `.git`, `.ssh`, `.gnupg`, `.aws`, `.kube`, or local AI
  assistant folders (`.codex`, `.claude`, `.cursor`, `.agents`, `.openai`)

## Diagnostics

The app binary doubles as a command line tool for checking its readings without
the UI. Each mode prints its result and exits.

```sh
BALLAST_DIAGNOSTIC=1 /Applications/Ballast.app/Contents/MacOS/Ballast
```

| `BALLAST_DIAGNOSTIC` | What it does |
| --- | --- |
| `1` | Prints one memory snapshot and the current advice |
| `scan` | Dry run of the storage scan: every item, what would be selected and what the guard refuses. Deletes nothing. Add `BALLAST_DEEP=1` to include `node_modules` |
| `layout` | Lays out each pane offscreen and fails if the popover would collapse |
| `render` | Renders each pane to `/tmp/ballast-*.png` |
| `notify` | Sends a test alert and reports which delivery path carried it |

Run the `scan` dry run before trusting a cleanup on a new machine.

## Good to know

A full storage scan can take a few minutes on a machine with many projects,
because `du` has to walk large stores such as `~/.gradle/caches` and the pnpm
store. Results appear as they are measured, and you can stop the scan at any
time.

## Contributing

Bug reports, new cleanup targets and fixes are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) to get set up, and please report anything that
could delete the wrong files privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Tekcify Technologies Ltd
