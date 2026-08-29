# sds-clean

`sds-clean` 0.1.0 is a local, review-first macOS cleanup CLI. It discovers a deliberately narrow set of tool-managed caches, eligible Xcode DerivedData children not modified today or yesterday, and eligible old top-level installer/archive files in Downloads. DerivedData and Downloads each appear as one aggregate plan row without child paths.

It does not scan Home generally, use telemetry or network calls, invoke a shell, request sudo or Full Disk Access, empty Trash, or directly delete files. Tool cleanups are permanent and opt-in. File candidates move through Foundation's native `FileManager.trashItem` API.

## Local usage

```sh
sds-clean --dry-run
sds-clean --json
sds-clean --delete
sds-clean --version
```

Bare `sds-clean` prints a short mode summary and exits without scanning. Exactly one operational mode is required: `--dry-run` for the complete human-readable plan, `--json` for the same plan as machine-readable dry-run data, or `--delete` to show that complete all-items plan and ask one default-No confirmation. After confirmation, every captured member is revalidated: DerivedData children and eligible Downloads files move separately through macOS Trash, while neither root folder is ever moved.

Human output is a compact all-items plan with one estimate per eligible category. The Downloads row distinguishes the narrowly eligible cleanup selection from the whole folder's allocated usage. `Estimated disk cleanup` sums known permanent cleanup estimates and known allocated bytes that would move to Trash; it describes the work performed by the plan, not immediate free disk space. Categories in the execution plan with no reliable estimate remain visible as `estimate unavailable`, and the total says that unavailable estimates are additional. DerivedData and Downloads remain recoverable by restoring them from Trash.

JSON schema version 5 adds the optional `totalScopeBytes` context field while retaining the other stable names. For permanent commands, `currentScopeBytes` measures only the exact command-owned cache paths in `scope`; npm is limited to its configured `_cacache`, and Yarn Classic uses `yarn cache dir`. `estimatedReclaimBytes` follows `estimateBasis` and can cover a different scope, as with Homebrew. For Trash aggregates, `currentScopeBytes`, `trashMoveBytes`, and `eligibleItemBytes` describe only the captured eligible items. Downloads additionally reports whole-folder allocated usage in `totalScopeBytes`; it is context, never added to reclaim totals. `estimatedPermanentReclaimBytes` sums known permanent cleanup estimates; `plannedTrashBytes` is a separate subtotal that remains on disk until Trash is emptied. The legacy field name `unestimatedTrashSelectionCount` counts ready Trash aggregates whose byte size is unknown.

Downloads eligibility remains narrow: current-user-owned, non-symlink, regular top-level files older than 30 days with supported installer/archive suffixes. Nested, hidden, partial-download, package, alias, young, and unrelated files are excluded. Downloads access may be denied by macOS privacy controls; do not grant Full Disk Access or use sudo for this tool. Tool notices distinguish an absent supported executable, unsupported installation layout, failed version probe, unrecognized version output, unavailable cleanup command, and an absent eligible cache scope. In every disabled state, no tool cleanup command runs.

## Development

```sh
swift test
swift build -c release
```

The package has no third-party dependencies. Tests use injected process and Trash boundaries and never clean real caches or empty Trash.

## Future Homebrew work

A future release can add a separate public repository/tag, checksummed release artifact, tap/formula, installation test, and eventual homebrew/core proposal. None of that publishing or tap work is part of 0.1.0.
