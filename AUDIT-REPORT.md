# Red Team Audit: ntfsctl CLI — Practical Readiness Assessment

**Date:** 2026-05-18
**Scope:** CLI-only readiness for real-world use (phone backups, file transfer to NTFS drives on macOS).
**Auditor mindset:** If it only works in ideal conditions, it's broken.

---

## Attack Surface

The CLI operates as a raw block device writer running as root, with no journaling, no locks,
no undo, and no confirmation prompts. Every write operation is a permanent mutation to a
filesystem that Windows will trust implicitly on next mount.

---

## Findings

### FATAL

#### 1. Volume never marked dirty before writes begin

**Location:** All write commands — `Write.swift`, `Cp.swift`, `Rm.swift`, `Mv.swift`

**Problem:** Every write command calls `setDirty(false)` at the end of a successful run.
None of them call `setDirty(true)` before the first write. The volume starts with whatever
dirty-state Windows left it in.

**Failure scenario:** ntfsctl crashes between step 2 (MFT record written) and step 3
($I30 insertion) of `createFile`. The disk now has an orphan MFT record marked IN_USE
with no $I30 entry, but dirty=0 (because Windows cleanly unmounted it). When Windows
mounts this drive next, it sees dirty=0, trusts the volume, and encounters an orphan —
which it may ignore or repair incorrectly.

**Why fatal:** A crash-mid-write with dirty=0 sends Windows into "trust this filesystem"
mode on a filesystem that's actually inconsistent. chkdsk won't auto-run. The correct
behavior is: set dirty=true before the first metadata write, set dirty=false only after
all writes are complete and consistent.

**Evidence:** `grep -rn "setDirty(true)"` returns zero results across the entire codebase.

**Fix:** In each write subcommand, call `try await volume.setDirty(true)` immediately after
opening the volume, before any mutation. ~30 min.

---

#### 2. MFT record allocation hard-caps at 2048 records — breaks on large drives

**Location:** `Packages/NTFSCore/Sources/NTFSCore/MFT.swift:28`

```swift
public func findFreeRecordNumber(maxScan: UInt64 = 2048) async throws -> UInt64 {
    for n in Self.firstUserRecord..<(Self.firstUserRecord + maxScan) {
```

**Problem:** The scan starts at record 16 and examines at most 2048 slots (up to record 2063).
On a real 4 TB WD drive used as a Windows backup drive, it's extremely likely to have more
than 2032 user files already. When all of records 16–2063 are in use, this throws `outOfSpace`
— even if records 2064–100000 are free.

**Failure scenario:** User has been using the 4 TB drive with Windows for months. It has 3000
files. They try `ntfsctl cp -r ~/PhoneBackup /dev/disk10s1 /Backups`. The free-space pre-check
passes, but the first `createFile` throws `outOfSpace` — a misleading error whose real cause
is the scan cap, not disk space.

**Why fatal:** Functional blocker for the stated use case (phone backup to a pre-existing
Windows drive). Every real drive that's been used as a Windows backup will hit this.

**Fix:** Replace linear scan with a lookup into the `$MFT $BITMAP` attribute (record 0's
$BITMAP attribute). ~1–2 days.

---

#### 3. LARGE_INDEX leaf split disabled — directories with >~50 fresh files break mid-copy

**Location:** `Packages/NTFSCore/Sources/NTFSCore/Volume.swift` — `splitLeafAndPromote` is
`@available(*, deprecated)` and not wired.

**Problem:** Each INDX block holds ~50 entries for average filename lengths. A freshly-created
directory gets one leaf. The moment the 51st file is inserted, the operation throws
`NTFSError.unsupportedFeature("leaf full")`, aborting the copy.

**Failure scenario:** `ntfsctl cp -r ~/DCIM /dev/disk10s1 /Backups` — phone DCIM folders
typically have 100–500+ photos per year subfolder. The first folder with 51+ photos causes
the command to fail mid-copy. The volume is consistent but the backup is silently incomplete.

**Why fatal:** For the phone backup use case (the stated v0.1 goal), this cap is hit on
virtually every real DCIM folder with more than a few months of photos.

**Fix:** Implement leaf split in `splitLeafAndPromote` (scaffold exists but disabled pending
second-split correctness fix). ~2–3 days.

---

### CRITICAL

