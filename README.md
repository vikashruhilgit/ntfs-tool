# ntfs-tool

Read/write NTFS on Apple Silicon Macs from the command line. MIT-licensed.

`ntfsctl` is a single-binary CLI that reads, writes, copies, renames, deletes, and audits files on **existing** NTFS volumes — no Apple Developer subscription, no SIP changes, no FSKit entitlement, no third-party drivers (no `macFUSE`, no `ntfs-3g`). It operates on raw block devices, so it works regardless of whether macOS has the drive mounted.

> **Formatting:** `ntfsctl` does **not** create NTFS volumes — format the drive once on Windows (or with `mkntfs-3g`), then use `ntfsctl` to read/write it. (A pure-Swift formatter was prototyped and removed: producing volumes that Windows + macOS mount cleanly is a spec-faithful effort on the scale of `ntfsprogs`, out of scope for this tool.)

```bash
# Find your NTFS drive:
sudo ntfsctl scan

# List a directory by path:
sudo ntfsctl list --long /dev/disk10s1 /Photos

# Stream-read a file (no size cap):
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg > out.jpg

# Recursively copy a host directory tree onto NTFS, with progress:
sudo ntfsctl cp -r --progress ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

# Re-run the same copy without nesting (merges into existing dest):
sudo ntfsctl cp -rT --progress ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

# Pull a directory back to the host:
sudo ntfsctl cp -r --from-volume /Backups /dev/disk10s1 ~/restored/

# Rename / move:
sudo ntfsctl mv /dev/disk10s1 /draft.txt /Archive/final.txt

# Recursive delete (force flag required for safety):
sudo ntfsctl rm -r --force /dev/disk10s1 /Backups/MyPhone

# Validate the on-disk shape (file-level deep dump, volume-wide audit):
sudo ntfsctl dump /dev/disk10s1 /Photos/vacation.jpg       # decodes runlist, $Bitmap cross-check
sudo ntfsctl verify --deep /dev/disk10s1                    # whole-volume runlist ↔ $Bitmap audit
```

There's also an [`NTFSCore`](Packages/NTFSCore) Swift library (embed in any project — **226 unit tests**, no FSKit dependency) and an FSKit System Extension + SwiftUI menu-bar app (code complete, mount UX needs Apple Developer entitlement or SIP-off to validate against real hardware — see [`docs/STATUS.md`](docs/STATUS.md)).

Built for macOS 15.4+ (Sequoia) on Apple Silicon. Swift 6.0+ / Xcode 16.3+ to build from source.

## What's new — v0.5 → v0.7 highlights

- **🎉 Full real-hardware validation.** The complete **22,419-file / 39.6 GiB** phone backup copied into a single directory tree on a freshly-formatted 4 TB WD My Passport — `verify --deep` clean (0 orphans / leaks / dangling / out-of-range / double-allocated; 11.6 M runlist clusters audited). The original ~350-file cap (and ~1,611 / ~6,139 / ~7,997 successors) are all gone — per-directory capacity is now bounded only by free clusters + MFT slots.
- **🧭 Directory-index locality allocator (v0.7.1)** — the root-cause fix that lifted the last cap. Keeps a directory's `$INDEX_ALLOCATION` index blocks contiguous (the Windows/Paragon/Tuxera approach), so the runlist stays tiny and never overflows the MFT record (measured: 222 extents → 1 at 4,000 entries). The `$ATTRIBUTE_LIST` multi-extension machinery is the rare fallback, not the primary mechanism.
- **✂️ Complete copy / move / skip / replace matrix.** `cp` (replace default, `-n` skip, `-T` merge), `cp --move` (cross-device cut — source deleted only after a confirmed copy; `--dry-run` previews), `mv` (within-volume rename/move with `-n` skip / default replace, atomic so the source is never lost).
- **🔬 Built-in diagnostics.** `ntfsctl dump <path>` decodes a file's runlist + cross-checks each cluster against `$Bitmap`; `ntfsctl verify --deep` does the same volume-wide (free-but-referenced / out-of-range / double-allocated).
- **♻️ Every code path is `$ATTRIBUTE_LIST`-aware** — create / read / write / truncate / delete / rename / verify / reclaim-orphans all handle migrated files through the full lifecycle.
- **🛡️ Independent spec-conformance assertions.** Hardened against the "writer and reader share the same bug" trap — multi-extent `$DATA`, boot sector, `$UpCase`, `$AttrDef` are byte-checked against hand-decoded references, not round-tripped through our own decoder.
- **🧪 87 → 226 unit tests** across this arc (plus a `Tools/ntfsctl` integration suite).

