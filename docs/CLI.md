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

# List the root directory
sudo ntfsctl list /dev/disk10s1                 # names only
sudo ntfsctl list --long /dev/disk10s1          # with MFT record numbers + sizes

# Descend into a subdirectory by its MFT record number
sudo ntfsctl list --long /dev/disk10s1 44       # 44 is the example RECNUM of a subdirectory

# Read a file's content (by MFT record number) to stdout
sudo ntfsctl cat /dev/disk10s1 36 > /tmp/extracted.bin

# Identify content type via magic bytes (pipe through `file`)
sudo ntfsctl cat /dev/disk10s1 36 | file -

# Hex-dump the first 64 bytes
sudo ntfsctl cat /dev/disk10s1 36 | head -c 64 | hexdump -C

# Compute SHA-256
sudo ntfsctl cat /dev/disk10s1 36 | shasum -a 256

# Sanity-check the volume (sweep first ~64 MFT records, report parse errors)
sudo ntfsctl verify /dev/disk10s1

# Done — re-mount with Apple's driver so Finder works again
diskutil mount /dev/disk10s1
```

**File lookup is by MFT record number, not by path.** This is intentional — NTFS is record-oriented and there's no `chdir`/`open(path)` abstraction in the raw API. To find a file:

1. `ntfsctl list --long /dev/diskN` shows the root's children with their record numbers.
2. Descend into a subdirectory by passing its record number as the second argument.
3. Repeat until you find the file you want.

A future iteration could add a path-resolution helper (`ntfsctl ls /path/to/file`) — for now, it's record-number based.

## Writing workflow

```bash
# 1. Unmount Apple's mount (required for any write)
diskutil unmount /dev/disk10s1

# 2. Create an empty file in a parent directory
#    --parent <recnum> selects the parent dir. Default is root (5).
#    The parent directory must have a resident-only $INDEX_ROOT — see Constraints.
sudo ntfsctl create /dev/disk10s1 my-note.txt --parent 44
# Prints: "Created 'my-note.txt' at MFT record 37"  (slot number varies)

# 3. Write content. Bytes come from stdin.
echo "Hello from ntfsctl on macOS." | sudo ntfsctl write /dev/disk10s1 37

# Or write the contents of an existing file
cat /tmp/source.txt | sudo ntfsctl write /dev/disk10s1 37

# 4. Mark the volume clean so chkdsk / ntfsfix don't flag it
sudo ntfsctl setdirty /dev/disk10s1 0

# 5. Verify by reading back
sudo ntfsctl cat /dev/disk10s1 37

# 6. (Optional) Resize the file
sudo ntfsctl truncate /dev/disk10s1 37 0       # make it empty
sudo ntfsctl truncate /dev/disk10s1 37 4096    # shrink to 4096 bytes (cluster-aligned)

# 7. Delete (frees clusters + removes from parent's $I30 index)
sudo ntfsctl delete /dev/disk10s1 37

