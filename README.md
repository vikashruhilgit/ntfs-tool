# ntfs-tool

Read/write NTFS on Apple Silicon Macs from the command line. MIT-licensed.

`ntfsctl` is a single-binary CLI that reads, writes, copies, renames, and deletes files on NTFS volumes — no Apple Developer subscription, no SIP changes, no FSKit entitlement. It operates on raw block devices, so it works regardless of whether macOS has the drive mounted.

```bash
# Find your NTFS drive:
sudo ntfsctl scan

# List a directory by path:
sudo ntfsctl list --long /dev/disk10s1 /Photos

# Stream-read a file (no size cap):
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg > out.jpg

# Recursively copy a host directory tree onto NTFS, with progress:
sudo ntfsctl cp -r --progress ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

# Pull a directory back to the host:
sudo ntfsctl cp -r --from-volume /Backups /dev/disk10s1 ~/restored/

# Rename / move:
sudo ntfsctl mv /dev/disk10s1 /draft.txt /Archive/final.txt

# Recursive delete (force flag required for safety):
sudo ntfsctl rm -r --force /dev/disk10s1 /Backups/MyPhone
```

There's also an [`NTFSCore`](Packages/NTFSCore) Swift library (embed in any project — 102 unit tests, no FSKit dependency) and an FSKit System Extension + SwiftUI menu-bar app (code complete, mount UX needs Apple Developer entitlement or SIP-off to validate against real hardware — see [`docs/STATUS.md`](docs/STATUS.md)).

Built for macOS 15.4+ (Sequoia) on Apple Silicon. Swift 6.0+ / Xcode 16.3+ to build from source; a prebuilt binary is on the [Releases tab](https://github.com/vikashruhilgit/ntfs-tool/releases) (when v0.2.0 ships — see [`docs/READY-TO-USE-PLAN.md`](docs/READY-TO-USE-PLAN.md) for what's left).

## Quick start — CLI

### Build

```bash
cd Tools/ntfsctl
swift build --configuration release
# Binary at .build/release/ntfsctl
ln -s "$(pwd)/.build/release/ntfsctl" /usr/local/bin/ntfsctl
```

### The mount/unmount dance

macOS auto-mounts NTFS drives read-only via Apple's built-in driver. That mount locks the device, so `ntfsctl` (which writes raw) needs you to release the lock first:

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl <subcommand> /dev/disk10s1 ...
diskutil mount /dev/disk10s1   # re-mount so Finder sees the changes
```

The drive stays plugged in throughout — only the filesystem mount is dropped.

### Safety guarantees

- **Volume marked dirty before writes, clean after** — if `ntfsctl` is interrupted (Ctrl+C, kernel panic, unplug), Windows sees the dirty bit on next mount and `chkdsk` auto-runs. Without this, you'd silently inherit a corrupt filesystem that Windows trusts.
- **`fcntl(F_FULLFSYNC)` before clearing the dirty bit** — guarantees data hits physical media before the dirty bit is cleared. Survives fast unplugs.
- **Exclusive `flock()` on the device** — two concurrent `ntfsctl` processes on the same device fail-fast instead of corrupting the bitmap.
- **`rm -r /` rejected** — a one-typo full-volume wipe is impossible by design. Recursive deletes require `--force` (or `--dry-run` to preview).
- **Bare arguments are always paths, never MFT record numbers** — a file literally named "38" no longer silently targets MFT record 38. Pass `--recnum` to opt into the legacy numeric form.

Full CLI walkthrough: [`docs/CLI.md`](docs/CLI.md).

## Quick start — library

```swift
import NTFSCore

let device = try FileHandleBlockDevice(openingFileForUpdateAt: "/dev/disk10s1")
let volume = try await Volume(device: device)

// Read
let entries = try await volume.enumerate(directory: 5)  // root
let bytes = try await volume.readFile(at: someRecordNumber)

// Write — always brackets in beginWriteSession() / endWriteSession() for crash safety
try await volume.beginWriteSession()
let recnum = try await volume.createFile(named: "new.txt", inDirectory: 5)
try await volume.write(at: recnum, offset: 0, bytes: Data("hi".utf8))
try await volume.endWriteSession()
```

## Quick start — FSKit extension

The FSKit extension is code-complete but Apple's runtime requires either SIP-off + developer mode (free, ~15 min, fully reversible) or the Apple Developer Program FSKit entitlement ($99/yr, 2-14 day wait). Procedure in [`docs/STATUS.md`](docs/STATUS.md#1-fskit-mount-validation-on-the-m4-high-value).

## Repo layout

```
ntfs-tool/
├── Packages/NTFSCore/     Swift library (pure NTFS read/write, 102 tests)
├── Extensions/NTFSFileSystem/  FSKit System Extension
├── Apps/NTFSMountManager/      SwiftUI menu-bar app
├── Tools/ntfsctl/         Command-line tool (13 subcommands)
├── docs/
│   ├── CLI.md             ntfsctl walkthrough
│   ├── STATUS.md          What's done, what's pending
│   ├── READY-TO-USE-PLAN.md  Path to v0.2.0 release
│   └── AUDIT-REPORT.md    Red-team safety audit
└── CLAUDE.md              Architecture + conventions
```

## Building everything

```bash
# NTFSCore (no Xcode needed)
cd Packages/NTFSCore && swift build && swift test
# → 102 tests pass

# ntfsctl CLI (no Xcode needed)
cd Tools/ntfsctl && swift build --configuration release

# FSKit extension + menu-bar app (require Xcode)
brew install xcodegen
xcodegen generate
xcodebuild -project NTFSMountManager.xcodeproj -scheme NTFSMountManager build
```

## Status

| Layer | Status |
|---|---|
| `ntfsctl` read commands (info, scan, list, cat, verify) | Production-ready |
| `ntfsctl` write commands (cp, write, rm, mv, create, delete, truncate) | Usable for most workflows; one known cap (LARGE_INDEX leaf split, see [`docs/STATUS.md`](docs/STATUS.md)) blocks copying > ~50 files into a single fresh directory |
| NTFSCore library | Production-ready (102/102 tests, real 4 TB Windows drive validated) |
| FSKit extension build | Builds clean in CI |
| FSKit mount in Finder | Needs SIP-off / entitlement to validate |
| Windows `chkdsk /f` clean | Needs your test on a Windows machine |

Full breakdown: [`docs/STATUS.md`](docs/STATUS.md).

## License

[MIT](LICENSE). Use it however you like.

The NTFS implementation is a clean-room Swift port from publicly-documented on-disk format specs — no GPL code incorporated.

## Contributing

Architecture notes + conventions in [`CLAUDE.md`](CLAUDE.md). For substantive work, file an issue first to align on approach — particularly for the engineering follow-ups documented in [`docs/STATUS.md`](docs/STATUS.md) (LARGE_INDEX leaf split, `$LogFile` journaling, MFT `$BITMAP` allocator).