#### 4. No fsync before exit — data loss on fast unplug

**Location:** `Packages/NTFSCore/Sources/NTFSCore/BlockDevice.swift` — no `synchronize()`
method in the protocol.

**Problem:** `FileHandle.write(contentsOf:)` writes to the kernel buffer cache. There is no
`fcntl(F_FULLFSYNC)` call before `setDirty(false)`. If the drive is unplugged before the
kernel flushes, dirty=0 might hit the disk while data writes are still in cache — Windows
trusts the volume but the data is gone.

**Fix:** Add `synchronize()` to the `BlockDevice` protocol; implement it in
`FileHandleBlockDevice` via `fcntl(F_FULLFSYNC, handle.fileDescriptor)`. Call before
`setDirty(false)` in every write command. ~30 min.

---

#### 5. `rm -r` can nuke all user files on the volume with one typo

**Location:** `Tools/ntfsctl/Sources/ntfsctl/Rm.swift:36–49`

**Problem:** `ntfsctl rm -r /dev/disk10s1 /` resolves "/" to root (MFT record 5).
`removeRecursive` enumerates all children of root and recursively deletes every user file.
Only at the very last step does `deleteFile(at: 5)` throw "refusing to delete reserved MFT
record 5" — but by then all user files are gone.

No confirmation prompt. No `--dry-run`. One extra `/` in a shell argument = complete
data loss.

**Fix:** Explicitly reject root (record 5) at the top of `removeRecursive`; add a
`--confirm` / `--force` flag for recursive deletes. ~2 hours.

---

#### 6. Stale size hints after writes in LARGE_INDEX directories

**Location:** `Packages/NTFSCore/Sources/NTFSCore/Volume.swift:1720` — `refreshParentI30Size`

**Problem:** After writing a file in a LARGE_INDEX directory, the `$FILE_NAME` size hints
inside the $I30 leaf are not updated. Windows Explorer, sync tools (Dropbox, OneDrive), and
photo apps will read the pre-write size. A 0-byte hint on a 3 GB video causes those tools to
skip, re-upload, or silently truncate.

**Fix:** Implement B-tree walk in `refreshParentI30Size` to find and rewrite the leaf entry.
~1–2 days (shares work with leaf-split implementation).

---

#### 7. Numeric target ambiguity — MFT recnum vs path

**Location:** `Tools/ntfsctl/Sources/ntfsctl/Write.swift:40`, `Rm.swift:39`, `Delete.swift`

```swift
if let parsed = UInt64(target) {
    recordNumber = parsed
} else { /* path resolution */ }
```

Any string that parses as UInt64 is treated as an MFT record number. A user intending to
target a file named "38" on the volume silently targets MFT record 38 instead. Typos in
recnums are unrecoverable.

**Fix:** Require an explicit `--recnum` flag to target by record number; treat all bare
arguments as paths. ~1 hour.

---

### WARNING

#### 8. No mtime/atime updates — breaks every timestamp-dependent workflow

All files written by ntfsctl have their modification time frozen at creation. Phone photos
copied to the drive show the copy time as "Date Modified" in Windows Explorer, not the
original shoot date. Adobe Lightroom, Google Photos desktop, and date-based organizers
misfile or deduplicate incorrectly.

**Fix:** Update `$STANDARD_INFORMATION.mtime` and `$FILE_NAME` timestamps in `writeFile` and
`write`. ~1 day.

---

#### 9. Bitmap loads entire $Bitmap into RAM

For an 8 TB NTFS volume with 4 KB clusters: ~2 billion clusters × 1 bit ≈ **250 MB loaded
into RAM** every time `bitmap()` is called. On a memory-constrained MacBook, this is
noticeable. On a 16 TB drive: 512 MB.

**Fix:** Implement a streaming allocator that reads the bitmap in chunks instead of loading
it whole. Medium complexity.

---

#### 10. `verify` default 4096-record cap silently passes corrupt large volumes

**Location:** `Tools/ntfsctl/Sources/ntfsctl/Verify.swift:28`

```swift
@Option(help: "Maximum MFT records to sweep. Default 4096; raise for larger volumes.")
var maxRecords: UInt64 = 4096
```

