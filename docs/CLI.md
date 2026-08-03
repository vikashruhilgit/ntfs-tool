# `ntfsctl` — Command-Line Guide

Complete reference for reading and writing NTFS volumes via `ntfsctl`. Works on any NTFS device (USB stick, external HDD, disk image) without needing the FSKit extension to be installed.

## Contents

- [Setup](#setup)
- [Important: the mount/unmount dance](#important-the-mountunmount-dance)
- [Reading workflow](#reading-workflow)
- [Writing workflow](#writing-workflow)
- [Subcommand reference](#subcommand-reference)
- [Common task recipes](#common-task-recipes)
- [Constraints and known limitations](#constraints-and-known-limitations)
- [Troubleshooting](#troubleshooting)

## Setup

### Build

```bash
cd Tools/ntfsctl
swift build
```

The binary lands at `Tools/ntfsctl/.build/debug/ntfsctl`.

For a release build (smaller, faster):

```bash
cd Tools/ntfsctl
swift build --configuration release
# Binary: .build/release/ntfsctl
```

### Put it on your PATH (optional but recommended)

```bash
# Pick one location (the symlink approach is easiest to update)
ln -s "$(pwd)/.build/debug/ntfsctl" /usr/local/bin/ntfsctl
```

Now you can type `ntfsctl` from anywhere. The examples below assume this is done.

### Verify

```bash
ntfsctl --help
ntfsctl info --help
```

## Important: the mount/unmount dance

macOS auto-mounts NTFS volumes via Apple's built-in read-only driver as soon as you plug them in. **That mount holds an exclusive lock on the raw device**, so `ntfsctl` (which operates on the raw device) can't open it while Apple's mount is active.

You must unmount before using `ntfsctl`:

```bash
diskutil unmount /dev/disk10s1            # release Apple's mount
sudo ntfsctl <subcommand> /dev/disk10s1   # do your work
diskutil mount /dev/disk10s1              # re-mount so Finder works again
```

The device stays plugged in. `diskutil unmount` only releases the filesystem-level mount; the device itself remains accessible.

**`sudo` is required** for raw block-device access on macOS. `ntfsctl` opens `/dev/diskN` directly, which is root-only.

## Reading workflow

```bash
# Find your NTFS device. Look for a slice with type "Microsoft Basic Data".
diskutil list

# Release Apple's mount (assume the device is /dev/disk10s1 — yours will differ)
diskutil unmount /dev/disk10s1

# Volume metadata
sudo ntfsctl info /dev/disk10s1

# List a directory by PATH (the primary form)
sudo ntfsctl list /dev/disk10s1                 # root, names only
sudo ntfsctl list --long /dev/disk10s1          # root, with sizes + record numbers
sudo ntfsctl list --long /dev/disk10s1 /Photos  # a subdirectory by path

# Read a file's content by PATH to stdout
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg > /tmp/extracted.jpg

# Identify content type via magic bytes (pipe through `file`)
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg | file -

# Hex-dump the first 64 bytes
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg | head -c 64 | hexdump -C

# Compute SHA-256
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg | shasum -a 256

# Sanity-check the volume (full MFT sweep + orphan detection)
sudo ntfsctl verify /dev/disk10s1

# Done — re-mount with Apple's driver so Finder works again
diskutil mount /dev/disk10s1
```

**Files and directories are addressed by path by default** (e.g. `/Photos/vacation.jpg`), resolved from the volume root. Every targeting subcommand (`list`, `tree`, `find`, `cat`, `dump`, `create`, `write`, `truncate`, `rm`, `mv`, `delete`) accepts a path.

The legacy MFT-record-number form is still available where it's useful — pass `--recnum` (or, for `create`, `--parent-recnum`) to interpret the argument as a record number instead of a path. A bare argument is **always** a path, so a file literally named `38` targets the path `/38`, never record 38.

## Writing workflow

```bash
# 1. Unmount Apple's mount (required for any write)
diskutil unmount /dev/disk10s1

# 2. Create an empty file in a parent directory (by path).
#    --parent <path> selects the parent dir (default /). Intermediate
#    directories are NOT auto-created by `create` — use `cp` for that, or
#    create each level. Pass --parent-recnum for the legacy numeric form.
sudo ntfsctl create /dev/disk10s1 my-note.txt --parent /Notes

# 3. Write content. Bytes come from stdin.
echo "Hello from ntfsctl on macOS." | sudo ntfsctl write /dev/disk10s1 /Notes/my-note.txt

# Or write the contents of an existing file
cat /tmp/source.txt | sudo ntfsctl write /dev/disk10s1 /Notes/my-note.txt

# 4. Mark the volume clean so chkdsk / ntfsfix don't flag it
sudo ntfsctl setdirty /dev/disk10s1 0

# 5. Verify by reading back
sudo ntfsctl cat /dev/disk10s1 /Notes/my-note.txt

# 6. (Optional) Resize the file
sudo ntfsctl truncate /dev/disk10s1 /Notes/my-note.txt 0       # make it empty
sudo ntfsctl truncate /dev/disk10s1 /Notes/my-note.txt 4096    # shrink to 4096 bytes

# 7. Delete (frees clusters + removes from parent's $I30 index)
sudo ntfsctl rm /dev/disk10s1 /Notes/my-note.txt

# 8. Re-mount so Finder / Apple's driver sees the changes
diskutil mount /dev/disk10s1
```

> For bulk host → volume copies (a whole folder tree, multi-GB files, progress
> reporting), use `cp` instead of `create` + `write` — see [Recursive copy from
> host to NTFS](#recursive-copy-from-host-to-ntfs). The create/write/truncate
> primitives above are for surgical single-file edits.

After remount, your new file appears in Finder under the parent directory. Apple's driver reads it (read-only); our `ntfsctl` wrote it. The bytes are byte-identical to what a native Windows-formatted NTFS would produce — validated against `ntfs-3g` in the project's integration tests.

### Append to / patch an existing file

The `--offset` flag selects where the write lands. Three modes are supported:

- `--offset 0` (default) — rewrite the file from the start.
- `--offset <currentSize>` — append.
- `0 < --offset N` with `N + bytes ≤ currentSize` — in-place mid-file patch (no allocation, no MFT touch).

Writes that *extend* past the current size (other than a pure append) are not supported — use `--from-file` with a full-size payload, or `truncate` then `write`.

```bash
# Append. Use the current file size as the offset.
echo "More content" | sudo ntfsctl write /dev/disk10s1 /Notes/my-note.txt --offset 5   # if existing size is 5 bytes
```

Get the current size from `ntfsctl list --long <parent>` or `ntfsctl info`.

## Subcommand reference

Run `ntfsctl <subcommand> --help` for full flag details. Summary:

| Command | Arguments | Description |
|---|---|---|
| `scan` | (no args) | List attached NTFS partitions with size + free space + serial. `--include-images` also probes `.img` files in cwd. `--long` for cluster size + MFT location. |
| `info` | `<device>` | Print volume metadata + free/used cluster counts |
| `list` | `<device> [path-or-recnum]` | List directory contents. Default = root (`/`). Accepts a path like `/Backups` (primary) or a bare MFT record number. Pass `--long` for record numbers + sizes + namespace. |
| `tree` | `<device> [path]` | Recursively render a directory as an indented `/usr/bin/tree`-style listing (`├── `, `└── `, `│   `), ending with a blank line and an `N directories, M files` summary. Default target = root (`/`); `--depth N` bounds the descent. The bare argument is a **path** — pass `--recnum` for the MFT-record-number form. Like `list`, it is a faithful view of the `$I30` index, so walking the root shows the NTFS metafiles (`$MFT`, `$Extend`, …) and the root's `.` self-entry; only DOS 8.3 aliases are collapsed. An unreadable directory renders as an inline `[error: …]` line and does not abort the rest of the render. **Read-only.** |
| `find` | `<device> [path] --name <glob>` | Recursively search a directory and print the full path of every entry whose **name** matches the glob — `find -name` semantics (not `-path`), case-insensitive, which is the right default for NTFS. `--type f` restricts to files, `--type d` to directories; `--depth N` bounds the descent; default target = root (`/`), `--recnum` for the numeric form — note that with `--recnum <N>` printed paths are rendered relative to the search root with a leading `/`, so they look absolute but only genuinely are when `N` is the volume root (5), since there is no reverse record-number-to-path lookup. Unreadable directories are reported on stderr and do not abort the search. Note the search root itself is never a candidate, and a target that resolves but cannot be walked (e.g. a file) reports on stderr and exits 0 — only an unresolvable target is a usage error (exit 64). **Read-only.** |
| `cat` | `<device> <recnum-or-path>` | Stream file bytes to stdout (chunked; no 1 GiB cap). `--offset` / `--length` for partial reads. |
| `verify` | `<device>` | Full MFT sweep + orphan + dangling-$I30 detection. Extension-record aware: reports `Extension records: N (linked)` and treats v0.5-migration extension records (those with a non-zero base file reference) as legitimate, not orphans; surfaces a separate `leaked extension (base record free)` error class. `--max-records N` (default 0 = auto-bounded by `$MFT`'s logical size). `--verbose` for per-record details. **`--deep`** additionally runs a whole-volume runlist↔`$Bitmap` + double-allocation sweep — catches free-but-referenced / out-of-range / double-allocated clusters the plain check can't see (the v0.5 multi-extent / portability diagnostic). **Read-only.** |
| `dump` | `<device> <path>` | Read-only deep dump of ONE file's unnamed `$DATA`: MFT record identity (base vs migrated/`$ATTRIBUTE_LIST`), `$DATA` header (resident vs non-resident, real/allocated/initialized sizes, lastVCN), the decoded runlist as an extent table with each extent's `$Bitmap` status (`ALLOCATED` / `FREE(!)` / `OUT_OF_RANGE(!)`, plus an advisory `OVERLAPS_RESERVED(!)` per-extent flag), and a final `runlist OK` / `runlist FAULTY` verdict. `--verbose` for per-cluster detail. The single-file companion to `verify --deep`: both share the same audit, and the pass/fail verdict covers exactly free-but-referenced / out-of-range / double-allocated clusters. Reserved-region overlap is reported only as the advisory per-extent flag and is NOT part of either command's verdict, so the two always agree. **Read-only.** |
| `create` | `<device> <name>` | Create an empty file (or `--directory`) in a parent dir. `--parent <path>` (default `/`); `--parent-recnum N` for the legacy numeric form. Per-directory capacity is bounded only by free clusters + MFT slots (auto leaf-split / height-grow / `$ATTRIBUTE_LIST` migration). |
| `cp` | `<src> <device> <dest>` | Bidirectional host↔volume copy. `--from-volume` to invert direction. `-r` recursive. `-T`/`--no-target-directory` merges a directory source's contents into an existing dest dir (instead of nesting). `--move`/`--remove-source` turns the copy into a cross-device cut — each source is deleted **after** its own copy succeeds (skipped/failed sources are preserved; `--dry-run` previews the deletions). `--progress` / `--dry-run` / `-n` (no-clobber) / `-v` / `--no-free-check`. |
| `write` | `<device> <recnum-or-path>` | Write stdin bytes to file. `--offset N`: 0 (rewrite) / file size (append) / `0 < N ≤ size-bytes.count` (in-place mid-file patch). `--from-file <path>` streams from a host file. |
| `rm` | `<device> <path-or-recnum>` | Remove a file or directory tree. `-r`/`--recursive` for directories; **`--force` is required** for non-empty recursive deletes; `--dry-run` previews; `-v` verbose; `--recnum` for the numeric form. `rm -r /` and reserved records (0-15) are rejected. |
| `mv` | `<device> <src-path> <dest-path>` | Rename or move within a single volume (with auto-create of intermediate destination dirs). Existing destination: default **replaces** it (delete-then-atomic-rename; a populated-directory destination is refused), `-n`/`--no-clobber` **skips** (no-op, exit 0). The source is never lost even if a replace aborts mid-flight (the underlying rename is insert-before-remove). |
| `truncate` | `<device> <path-or-recnum> <newSize>` | Resize a file to any byte-precise size (shrink only; growing requires `write`). `--recnum` for the numeric form. |
| `delete` | `<device> <path-or-recnum>` | Low-level single-FILE delete (path by default, `--recnum` for the numeric form). Frees clusters + removes from parent's `$I30`. Refuses reserved records 0-15 and directories. (Prefer `rm` for everyday use / directory trees.) |
| `setdirty` | `<device> <0\|1>` | Toggle the $VOLUME_INFORMATION dirty bit |
| `reclaim-orphans` | `<device>` | Sweep MFT for orphaned BASE records (IN_USE=1 but unreachable from root) and clear them. Dry-run by default — pass `--confirm` to actually clean. `-v` for per-orphan name/parent details. Native equivalent of `ntfsfix` / `chkdsk /f` for orphan recovery. **Extension-record safe:** never frees a v0.5-migration extension record (a record holding a live file's migrated `$DATA` / `$INDEX_ALLOCATION`) — freeing one would corrupt the base file; leaked extensions are reported with a `chkdsk /f` recommendation, not auto-freed. |

## Formatting — not provided (format on Windows)

`ntfsctl` operates on **existing** NTFS volumes; it does not create them.
**Format the drive once on Windows** (right-click → Format → NTFS) or with
`mkntfs-3g` on Linux, then use `ntfsctl` to read/write it.

A pure-Swift formatter (`ntfsctl mkntfs`) was prototyped in v0.6 and
**removed in v0.7.2**: hardware testing showed the volumes it produced were
read-only-mountable by NTFSCore's own reader but **rejected as corrupt by
Windows and macOS `livefiles_ntfs`**. A spec-faithful NTFS formatter — correct
BPB geometry, conventional `$MFT`/`$MFTMirr` placement, real boot code, and a
valid `$Secure` with `$SDS`/`$SDH`/`$SII` B-trees and security-descriptor
hashes — is an effort on the scale of `ntfsprogs`' `mkntfs.c` and out of scope
for this tool. A half-correct formatter that yields "valid to us, corrupt to
Windows" volumes is worse than none, so it was removed. (An internal,
clearly-labelled NTFSCore-only fixture builder remains for the test suite; it
is not user-accessible and is not a portable formatter.)

## Common task recipes

### Copy a file FROM the NTFS volume TO macOS

```bash
diskutil unmount /dev/disk10s1
# Find the file's record number first via ntfsctl list --long ...
sudo ntfsctl cat /dev/disk10s1 36 > ~/Downloads/extracted-file.exe
diskutil mount /dev/disk10s1
```

### Copy a file FROM macOS TO the NTFS volume

```bash
diskutil unmount /dev/disk10s1
# Find or create the destination file's MFT record
sudo ntfsctl create /dev/disk10s1 my-copy.txt --parent 44
# Returns: "Created 'my-copy.txt' at MFT record 37"
cat ~/Documents/source.txt | sudo ntfsctl write /dev/disk10s1 37
sudo ntfsctl setdirty /dev/disk10s1 0
diskutil mount /dev/disk10s1
```

### Bulk-list all files on the volume

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl list --long /dev/disk10s1                                # root
# Descend either by record number or by path (path form is friendlier):
sudo ntfsctl list --long /dev/disk10s1 /WD\ -\ Software
sudo ntfsctl list --long /dev/disk10s1 /gallery/2024
diskutil mount /dev/disk10s1
```

(Or use `ntfsctl tree <device> /Photos` for a recursive listing and `ntfsctl find <device> / --name '*.jpg'` to locate a file by name anywhere on the volume — see the Subcommand reference.)

### Recursive copy from host to NTFS

```bash
diskutil unmount /dev/disk10s1

# Single file into an existing directory (auto-creates intermediates):
sudo ntfsctl cp ~/photo.jpg /dev/disk10s1 /Backups/Photos/

# Recursive: copy an entire host tree:
sudo ntfsctl cp -r ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

# Big-file streaming happens automatically — no separate flag needed for cp:
sudo ntfsctl cp ~/Movies/big.mp4 /dev/disk10s1 /Videos/

diskutil mount /dev/disk10s1
```

`cp` resolves the destination path: trailing slash (or matching an existing directory) treats it as the parent and appends the source basename; otherwise it copies under the given name. Intermediate destination directories are auto-created.

#### Merge a directory's contents into an existing dir (`-T` / `--no-target-directory`)

By default, `cp` follows POSIX nesting rules. If the destination path does **not** exist, the source lands there directly (`cp -r src/Android /dev/disk10s1 /gallery/Android` → `/gallery/Android`). If the destination directory **already exists**, the source is nested under `dest/<sourceBasename>` — so re-running `cp -r src/Android /dev/disk10s1 /gallery/Android` once `/gallery/Android` exists yields a surprising `/gallery/Android/Android`. Pass `-T`/`--no-target-directory` to instead **merge the source's contents into the destination directory itself**:

```bash
# MERGE: source/Android's children land directly inside /gallery/Android.
# (NOT /gallery/src/Android, NOT /gallery/Android/Android.)
sudo ntfsctl cp -rT ~/Desktop/s21fe-backup/Android /dev/disk10s1 /gallery/Android
```

So `source/Android` → `dest/Android`: files already present on the volume are merged with the incoming tree rather than the whole source folder being dropped inside as a new sub-level. `-T` only merges **directory** sources — a single-file source still nests under the destination.

#### Conflict policy on merge: replace (default) vs skip (`-n`)

When a merge (or any `cp`) hits a destination file that already exists, the per-file policy decides what happens:

- **default = replace** — the existing destination file is deleted and recreated from the host source. Use this to refresh a backup with newer content.
- **`-n` / `--no-clobber` = skip** — existing destination files are left untouched; only files that don't yet exist are created. `-n` is the **safe re-run mode**: if a big `cp -rT` was interrupted, re-running it with `-n` fills in only the missing files and never touches what already copied.

```bash
# First run: full merge, replacing any stale files.
sudo ntfsctl cp -rT ~/Desktop/s21fe-backup /dev/disk10s1 /gallery/s21fe-backup

# Interrupted? Re-run safely — only missing files are added, existing ones kept.
sudo ntfsctl cp -rTn ~/Desktop/s21fe-backup /dev/disk10s1 /gallery/s21fe-backup
```

#### Preflight summary line

Before any bytes move (in both real and `--dry-run` runs), `cp` prints a one-line summary of where the source will land, so you can confirm the resolved destination before committing:

```
→ creating /gallery/s21fe-backup (new)
→ nesting under /gallery/s21fe-backup (dest exists; pass -T to merge)
→ merging into /gallery/s21fe-backup (existing dir; conflicts: replace)
```

The third form also reports the active conflict policy (`replace` or `skip`). Combine with `--dry-run` to preview a merge without writing anything.

#### Backup workflow example

```bash
diskutil unmount /dev/disk10s1

# Mirror a phone backup folder into an existing /gallery/s21fe-backup dir,
# merging contents and refreshing changed files:
sudo ntfsctl cp -rT ~/Desktop/s21fe-backup /dev/disk10s1 /gallery/s21fe-backup

# Re-run later to top up only new files (safe, skips existing):
sudo ntfsctl cp -rTn ~/Desktop/s21fe-backup /dev/disk10s1 /gallery/s21fe-backup

diskutil mount /dev/disk10s1
```

**Per-directory capacity:** there is no fixed cap. `create` / `cp` perform automatic leaf split, B-tree height growth, and `$ATTRIBUTE_LIST` migration as a directory grows, so a single directory is bounded only by free clusters + free MFT slots. Validated on real hardware: a **22,419-file** tree copied into one directory, `verify --deep` clean. (The old ~30-50-files-per-directory limit was a v1 leaf-split gap, lifted across v0.4–v0.7.1 — see [Constraints](#create-into-large_index-parents--per-directory-capacity).)

### Move instead of copy (`cp --move`) — cross-device cut

`cp --move` (alias `--remove-source`) keeps the same copy semantics but turns each copy into a **cut**: after a file's copy SUCCEEDS, its source is deleted. The deletion is per-file and strictly post-success — a file that was **skipped** (a `-n` collision or a non-regular source) or that **failed** keeps its source. With `-r`, an emptied source directory is removed depth-first only after *all* its children moved; a directory that still holds a skipped or failed child is preserved.

- **host → volume** deletes the host source file after the volume write succeeds.
- **volume → host** (`--from-volume --move`) deletes the volume source (via the extension-record-aware delete) after the pull succeeds; the device is opened writable in this case.
- **`--dry-run --move`** previews and is inert — it prints what *would* be deleted but writes and deletes nothing.

The summary reports the moved-file count and freed bytes (`moved: deleted N source file(s), freed X`).

> **Safety rule:** a source is only ever deleted *after* its own copy succeeds. Nothing is deleted speculatively, and `--dry-run` previews the deletions without touching anything.

```bash
diskutil unmount /dev/disk10s1

# Cut a single host file onto the volume (host copy is removed after success):
sudo ntfsctl cp --move ~/photo.jpg /dev/disk10s1 /Backups/Photos/

# Recursively move a whole host tree onto the volume, emptying the source:
sudo ntfsctl cp -r --move ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

# Pull-and-cut: move files OFF the volume back to the host (deletes volume sources):
sudo ntfsctl cp -r --from-volume --move /Backups/MyPhone /dev/disk10s1 ~/restored/

# Preview a move without writing or deleting anything:
sudo ntfsctl cp -r --move --dry-run ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

diskutil mount /dev/disk10s1
```

### Rename / relocate within a volume (`mv`) — skip vs replace

`mv` renames or relocates a file or directory **within a single NTFS volume** (intermediate destination directories are auto-created). For a cross-device move (host ↔ volume) use `cp --move` instead.

When the destination name already exists:

- **default = replace** — the existing destination is deleted, then the source is atomically moved onto its name. Replace applies to an existing file or an EMPTY directory; a **populated** directory destination is refused (it would orphan its contents).
- **`-n` / `--no-clobber` = skip** — the existing destination is left untouched and `mv` exits 0 without moving.

Replace is transactional: the underlying `Volume.rename` is insert-before-remove, so the **source is never lost even if the move aborts mid-flight**. Case-only renames and exact self-moves are handled as no-data-loss special cases.

```bash
diskutil unmount /dev/disk10s1

# Simple rename in the same directory:
sudo ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

# Relocate into another directory (auto-creates /Archive if missing):
sudo ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Archive/final.txt

# Replace an existing destination (default): /Backups/final.txt is deleted, draft moved onto it:
sudo ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

# Don't clobber an existing destination — skip and exit 0:
sudo ntfsctl mv -n /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

diskutil mount /dev/disk10s1
```

### Copy / move / skip / replace capability matrix

The complete model across copy vs move, the two transfer directions, and the conflict policies:

| Operation | Copy (keep source) | Move (delete source after success) |
|---|---|---|
| host → volume | `cp` | `cp --move` |
| volume → host | `cp --from-volume` | `cp --from-volume --move` |
| within one volume (rename/relocate) | (n/a — same device) | `mv` |
| merge a directory's contents into an existing dir | `cp -T` | `cp -T --move` |
| conflict: replace existing (default) | `cp` / `mv` | `cp --move` / `mv` |
| conflict: skip existing | `cp -n` / `mv -n` | `cp --move -n` / `mv -n` |

Safety guarantees that hold across the whole matrix:

- A source is **only ever deleted after its copy/move succeeds** — skipped (`-n`) and failed transfers keep their source.
- `cp --move --dry-run` **previews** the deletions and is completely inert.
- `mv` replace is **transactional**: the source is never lost even if the move aborts mid-flight (insert-before-remove rename).

### Validate a volume's structural integrity

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl info /dev/disk10s1              # boot sector + bitmap parses
sudo ntfsctl verify /dev/disk10s1            # MFT records parse, 0 errors
diskutil mount /dev/disk10s1
```

For external validation via `ntfsfix` (the canonical Linux NTFS fsck), use Docker:

```bash
diskutil unmount /dev/disk10s1
# Copy device contents to an image first (or operate on an existing .img directly)
sudo cp /dev/disk10s1 /tmp/volume-snapshot.img
diskutil mount /dev/disk10s1

docker run --rm -v /tmp:/io --privileged debian:bookworm-slim bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq ntfs-3g >/dev/null &&
  ntfsfix --no-action /io/volume-snapshot.img
'
```

### Diagnose multi-extent / portability faults (`dump` + `verify --deep`)

These two commands are the **read-only diagnostics for the open WD-drive
multi-extent `$DATA` investigation**: files whose unnamed `$DATA` spans multiple
extents read byte-exact with `ntfsctl cat` but raise `Input/output error` in
macOS's native NTFS driver. The leading hypothesis is an over-free that left
clusters belonging to committed files marked FREE in `$Bitmap` (or reused by
another file), which a spec-strict reader rejects. Both commands cross-check
each file's runlist against `$Bitmap` and are **strictly read-only — safe to run
on a live, mounted drive** (they open the device with the read-only initializer
and call no mutating APIs).

- **`dump <device> <path>`** inspects ONE suspect file in detail.
- **`verify --deep <device>`** sweeps the WHOLE volume for the same fault classes.

#### Inspect one failing file — `dump <path>`

```bash
diskutil unmount /dev/disk10s1
# Point dump at the exact file the native driver chokes on.
sudo ntfsctl dump /dev/disk10s1 "/Backups/big-fragmented.bin"
diskutil mount /dev/disk10s1
```

Example output for a healthy multi-extent file (verdict `runlist OK`):

```
File:                     /Backups/big-fragmented.bin
MFT record:               73
  Base record:            yes
  Migrated ($ATTR_LIST):  no
$DATA:
  Storage:                non-resident
  realSize:               4980736 bytes (4.75 MiB)
  allocatedSize:          4980736 bytes (4.75 MiB)
  initializedSize:        4980736 bytes (4.75 MiB)
  lastVCN:                1215

Extents (3):
  vcn_start    vcn_count    startLCN         bitmap status
  ----------------------------------------------------------------------
  0            500          262144           ALLOCATED 500
  500          400          524288           ALLOCATED 400
  900          316          131072           ALLOCATED 316

Summary:
  Clusters referenced:    1216
  Free but referenced:    0
  Out of range:           0

runlist OK
```

Example output for the actual fault — a cluster the file still references but
`$Bitmap` marks FREE (the over-free smoking gun). Per-extent status flags the
bad run and `dump` exits non-zero:

```
File:                     /Backups/big-fragmented.bin
MFT record:               73
  Base record:            yes
  Migrated ($ATTR_LIST):  no
$DATA:
  Storage:                non-resident
  realSize:               4980736 bytes (4.75 MiB)
  allocatedSize:          4980736 bytes (4.75 MiB)
  initializedSize:        4980736 bytes (4.75 MiB)
  lastVCN:                1215

Extents (3):
  vcn_start    vcn_count    startLCN         bitmap status
  ----------------------------------------------------------------------
  0            500          262144           ALLOCATED 500
  500          400          524288           ALLOCATED 399  FREE(!) 1
  900          316          131072           ALLOCATED 316

Summary:
  Clusters referenced:    1216
  Free but referenced:    1
  Out of range:           0

runlist FAULTY — 1 anomaly(ies):
  - extent VCN 500 LCN 524288+400: 1 cluster(s) FREE in $Bitmap but referenced
```

An `OUT_OF_RANGE(!)` status (and an `out of volume range` anomaly) appears the
same way when a run points at an LCN `>=` the volume's cluster count — the other
class of corruption a spec-strict reader rejects with an I/O error.

A run may also show an advisory `OVERLAPS_RESERVED(!)` flag in its per-extent
status column when it lands inside a reserved region (`$MFT` / `$MFTMirr` /
`$Bitmap`). This is informational only: reserved-region detection is
best-effort/approximate, so it is **not** part of the `runlist OK` / `runlist
FAULTY` verdict and never makes `dump` exit non-zero on its own. `verify --deep`
treats it the same way, so the two commands always agree — the verdict covers
exactly free-but-referenced / out-of-range / double-allocated clusters.

#### Sweep the whole volume — `verify --deep`

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl verify --deep /dev/disk10s1
diskutil mount /dev/disk10s1
```

`--deep` appends a runlist/`$Bitmap` audit to the normal verify output, reporting
the five counts (files checked, runlist clusters verified, free-but-referenced,
out-of-range, double-allocated). Clean volume:

```
Boot sector:              OK  (NTFS)
MFT sweep (records 0..255):
  In use (total):         42
    User (>=16):          26
    Directories:          7
  Free:                   214
  Parse errors:           0
Directory tree (from root):
  Reachable user files:   26
  Extension records:      0 (linked)
  Orphans (base record in MFT, not in tree): 0
  Leaked extensions (base record free): 0
  Dangling ($I30 entry but MFT slot free): 0
Deep runlist/$Bitmap audit:
  Files checked:                26
  Runlist clusters verified:    4096
  Free-but-referenced clusters: 0
  Out-of-range clusters:        0
  Double-allocated clusters:    0
  Unreadable records:           0

Verify PASSED.
```

A volume hit by the over-free / aliasing bug — note the plain MFT sweep passes,
but the deep audit catches what it cannot see, and the run exits non-zero:

```
Deep runlist/$Bitmap audit:
  Files checked:                26
  Runlist clusters verified:    4096
  Free-but-referenced clusters: 1
  Out-of-range clusters:        0
  Double-allocated clusters:    2
  Unreadable records:           0

Verify FAILED — 0 parse, 0 orphan, 0 leaked-extension, 0 dangling, 0 enum errors — deep audit: 1 free-but-referenced, 0 out-of-range, 2 double-allocated cluster(s). Suggest running ntfsfix or chkdsk /f.
```

Add `--verbose` to list the offending record numbers and their per-record
anomaly lines, then point `dump <path>` at each one for the extent-level detail.
Workflow: `verify --deep` to find WHICH files are affected, `dump <path>` to see
WHERE in each file's runlist the fault is.

### Prove on-disk correctness independent of any NTFS driver (portability spot-check)

This is the **canonical portability spot-check**: run it when `livefiles_ntfs`
(macOS's native NTFS reader) reports `Input/output error` on a file's content —
especially above 4 GB, where `livefiles_ntfs` has a known 32-bit blockmap
limitation (see [`docs/STATUS.md` — macOS `livefiles_ntfs` >4 GB read
limitation](STATUS.md#macos-livefiles_ntfs-4-gb-read-limitation)). The recipe
proves our on-disk bytes are spec-correct in two layers: a driver-level layer
(using `ntfsctl`) and a no-driver raw layer (using `dd`, bypassing every NTFS
driver entirely). If the raw `dd`+sha layer matches the source, the data on disk
is correct no matter what `livefiles_ntfs` reports.

Take `bn.pdf` (source sha `45b9219026bb9b135c43fc213c9eabe16c0b9565`) as the
worked example.

#### Layer 1 — driver-level (via `ntfsctl`)

```bash
diskutil unmount /dev/disk10s1

# (a) Inspect the file's runlist + $Bitmap state. For bn.pdf this prints a
#     single extent at LCN 1260225, in range, $Bitmap ALLOCATED, runlist OK.
sudo ntfsctl dump /dev/disk10s1 "/WhatsApp Documents/bn.pdf"

# (b) Whole-volume runlist <-> $Bitmap sweep (free-but-referenced / out-of-range
#     / double-allocated). Confirms no structural fault across the volume.
sudo ntfsctl verify --deep /dev/disk10s1

# (c) Read the content through OUR driver and hash it. Compare to the source sha.
sudo ntfsctl cat /dev/disk10s1 "/WhatsApp Documents/bn.pdf" | shasum
# expect: 45b9219026bb9b135c43fc213c9eabe16c0b9565

diskutil mount /dev/disk10s1
```

#### Layer 2 — no-driver raw read (via `dd`)

This layer touches NO NTFS driver at all — it reads the physical clusters
straight off the block device, so a match here proves the bytes are correct on
disk regardless of `livefiles_ntfs` / `ntfsctl` / any driver.

Derive the `dd` parameters from the `ntfsctl dump` output above:

- **`skip` (first sector)** = `firstLCN × clusterSize ÷ 512`.
  For `bn.pdf`: `1260225 × 4096 ÷ 512` is the extent's first 512-byte sector
  — `10081800` in this run.
- **`count` (sectors)** = `ceil(allocatedSize ÷ 512)` (the extent's whole
  clusters in 512-byte sectors) — `1056` here.
- **`head -c <realSize>`** trims the trailing partial-cluster slack down to the
  file's exact byte length (`realSize`) — `540566` bytes here.

```bash
diskutil unmount /dev/disk10s1
sudo dd if=/dev/disk10s1 bs=512 skip=10081800 count=1056 \
  | head -c 540566 \
  | shasum
# expect: 45b9219026bb9b135c43fc213c9eabe16c0b9565
diskutil mount /dev/disk10s1
```

If layer 2's hash equals the source sha, the on-disk data is byte-exact and any
`livefiles_ntfs` EIO is a reader bug, not a write defect. (Recommended
follow-up: confirm the same above-4-GB files with `ntfs-3g` / Windows `chkdsk`,
the mature readers our writes target.)

### Reclaim orphaned MFT records left by older buggy builds

If `verify` reports orphans (records in the MFT with IN_USE=1 but not reachable from any directory), you can clean them in-place without booting Windows or Linux. Common scenario: a previous failed `cp -r` against a pre-v0.3 build that hit the leaf-split silent-orphan bug.

```bash
diskutil unmount /dev/disk10s1
# 1. See what would be reclaimed (read-only dry-run — totally safe).
sudo ntfsctl reclaim-orphans -v /dev/disk10s1
#    Prints orphan recnums + their $FILE_NAME if present, e.g.:
#    orphan recnum 72  name='IMG_2031.HEIC' parent_ref=44
#    Inspect the names — if these are files you actually want to keep,
#    DO NOT continue. They'd be reachable only through their parent's
#    $I30, which is corrupted; reclaim drops them.

# 2. Clean. Wraps in a dirty-bit transaction with fsync.
sudo ntfsctl reclaim-orphans --confirm /dev/disk10s1

# 3. Confirm
sudo ntfsctl verify /dev/disk10s1
#    Orphans should now be 0.
diskutil mount /dev/disk10s1
```

This is the native equivalent of `ntfsfix --clear-bad-sectors` / `chkdsk /f`'s orphan reclamation — same on-disk effect (clear IN_USE flag + free the bit in `$MFT.$BITMAP`), but doesn't require a Windows machine or a Linux Docker container. Use when:

- An older build of `ntfsctl` (pre-v0.3) left orphans on the drive.
- Another tool crashed mid-write and orphaned a record.
- You manually `setdirty 0`'d a volume after a partial operation.

The current build's `createFile` correctly rolls back its own orphans on failure, so a fresh `cp -r` against a clean drive should never need this. It's purely a recovery tool for inherited corruption.

### Verify our writes match Apple's reads (bit-exact)

```bash
diskutil unmount /dev/disk10s1
ours="$(sudo ntfsctl cat /dev/disk10s1 36 | shasum -a 256 | awk '{print $1}')"
diskutil mount /dev/disk10s1
apples="$(shasum -a 256 '/Volumes/My Passport/path/to/same-file.ext' | awk '{print $1}')"
echo "ours:    $ours"
echo "apples:  $apples"
[ "$ours" = "$apples" ] && echo "MATCH" || echo "DIVERGE"
```

## Constraints and known limitations

These are documented as "v1 scope" with clear pointers to where they'd be lifted in a future hardening pass. None of them prevent ordinary read/write use against typical NTFS volumes.

### `create` into LARGE_INDEX parents — per-directory capacity

`create` (and `cp`'s internal create) descends `$INDEX_ALLOCATION` and inserts into the correct INDX leaf, with automatic leaf split + height growth + multi-extension `$INDEX_ALLOCATION` migration on overflow.

**v0.7+: per-directory capacity is now bounded only by free clusters and free MFT slots on the volume.** Earlier ceilings have been lifted in successive releases:

- v0.4: `$INDEX_ROOT` multi-level split.
- v0.5: `$INDEX_ALLOCATION` migrated to an extension MFT record when it outgrows base-record slack.
- v0.5.2: leaf-split migration-catch gap closed on two formerly-uncaught call sites.
- **v0.7: multi-extension `$ATTRIBUTE_LIST`** — when the migrated `$INDEX_ALLOCATION:$I30` extension's own runlist fills its MFT record, a second extension is allocated transparently and a new entry naming it at the split VCN is appended to the base's resident `$ATTRIBUTE_LIST`. The v0.6.x `unsupportedFeature("multi-extension $ATTRIBUTE_LIST required for $INDEX_ALLOCATION:$I30 …")` error is unreachable from this code path post-v0.7.

Small (resident-only `$INDEX_ROOT`) directories are auto-promoted to LARGE_INDEX on overflow — you don't have to do this manually.

### `write` supports rewrite, append, and in-place mid-file overwrite

Three patterns:
- `offset == 0` → rewrites the file from the start (any existing content is discarded)
- `offset == existingSize` → appends
- `0 < offset` AND `offset + bytes.count ≤ existingSize` → in-place mid-file patch (no allocation, no MFT touch — fast)

Writes that EXTEND past the existing size (other than pure append) still return `unsupportedFeature` — use `--from-file` with a fresh full-size payload, OR `truncate` + `write` separately.

### `truncate` is byte-precise (shrink only)

`newSize` may be any value ≤ existing size. Non-cluster-aligned shrinks work — trailing partial clusters keep their slack (the on-disk realSize stops reads at the right byte). Growing files via `truncate` isn't supported; use `write` to extend.

### Files larger than 1 GiB

**Lifted in this iteration.** `cat` and `write --from-file` now stream in 1 MiB chunks (configurable via `--chunk-size`), so file size is bounded only by free clusters on the volume, not by RSS or any explicit cap. The `cat` (no flags) and `write --from-file <path>` paths are the streaming-safe entry points:

```bash
# Write a multi-GB video to NTFS:
sudo ntfsctl write /dev/disk10s1 /Videos/movie.mp4 --from-file ~/Movies/big.mp4

# Read it back, computing SHA-256 on the fly:
sudo ntfsctl cat /dev/disk10s1 /Videos/movie.mp4 | shasum -a 256
```

The `write` stdin path (`echo ... | ntfsctl write`) still reads stdin fully into memory before writing — practical ceiling is RSS. Prefer `--from-file` for anything over a few hundred MiB.

### `$LogFile` journaling is "dirty bit only"

After every successful mutation, `ntfsctl` clears the `$VOLUME_INFORMATION` dirty bit so `chkdsk` / `ntfsfix` treat the volume as cleanly unmounted. Full LFS (Log File Service) journal records — what would enable automatic crash recovery — are not yet implemented.

**What this means in practice:** if power is lost or the device is yanked mid-write, the volume needs manual `chkdsk /f` recovery on Windows. Clean unmount = always fine. Crash safety = requires v0.2 journaling work.

### Filename collation is approximate for non-ASCII

When `create` inserts a new entry into the parent's `$I30` index, it sorts using Swift's `localizedCaseInsensitiveCompare`. For ASCII filenames this matches Windows's `$UpCase`-driven ordering exactly. For non-ASCII filenames (accented characters, CJK, etc.) the order may differ slightly from what Windows would produce. **The volume remains structurally valid** — entries are still sorted, just possibly in a different but consistent order.

## Troubleshooting

### "cannot open /dev/diskN for reading"

Apple's auto-mount has an exclusive lock. Run `diskutil unmount /dev/diskN` first.

### `diskutil unmount` says "in use"

Something has files open on the volume. Common causes:
- Finder window showing the volume → close it
- Spotlight indexing → wait a few seconds and retry
- A terminal session with `cd /Volumes/<name>` → `cd` away first

Last resort: `diskutil unmount force /dev/diskN` — safe at this point since we're going to do read-only operations.

### "would overflow record … type 0x80 / 0xA0" or other write-path `unsupportedFeature`

LARGE_INDEX directories of any size are supported (auto leaf-split / height-grow / `$ATTRIBUTE_LIST` migration), so a full parent directory is no longer a limitation. If you still hit an `unsupportedFeature` on a write, capture the full message plus `ntfsctl dump <path>` / `ntfsctl info` output and open an issue — it likely points at a genuinely pathological on-disk shape, not a per-directory cap.

### `verify` reports errors

Paste the error output. Specific failure modes:
- **"Orphans (base record in MFT, not in tree): N"** → BASE records allocated but unreachable. Run `ntfsctl reclaim-orphans -v <device>` to inspect them, then `--confirm` to clear. See the [reclaim recipe](#reclaim-orphaned-mft-records-left-by-older-buggy-builds). (Note: v0.5-migration extension records are NOT counted here — they're reported separately as `Extension records: N (linked)` and are expected, not errors.)
- **"Leaked extensions (base record free): N"** → an extension MFT record (one holding a migrated `$DATA` / `$INDEX_ALLOCATION`) whose base record is no longer in use. A real defect — run `chkdsk /f`. `reclaim-orphans` deliberately does NOT free these, since safe removal needs base-side `$ATTRIBUTE_LIST` fixup that ntfsctl doesn't do yet.
- **"Dangling ($I30 entry but MFT slot free): N"** → directory entries pointing at freed MFT slots. Requires `chkdsk /f` / `ntfsfix` — the corresponding tool isn't built into ntfsctl yet.
- **"MFT record magic is 'BAAD'"** → that record was previously marked corrupt by Windows. Not necessarily a problem for the volume overall.
- **"USA sentinel mismatch"** → hardware fault or interrupted write. Run Windows `chkdsk /f` to recover.
- **"attribute … extends past record's used region"** → likely a bug in our parser. Open an issue with the full output and the device's `info` output.
- **`verify --deep` reports "free-but-referenced" / "out-of-range" / "double-allocated" cluster(s)** → the runlist↔`$Bitmap` audit found corruption the plain MFT sweep can't see (the v0.5 multi-extent / portability fault class). `free-but-referenced` = a cluster a file still references but `$Bitmap` marks FREE (over-free); `out-of-range` = a run points past the volume's last cluster; `double-allocated` = two files claim the same cluster. All three make spec-strict readers (macOS native driver, ntfs-3g, Windows) raise `Input/output error` on the affected file. Run `ntfsctl dump <device> <path>` on each affected file (use `verify --deep --verbose` to get the record numbers) for the extent-level detail, then repair with `chkdsk /f` (Windows) or `ntfsfix`. The audit is read-only — it diagnoses, it does not repair.

### Apple's driver remounts the volume between my commands

macOS's auto-mount daemon (`diskarbitrationd`) sometimes re-mounts a volume seconds after `diskutil unmount`. Prevention:

```bash
# Suppress automatic mounting for this disk while you work on it
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool false
# (And undo after you're done.)
```

Or, simpler: run the unmount + ntfsctl + mount as a single shell pipeline so there's no window for the daemon to interfere.
