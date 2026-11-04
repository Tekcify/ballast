# Security policy

Ballast removes files from people's machines, so we treat any way to make it
delete the wrong thing as a security issue. That includes:

- a path that gets past `DeletionGuard` when it should be refused
- a cleanup that removes something outside the item the user selected
- an item placed in the wrong risk tier, so real content is deleted outright
  instead of moved to the Recycle Bin or Trash
- a running project's files being offered for cleanup

## Reporting a vulnerability

Please do not open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/tekcify/ballast/security/advisories/new)
with:

- what you did and what was removed or offered for removal
- the output of the storage dry run for the affected item (`Ballast.exe
  --diagnostic scan` on Windows, `BALLAST_DIAGNOSTIC=scan` on a Mac), with
  personal paths trimmed if you prefer
- your Windows or macOS version and the Ballast commit you built from

We aim to reply within a few days and will keep you updated until a fix ships.
We are happy to credit you in the release notes if you would like.

## Supported versions

Fixes go into the `main` branch. Please reproduce on the latest commit before
reporting.
