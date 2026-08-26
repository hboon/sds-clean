# sds-clean

`sds-clean` 0.1.0 is a local, review-first macOS cleanup CLI. It discovers a deliberately narrow set of tool-managed caches, individual Xcode DerivedData children, and up to 20 large old installer/archive files directly inside Downloads.

It does not scan Home generally, use telemetry or network calls, invoke a shell, request sudo or Full Disk Access, empty Trash, or directly delete files. Tool cleanups are permanent and opt-in. File candidates move through Foundation's native `FileManager.trashItem` API.

## Local usage

```sh
sds-clean --dry-run
sds-clean --json
sds-clean
sds-clean --yes --select 1,3
sds-clean --version
```

Interactive runs select nothing by default and require a second exact-TTY confirmation. `--json` implies dry-run. `--yes` still requires an explicit selection and a TTY-visible plan.

Downloads access may be denied by macOS privacy controls. That is reported as a normal skip; do not grant Full Disk Access or use sudo for this tool.

## Development

```sh
swift test
swift build -c release
```

The package has no third-party dependencies. Tests use injected process and Trash boundaries and never clean real caches or empty Trash.

## Future Homebrew work

A future release can add a separate public repository/tag, checksummed release artifact, tap/formula, installation test, and eventual homebrew/core proposal. None of that publishing or tap work is part of 0.1.0.