# 8. Re-mount so Finder / Apple's driver sees the changes
diskutil mount /dev/disk10s1
```

After remount, your new file appears in Finder under the parent directory. Apple's driver reads it (read-only); our `ntfsctl` wrote it. The bytes are byte-identical to what a native Windows-formatted NTFS would produce — validated against `ntfs-3g` in the project's integration tests.

### Append to an existing file

The `--offset` flag lets you write at a specific offset. The only supported offsets in v1 are `0` (rewrite) or the file's current size (append):

```bash
# Append. Use the current file size as the offset.
echo "More content" | sudo ntfsctl write /dev/disk10s1 37 --offset 5      # if existing size is 5 bytes
```

Get the current size from `ntfsctl list --long <parent>` or `ntfsctl info`.

## Subcommand reference

Run `ntfsctl <subcommand> --help` for full flag details. Summary:

| Command | Arguments | Description |
|---|---|---|
| `scan` | (no args) | List attached NTFS partitions with size + free space + serial. `--include-images` also probes `.img` files in cwd. `--long` for cluster size + MFT location. |
| `info` | `<device>` | Print volume metadata + free/used cluster counts |
| `list` | `<device> [recnum-or-path]` | List directory contents. Default = 5 (root). Pass `--long` for record numbers + sizes + namespace. Accepts a path like `/Backups` instead of a recnum. |
| `cat` | `<device> <recnum-or-path>` | Stream file bytes to stdout (chunked; no 1 GiB cap). `--offset` / `--length` for partial reads. |
| `verify` | `<device>` | Full MFT sweep + orphan + dangling-$I30 detection. Extension-record aware: reports `Extension records: N (linked)` and treats v0.5-migration extension records (those with a non-zero base file reference) as legitimate, not orphans; surfaces a separate `leaked extension (base record free)` error class. `--max-records N` (default 0 = auto-bounded by `$MFT`'s logical size). `--verbose` for per-record details. **`--deep`** additionally runs a whole-volume runlist↔`$Bitmap` + double-allocation sweep — catches free-but-referenced / out-of-range / double-allocated clusters the plain check can't see (the v0.5 multi-extent / portability diagnostic). **Read-only.** |
| `dump` | `<device> <path>` | Read-only deep dump of ONE file's unnamed `$DATA`: MFT record identity (base vs migrated/`$ATTRIBUTE_LIST`), `$DATA` header (resident vs non-resident, real/allocated/initialized sizes, lastVCN), the decoded runlist as an extent table with each extent's `$Bitmap` status (`ALLOCATED` / `FREE(!)` / `OUT_OF_RANGE(!)` / `OVERLAPS_RESERVED(!)`), and a final `runlist OK` / `runlist FAULTY` verdict. `--verbose` for per-cluster detail. The single-file companion to `verify --deep`; shares the exact same audit logic. **Read-only.** |
| `create` | `<device> <name>` | Create empty file in parent dir. `--parent <recnum>` (default 5), `--directory` for folder. Auto-promotes small dirs to LARGE_INDEX on overflow. |
| `cp` | `<src> <device> <dest>` | Bidirectional host↔volume copy. `--from-volume` to invert direction. `-r` recursive. `-T`/`--no-target-directory` merges a directory source's contents into an existing dest dir (instead of nesting). `--progress` / `--dry-run` / `-n` (no-clobber) / `-v` / `--no-free-check`. |
| `write` | `<device> <recnum-or-path>` | Write stdin bytes to file. `--offset N`: 0 (rewrite) / file size (append) / `0 < N ≤ size-bytes.count` (in-place mid-file patch). `--from-file <path>` streams from a host file. |
| `rm` | `<device> <recnum-or-path>` | Delete a file or directory. `-r` recursive. `-v` verbose. |
| `mv` | `<device> <src-path> <dest-path>` | Rename or move (with auto-create of intermediate destination dirs). |
| `truncate` | `<device> <recnum> <newSize>` | Resize file to any byte-precise size (shrink only; growing requires `write`). |
| `delete` | `<device> <recnum>` | Single-record delete by recnum. Frees clusters + removes from parent's $I30. Refuses reserved records 0-15. (Prefer `rm` for path-based use.) |
| `setdirty` | `<device> <0\|1>` | Toggle the $VOLUME_INFORMATION dirty bit |
| `reclaim-orphans` | `<device>` | Sweep MFT for orphaned BASE records (IN_USE=1 but unreachable from root) and clear them. Dry-run by default — pass `--confirm` to actually clean. `-v` for per-orphan name/parent details. Native equivalent of `ntfsfix` / `chkdsk /f` for orphan recovery. **Extension-record safe:** never frees a v0.5-migration extension record (a record holding a live file's migrated `$DATA` / `$INDEX_ALLOCATION`) — freeing one would corrupt the base file; leaked extensions are reported with a `chkdsk /f` recommendation, not auto-freed. |

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

(A `find`-style recursive walker is future work — for now you walk by hand or write a shell loop.)

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

**Per-leaf cap reminder:** v1's LARGE_INDEX support has no leaf split. If you're copying many files into a single fresh directory, expect ~30-50 files per directory before hitting `unsupportedFeature(...leaf full)`. Existing Windows-formatted volumes typically already have multi-leaf trees so this matters less for inserts into pre-existing folders.

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

### `create` into LARGE_INDEX parents — per-leaf cap

`create` (and `cp`'s internal create) now descends `$INDEX_ALLOCATION` and inserts into the correct INDX leaf. Real-world directories with hundreds of entries work as long as the specific leaf the new key sorts into still has slack space (~50 entries per typical 4 KiB INDX block).

If the target leaf is fully packed, you'll see:

```
unsupportedFeature(description: "LARGE_INDEX leaf full (used X / allocated Y, needed Z) — leaf split not yet implemented")
```

**Workaround:** create files inside a different (less-full) subdirectory until leaf split is implemented (see [`docs/STATUS.md`](STATUS.md) engineering follow-up #2). Or for fresh directories created via `cp -r`, copy at most ~30-40 files per directory in v1.

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

### "unsupportedFeature: parent directory has LARGE_INDEX"

Your parent dir has too many entries. Use a smaller subdirectory. See [Constraints](#constraints-and-known-limitations).

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