A volume with 10,000 files only has its first 4096 MFT records checked. Orphans and parse
errors in records 4097+ are silently ignored. `ntfsctl verify` can report "PASSED" on a
volume with real corruption in high-numbered records.

**Fix:** Default `maxRecords` to the actual MFT logical size (already computed in the verify
sweep as `mftLogicalRecords`). Remove the cap or make it opt-in. ~1 hour.

---

#### 11. Integration test runs `apt-get` every invocation

**Location:** `Packages/NTFSCore/Tests/NTFSCoreTests/IntegrationTests.swift:62`

Every Docker integration test does a fresh `apt-get install ntfs-3g` (~30–90 s on a slow
connection). This makes the integration test effectively never run in practice.

**Fix:** Build and push a pre-baked Docker image `ntfstool-test:latest` with ntfs-3g
already installed. Use it in the test. ~1–2 hours.

---

### WEAKNESS

#### 12. No inter-process lock on the block device

Two concurrent `ntfsctl` processes on the same device race on bitmap allocation. No `flock()`
or advisory lock prevents a user from running `ntfsctl cp` in two terminal windows
simultaneously. Both read the same cached bitmap, allocate the same clusters, and write
conflicting data.

**Fix:** Call `flock(handle.fileDescriptor, LOCK_EX)` in `FileHandleBlockDevice.init(openingFileForUpdateAt:)`. ~30 min.

---

## Top 3 Fatal Real-World Issues

1. **MFT scan cap (2048 records)** — Your real 4 TB WD drive almost certainly has >2032
   existing files. The first `ntfsctl cp` command fails with a misleading "outOfSpace" error,
   not because the disk is full but because the slot scanner gives up.

2. **LARGE_INDEX leaf split not implemented** — Any fresh directory you create with >~50
   files aborts mid-copy. DCIM subfolders routinely exceed 50 photos.

3. **Volume never marked dirty before writes** — If ntfsctl is interrupted (Ctrl+C, power
   loss, crash), the volume is left in an inconsistent state that Windows won't auto-repair.

---

## What Would Convince a Hostile Expert

- *"Show me the `setDirty(true)` call before the first metadata write."* — You can't.
- *"Copy 60 files into a fresh directory."* — Fails at file 51 with `unsupportedFeature`.
- *"Run `ntfsctl create` on the real WD drive after it already has 3000+ files."* — Throws `outOfSpace` with terabytes free.

---

## Prioritized Fixes by Real-World Impact

| Priority | Fix | Prevents | Effort |
|---|---|---|---|
| 1 | `setDirty(true)` before first write in every write command | Volume corruption on crash | 30 min |
| 2 | Replace MFT linear scan with $MFT $BITMAP lookup | Fails on drives with >2032 files | 1–2 days |
| 3 | Implement LARGE_INDEX leaf split | Fails on dirs with >~50 fresh files | 2–3 days |
| 4 | Explicit `rm -r /` guard + `--confirm` flag | Accidental full-volume wipe | 2 hours |
| 5 | `fcntl(F_FULLFSYNC)` before `setDirty(false)` | Data loss on fast unplug | 30 min |
| 6 | Update mtime/atime on write | Breaks photo library / sync tools | 1 day |
| 7 | Default `verify --max-records` to actual MFT logical size | Silent false-pass on large volumes | 1 hour |
| 8 | Require `--recnum` flag for record-number targeting | Accidental record mutation | 1 hour |
| 9 | `flock()` on write-mode device open | Concurrent-process corruption | 30 min |

---

## Verdict

**Read-only (`info`, `list`, `cat`, `scan`, `verify`):** Ready. Solid, well-tested.

**Write (`cp`, `rm`, `write`, `create`, `delete`, `mv`):** **Not ready for general use.**

For the specific phone-backup use case: if your WD drive has fewer than 2032 existing files
AND your phone's DCIM subdirectories each have fewer than 50 photos AND you use the helper
script (which handles unmount/remount correctly), it works — as `scripts/copy-s21fe-to-mypassport.sh`
proves. But the first two conditions fail for most real drives and any DCIM folder with a
year's worth of photos.

Fixes 1, 4, 5, 7, 8, and 9 are each under 2 hours. Fixes 2 and 3 are the substantive
engineering gaps. After fixes 1–5, the CLI would be safe enough for daily use on moderately
sized drives. After all nine, it would be ready for general release.
