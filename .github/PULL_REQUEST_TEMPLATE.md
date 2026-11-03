## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How I checked it

<!-- Which diagnostic modes you ran and what you compared against. -->

- [ ] `swift build -c release` passes with no new warnings
- [ ] `BALLAST_DIAGNOSTIC=layout` passes (UI changes)
- [ ] `BALLAST_DIAGNOSTIC=scan` output reviewed (storage changes)
- [ ] Memory figures compared with Activity Monitor or `vm_stat` (memory changes)
- [ ] `BallastDiagnostic.exe` compared with Task Manager (Windows memory changes)

Tested on (macOS or Windows version):

## Storage changes only

- [ ] The risk tier is honest about the cost of losing the data
- [ ] `DeletionGuard` was not loosened
- [ ] Project caches use `guardAgainstLiveProjects`
