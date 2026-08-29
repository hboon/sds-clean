# sds-clean

`sds-clean` 0.1.0 is a local, review-first macOS cleanup CLI. It discovers a deliberately narrow set of tool-managed caches and presents eligible Xcode DerivedData children not modified today or yesterday as one aggregate cleanup choice. Downloads appears once for information; the CLI does not clean or move anything in Downloads.

It does not scan Home generally, use telemetry or network calls, invoke a shell, request sudo or Full Disk Access, empty Trash, or directly delete files. Tool cleanups are permanent and opt-in. File candidates move through Foundation's native `FileManager.trashItem` API.

## Local usage

```sh
sds-clean --dry-run
sds-clean --json
sds-clean --delete
sds-clean --delete --yes --select 1,3
sds-clean --version
```

Bare `sds-clean` prints a short mode summary and exits without scanning. Exactly one operational mode is required: `--dry-run` for a human report, `--json` for a machine-readable dry-run, or `--delete` for interactive cleanup. Interactive runs select nothing by default and require a second exact-TTY confirmation. `--yes --select` is available only with `--delete`, still requires a TTY, and always prints the exact plan before execution. The Downloads information row cannot enter an execution plan. Selecting the DerivedData aggregate moves each captured, still-eligible child separately through macOS Trash; it never moves the DerivedData folder itself.

Dry-run output separates current scope size from estimated reclaim. Commands that clear their whole discovered cache scope use that scope size as their estimate. Homebrew uses the total reported by `brew cleanup --prune=120 --dry-run`; if that total cannot be parsed reliably, Homebrew is excluded from the numeric total. Subset commands such as `pnpm store prune` are also explicitly unestimated and excluded. DerivedData sizes are reported separately as bytes that would move to Trash—not immediately freed disk space.

Downloads access may be denied by macOS privacy controls. That is reported as a normal, actionable skip; do not grant Full Disk Access or use sudo for this tool. Tool notices distinguish an absent supported executable, unsupported installation layout, failed version probe, unrecognized version output, unavailable cleanup command, and an absent eligible cache scope. In every disabled state, no tool cleanup command runs.

## Development

```sh
swift test
swift build -c release
```

The package has no third-party dependencies. Tests use injected process and Trash boundaries and never clean real caches or empty Trash.

## Future Homebrew work

A future release can add a separate public repository/tag, checksummed release artifact, tap/formula, installation test, and eventual homebrew/core proposal. None of that publishing or tap work is part of 0.1.0.
