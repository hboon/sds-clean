# sds-clean

`sds-clean` 0.1.1 is a local macOS cleanup CLI. It checks a set of tool-managed caches, eligible Xcode DerivedData children (not modified today or yesterday), and eligible installer/archive files in Downloads.

It does not scan Home generally, or include telemetry.

## Local usage

```sh
sds-clean --dry-run
sds-clean --delete
sds-clean --version
```

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
