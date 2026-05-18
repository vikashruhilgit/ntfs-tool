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
| `verify` | `<device>` | Full MFT sweep + orphan + dangling-$I30 detection. `--max-records N` (default 4096). `--verbose` for per-record details. |
| `create` | `<device> <name>` | Create empty file in parent dir. `--parent <recnum>` (default 5), `--directory` for folder. Auto-promotes small dirs to LARGE_INDEX on overflow. |
| `cp` | `<src> <device> <dest>` | Bidirectional host↔volume copy. `--from-volume` to invert direction. `-r` recursive. `--progress` / `--dry-run` / `-n` (no-clobber) / `-v` / `--no-free-check`. |
| `write` | `<device> <recnum-or-path>` | Write stdin bytes to file. `--offset N`: 0 (rewrite) / file size (append) / `0 < N ≤ size-bytes.count` (in-place mid-file patch). `--from-file <path>` streams from a host file. |
| `rm` | `<device> <recnum-or-path>` | Delete a file or directory. `-r` recursive. `-v` verbose. |
| `mv` | `<device> <src-path> <dest-path>` | Rename or move (with auto-create of intermediate destination dirs). |
| `truncate` | `<device> <recnum> <newSize>` | Resize file to any byte-precise size (shrink only; growing requires `write`). |
| `delete` | `<device> <recnum>` | Single-record delete by recnum. Frees clusters + removes from parent's $I30. Refuses reserved records 0-15. (Prefer `rm` for path-based use.) |
| `setdirty` | `<device> <0\|1>` | Toggle the $VOLUME_INFORMATION dirty bit |

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
- **"MFT record magic is 'BAAD'"** → that record was previously marked corrupt by Windows. Not necessarily a problem for the volume overall.
- **"USA sentinel mismatch"** → hardware fault or interrupted write. Run Windows `chkdsk /f` to recover.
- **"attribute … extends past record's used region"** → likely a bug in our parser. Open an issue with the full output and the device's `info` output.

### Apple's driver remounts the volume between my commands

macOS's auto-mount daemon (`diskarbitrationd`) sometimes re-mounts a volume seconds after `diskutil unmount`. Prevention:

```bash
# Suppress automatic mounting for this disk while you work on it
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool false
# (And undo after you're done.)
```

Or, simpler: run the unmount + ntfsctl + mount as a single shell pipeline so there's no window for the daemon to interfere.