Full per-PR changelog: [`CHANGELOG.md`](CHANGELOG.md). Detailed state: [`docs/STATUS.md`](docs/STATUS.md).

## Quick start

### Build from source

```bash
cd Tools/ntfsctl
swift build --configuration release
# Binary at .build/release/ntfsctl
ln -s "$(pwd)/.build/release/ntfsctl" /usr/local/bin/ntfsctl
ntfsctl --version
```

(No Xcode needed for `ntfsctl` or `NTFSCore`. The FSKit extension + menu-bar app need Xcode 16.3+.)

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
- **Compute-first transactional writes** — every multi-attribute mutation (leaf split, migration, file create, file delete) builds the new state in memory first, then commits, then reclaims allocations on any throw. `verify --deep` catches any rollback gap volume-wide.
- **`$ATTRIBUTE_LIST` sequence-number cross-check on read** — a stale `$ATTRIBUTE_LIST` entry pointing at a recycled extension MFT slot throws `corruptOnDisk` at read time rather than silently returning another file's bytes.
- **`reclaim-orphans` never frees a legitimate extension record** — a structural precondition guarantees a v0.5-migration extension record (holding a live file's migrated `$DATA` / `$INDEX_ALLOCATION`) can't reach the reclaim set; only confirmed-base-free leaked extensions are reclaimable.
- **`rm -r /` rejected** — a one-typo full-volume wipe is impossible by design. Recursive deletes require `--force`.
- **Bare arguments are always paths, never MFT record numbers** — a file literally named "38" no longer silently targets MFT record 38. Pass `--recnum` to opt into the legacy numeric form.

Full CLI walkthrough: [`docs/CLI.md`](docs/CLI.md).

## Subcommand reference (15 total)

| Group | Subcommands |
|---|---|
| **Read** | `info`, `scan`, `list`, `cat`, `verify` (+ `--deep`), `dump` |
| **Write** | `create`, `write`, `truncate`, `cp` (+ `-T`/`-r`/`--from-volume`/`--progress`/`--dry-run`/`-n`), `rm`, `mv`, `delete` |
| **Volume admin** | `setdirty`, `reclaim-orphans` |

Detail + examples: [`docs/CLI.md`](docs/CLI.md).

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

## Read-write flow (menu-bar app)

End to end, writing NTFS in Finder via the menu-bar app + FSKit extension:

1. **Activate the extension** — launch **NTFS Mount Manager**. On first run it
   shows a short onboarding sheet describing this flow. Approve the system
   extension once in System Settings (or `systemextensionsctl developer on` for
   free personal signing).
2. **Plug in an NTFS volume** — it appears in the sidebar and mounts read-write
   through the extension.
3. **Write in Finder** — copy, rename, and delete files directly in Finder, just
   like a native disk. Changes are written straight to the NTFS volume.
4. **Eject safely** — always eject (sidebar **Eject**, or Finder) before
   unplugging so pending writes flush and the volume stays clean for Windows.

### Format & Repair (Danger Zone)

Each volume's dashboard has a visually separated **Danger Zone**:

- **Format as NTFS…** — reformats the (unmounted) device as a fresh NTFS
  filesystem via `NTFSCore.Volume.formatNTFS`. Gated by a confirmation dialog
  that names the target device. Destroys all data.
- **Repair…** — runs `NTFSCore`'s consistency audit
  (`auditAllDataRunlistsAgainstBitmap`) plus a `$Volume` dirty-flag check. If the
  volume is only flagged *dirty* (clean audit), it clears the dirty flag. **There
  is no in-place corruption repair** — if the audit finds real structural damage,
  it is reported and you are advised to run Windows `chkdsk /F`. We never claim to
  fix corruption we cannot.

See [`docs/REPAIR.md`](docs/REPAIR.md) for the manual write-validation and repair
smoke procedures.

## Repo layout

```
ntfs-tool/
├── Packages/NTFSCore/     Swift library — pure NTFS read/write/format, 269 tests
├── Extensions/NTFSFileSystem/  FSKit System Extension
├── Apps/NTFSMountManager/      SwiftUI menu-bar app
├── Tools/ntfsctl/         Command-line tool (18 subcommands)
├── docs/
│   ├── CLI.md             ntfsctl walkthrough
│   └── STATUS.md          What's done, what's pending, what's next
├── CHANGELOG.md           Per-PR changes
└── CLAUDE.md              Architecture + conventions
```

## Building everything

```bash
# NTFSCore (no Xcode needed)
cd Packages/NTFSCore && swift build && swift test
# → 226 tests pass

# ntfsctl CLI (no Xcode needed)
cd Tools/ntfsctl && swift build --configuration release

# FSKit extension + menu-bar app (require Xcode)
brew install xcodegen
xcodegen generate
xcodebuild -project NTFSMountManager.xcodeproj -scheme NTFSMountManager build
```

## Build & install the app

One command produces a runnable `NTFSMountManager.app` with the FSKit system
extension embedded inside it:

```bash
./scripts/package.sh --release      # → dist/NTFSMountManager.app (ad-hoc signed)
./scripts/package.sh --release --zip # also writes dist/NTFSMountManager.zip
```

The script runs `xcodegen generate`, builds the app (which builds and embeds the
`NTFSFileSystem.systemextension`), stages it into `dist/`, and verifies the
extension is embedded. The default build is **ad-hoc signed** — it runs locally,
but to *activate* the system extension you need free personal-use signing plus
`systemextensionsctl developer on`.

Full free-signing path, clean-machine activation walkthrough, and the
notarization procedure for off-machine distribution:
**[`docs/PACKAGING.md`](docs/PACKAGING.md)**.

> CI builds both the `NTFSMountManager` and `NTFSFileSystem` Xcode schemes on
> `macos-15` (ad-hoc). Notarization is documented but not run in CI — it needs a
> paid Apple Developer account.

## Status

| Layer | Status |
|---|---|
| `ntfsctl` read commands (`info`, `scan`, `list`, `tree`, `find`, `cat`, `verify`, `dump`) | Production-ready |
| `ntfsctl` write commands (`cp` (+`--move`), `write`, `rm`, `mv`, `create`, `delete`, `truncate`) | Production-ready; validated by a full **22,419-file / 39.6 GiB** single-tree copy on a real 4 TB WD drive (`verify --deep` clean). No known per-directory capacity cap — bounded only by free clusters + MFT slots. |
| `ntfsctl` volume admin (`reclaim-orphans`, `setdirty`) | Production-ready |
| NTFS formatting | `NTFSCore.Volume.formatNTFS` — surfaced in the app's Danger Zone (**Format as NTFS**). Validated by the in-repo oracle (`MkntfsTests` asserts `auditAllDataRunlistsAgainstBitmap().isClean`) and `scripts/format-oracle.sh` against real `ntfs-3g`. |
| `NTFSCore` library | Production-ready (226 tests, full 22,419-file copy validated on a real 4 TB WD drive) |
| FSKit extension build | Builds clean |
| FSKit mount in Finder | Needs SIP-off / entitlement to validate |
| Windows `chkdsk` clean | ✅ Passed 2026-08-04 — 11,568-file copy, all stages clean, no bitmap error |

Full breakdown: [`docs/STATUS.md`](docs/STATUS.md).

## License

[MIT](LICENSE). Use it however you like.

The NTFS implementation is a clean-room Swift port from publicly-documented on-disk format specs — no GPL code incorporated. The `$UpCase` table is derived from Unicode case mappings via Swift's `String.uppercased()`; the `$AttrDef` table is derived from the public NTFS 3.1 spec.

## Contributing

Architecture notes + conventions in [`CLAUDE.md`](CLAUDE.md). For substantive work, file an issue first to align on approach. Remaining follow-ups (documented in [`docs/STATUS.md`](docs/STATUS.md)): FSKit mount validation (manual, needs SIP-off + developer mode or the FSKit entitlement — the only external gate left now that Windows `chkdsk` passes), CI workflow repair (the `.github/workflows/ci.yml` macOS jobs fail at provisioning; merges currently rely on local `swift test`), and optional polish like multi-extension `$DATA` (the file-level analogue of the shipped multi-extension `$INDEX_ALLOCATION`; not driven by any known failure).
