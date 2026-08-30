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

Example output (your results will vary):

```
$ sds-clean --dry-run
Estimated disk cleanup: 51.56 GB
  Permanent: 30.81 GB
  Move to Trash: 20.75 GB (you can undo by restoring from Trash)

Permanent: 30.81 GB
- Homebrew: 372.7 MB
- npm: 26.26 GB
- Yarn Classic: 0 bytes
- SwiftPM: 4.17 GB

Move to Trash: 20.75 GB
- Xcode DerivedData: 20.73 GB
- Downloads: 21.3 MB eligible (206.5 MB total)

This is a dry run; no files will be deleted.
```

Human output is a compact all-items plan with one estimate per eligible category. The Downloads row distinguishes the narrowly eligible cleanup selection from the whole folder's allocated usage. `Estimated disk cleanup` sums known permanent cleanup estimates and known allocated bytes that would move to Trash; it describes the work performed by the plan, not immediate free disk space. Categories in the execution plan with no reliable estimate remain visible as `estimate unavailable`, and the total says that unavailable estimates are additional. DerivedData and Downloads remain recoverable by restoring them from Trash.

JSON schema version 5 adds the optional `totalScopeBytes` context field while retaining the other stable names. For permanent commands, `currentScopeBytes` measures only the exact command-owned cache paths in `scope`; npm is limited to its configured `_cacache`, Yarn Classic uses `yarn cache dir`, and eligible Yarn 2+ installations use the command-reported `globalFolder`. Modern Yarn runs only as direct `yarn cache clean --mirror`; its estimate is unavailable because the command removes a subset of `globalFolder` (the mirror plus bundled global-artifact hooks), never a project `.yarn/cache`, unplugged folder, install state, or Zero-Installs archive. `estimatedReclaimBytes` follows `estimateBasis` and can cover a different scope, as with Homebrew. For Trash aggregates, `currentScopeBytes`, `trashMoveBytes`, and `eligibleItemBytes` describe only the captured eligible items. Downloads additionally reports whole-folder allocated usage in `totalScopeBytes`; it is context, never added to reclaim totals. `estimatedPermanentReclaimBytes` sums known permanent cleanup estimates; `plannedTrashBytes` is a separate subtotal that remains on disk until Trash is emptied. The legacy field name `unestimatedTrashSelectionCount` counts ready Trash aggregates whose byte size is unknown.

Modern Yarn support is deliberately narrower than executable discovery. The executable must be Yarn 2 or newer in a canonical Homebrew or system-wide Node installation; Corepack shims, project `.yarn/releases` binaries, and other user wrappers are refused. `cache clean --help` must advertise the exact `--mirror` option, and `config get globalFolder` must return one unambiguous current-user-owned, non-symlink directory below Home on Home's filesystem. Every probe and cleanup runs from `/` with project rc discovery redirected to an absent root filename, `yarnPath` ignored, Corepack project/network behavior disabled, and Yarn network, telemetry, scripts, update-like tips, and progress behavior disabled. Nonzero command exits remain failures with no deletion fallback. Unsupported or absent modern Yarn appears only in JSON diagnostics, leaving compact human output unchanged.

Downloads eligibility remains narrow: current-user-owned, non-symlink, regular top-level files older than 30 days with supported installer/archive suffixes. Nested, hidden, partial-download, package, alias, young, and unrelated files are excluded. Downloads access may be denied by macOS privacy controls; do not grant Full Disk Access or use sudo for this tool. Tool notices distinguish an absent supported executable, unsupported installation layout, failed version probe, unrecognized version output, unavailable cleanup command, and an absent eligible cache scope. In every disabled state, no tool cleanup command runs.

## Install with Homebrew

```sh
brew install hboon/tap/sds-clean
```

## Install from source

Clone the repository and build the release executable with Swift Package
Manager:

```sh
git clone https://github.com/hboon/sds-clean.git
cd sds-clean
swift build -c release
.build/release/sds-clean --version
```

Run the executable in place, copy it to a directory already on your `PATH`, or
invoke it by its full path. Installation does not require sudo.

The package uses Swift tools version 6.2. Building currently requires a Swift
6.2 toolchain; the supported Apple build host is Xcode 26. Older Xcode releases
that do not provide Swift 6.2 cannot build this version.

## Development

```sh
swift test
swift build -c release
```

The package has no third-party dependencies. Tests use injected process and Trash boundaries and never clean real caches or empty Trash.

## License

sds-clean is released under the [MIT License](LICENSE).
