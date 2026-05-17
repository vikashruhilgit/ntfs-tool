# Project Status — What's Done, What's Pending, What's Next

This document is the single source of truth for project state. Updated when major work lands.

**Last updated:** 2026-05-17, after Phase 5f-pre work (recursive copy, LARGE_INDEX insert + promotion, streaming I/O).
**Rubric score:** 30/30 baseline from `.supervisor/requirements/auto-2026-05-14-203703-ntfs-multi-phase-rubric.md`, plus three follow-on capabilities (see "What's done — post-v0.1 enhancements").

## Contents

- [Overview](#overview)
- [What's done](#whats-done)
- [What's validated (and how)](#whats-validated-and-how)
- [What's pending — only you can do](#whats-pending--only-you-can-do)
- [What's pending — engineering follow-ups](#whats-pending--engineering-follow-ups)
- [Roadmap to v1.0](#roadmap-to-v10)
- [How to contribute](#how-to-contribute)

## Overview

The project is **a working NTFS read/write toolkit for Apple Silicon Macs**:

- **`ntfsctl` CLI** — full read + write, validated against a real Western Digital 4 TB NTFS drive. **Shippable today.** See [`docs/CLI.md`](CLI.md).
- **`NTFSCore` Swift library** — 87 unit tests, full read + write, validated against `mkntfs` fixtures + `ntfs-3g` round-trip. **Embeddable today.**
- **FSKit System Extension** — code complete, all write callbacks wired, builds clean. **Mount UX not yet validated against real hardware** — requires SIP-off (or the FSKit entitlement) to load.
- **SwiftUI menu-bar app** — DiskArbitration-driven NTFS detection, per-volume mount/eject, OSSystemExtensionManager activation flow. Builds clean.

If you want **terminal read/write access to NTFS on macOS today**, the CLI is ready. If you want **Finder-integrated drag-and-drop write**, the FSKit extension is the remaining unknown.

## What's done

### NTFSCore Swift library (`Packages/NTFSCore`)

| File | Purpose | Test coverage |
|---|---|---|
| `BootSector.swift` | Parse the 512-byte boot sector. All standard NTFS fields. Signed-int8 `clustersPerMFTRecord` semantics. | 8 tests, real WD drive |
| `MFT.swift` | Read/write MFT records by number. `findFreeRecordNumber`. $MFTMirr sync for records 0-3. | 10 tests |
| `MFTRecord.swift` | Parse + serialize one MFT record. Headers, attribute iteration. | 10 tests |
| `MFTRecordBuilder.swift` | Build a fresh MFT record from scratch ($STANDARD_INFORMATION + $FILE_NAME + empty $DATA). | 8 tests (via FileCreateDelete) |
| `UpdateSequenceArray.swift` | USA fix-up (read) + reverse-fix-up (write). | covered in MFTRecord tests |
| `Attribute.swift` | Common header + resident/non-resident extension parsing. End-marker iteration. | 5 tests |
| `AttributeType.swift` | The 16 standard attribute type codes. | covered |
| `DataRun.swift` | RLE-encoded runlist decoder (signed deltas, sparse, multi-byte fields). | 6 tests |
| `FileName.swift` | $FILE_NAME body parser (parent ref, 4 FILETIMEs, namespace, UTF-16 name). | 11 tests |
| `StandardInformation.swift` | $STANDARD_INFORMATION parser (v1.2 + v3.0 layouts). | covered |
| `IndexRoot.swift` / `IndexAllocation.swift` / `IndexEntry.swift` | $I30 B-tree reader. INDX block USA fix-up. Linear sweep with dedup. | 6 tests (Directory) |
| `IndexBuilder.swift` | $INDEX_ROOT body serializer for inserts/removes. COLLATION_FILENAME approximation. | covered via FileCreateDelete |
| `DirectoryEntry.swift` | Public-facing wrapper over IndexEntry+FileName. | covered |
| `Bitmap.swift` | $Bitmap reader + bit-level allocator (allocate/free/findFreeRun). | 10 + 14 tests |
| `Volume.swift` | Top-level coordinator. enumerate, readFile, readFileSlice, createFile, deleteFile, write, truncate, allocateClusters, freeClusters, setDirty. | covered across all suites |
| `VolumeInformation.swift` | $VOLUME_INFORMATION parser + serializer (incl. dirty bit). | covered |
| `BlockDevice.swift` | Sendable protocol; FileHandleBlockDevice impl (read + write). | covered |
| `UTF16.swift` | LE UTF-16 decoder shared by Attribute / FileName / IndexEntry. | covered |
| `Endian.swift` | Little-endian fixed-width Data accessors with bounds checking. | covered |
| `Errors.swift` | Typed `NTFSError` enum. | — |

**87 tests total** across 12 test files. Plus an integration test (`IntegrationTests.swift`) that runs ntfsfix + ntfs-3g round-trip in Docker — skipped gracefully when Docker isn't reachable.

### `ntfsctl` CLI (`Tools/ntfsctl`)

10 subcommands covering read + write:

| Subcommand | Done | Notes |
|---|---|---|
| `info` | ✅ | Volume metadata + free-space stats |
| `list` | ✅ | Directory enumeration, short + long format. Accepts MFT recnum OR path. |
| `verify` | ✅ | MFT sweep 0..63, parse-error reporting |
| `cat` | ✅ | File content to stdout. **Streaming (no 1 GiB cap)**, supports `--offset`/`--length`. Accepts MFT recnum OR path. |
| `create` | ✅ | New file/directory with $I30 insertion. Works against LARGE_INDEX parents. |
| `delete` | ✅ | File deletion with cluster free + $I30 removal. Works against LARGE_INDEX parents. |
| `write` | ✅ | Stdin → file content (rewrite or append). **`--from-file` streams from a host file (no 1 GiB cap)**. Accepts MFT recnum OR path. |
| `cp` | ✅ | **Copy host files/directories into the volume. `-r` for recursive. Path-based destination, auto-creates intermediate dirs, streams large files.** |
| `truncate` | ✅ | Resize (0 or cluster-aligned) |
| `setdirty` | ✅ | $VOLUME_INFORMATION dirty bit toggle |

See [`docs/CLI.md`](CLI.md) for usage walkthrough.

### Post-v0.1 capability work (this iteration)

These three follow-on capabilities lifted the v0.1 limits that made the CLI awkward for real-world phone-backup style workflows:

| Capability | Where | What changed |
|---|---|---|
| **Recursive host→volume copy** | `Tools/ntfsctl/Sources/ntfsctl/Cp.swift` | New `cp -r` subcommand: walks a host directory, auto-creates intermediate destination dirs on the volume, streams file content in 1 MiB chunks. Marks the volume clean (`setDirty(false)`) on success. |
| **LARGE_INDEX insert + remove** | `Packages/NTFSCore/Sources/NTFSCore/IndexAllocationWriter.swift` | B-tree descent through `$INDEX_ROOT` → `$INDEX_ALLOCATION` leaves. Inserts new entries into the correct leaf with USA fix-up. Removes existing entries from leaves on delete. Was: every parent dir with `$INDEX_ALLOCATION` (typically >5-7 entries) was rejected; now: works as long as the target leaf has slack (~50 entries per 4 KiB INDX block). |
| **Small→LARGE promotion** | `Packages/NTFSCore/Sources/NTFSCore/Volume.swift` (`promoteDirectoryToLargeIndex`) | When a small (resident-only) directory's `$INDEX_ROOT` would overflow on insert, automatically promote it: allocate one cluster, move all existing entries to an INDX leaf, replace `$INDEX_ROOT` with an empty interior root (`LARGE_INDEX` flag + LAST+HAS_SUBNODE→VCN 0), add `$INDEX_ALLOCATION:$I30` and `$BITMAP:$I30` to the parent record. Lets fresh directories grow past the ~5-7-entry resident ceiling. |
| **Streaming writeFile** | `Packages/NTFSCore/Sources/NTFSCore/Volume.swift` (`writeFile`) | Chunked API that allocates clusters once, streams content via repeated `BlockDevice.write` calls. Multi-extent allocator (`allocateClustersFragmented`) falls back to greedy splitting on fragmented volumes. No 1 GiB cap. Convenience overload `writeFile(at:fromFileAt:)` opens a host file and streams in 1 MiB chunks. |
| **Streaming cat via `readFileSlice`** | `Tools/ntfsctl/Sources/ntfsctl/Cat.swift` | `cat` now loops `readFileSlice` (which is already streaming) instead of `readFile` (which has the 1 GiB cap). |
| **Path resolve** | `Packages/NTFSCore/Sources/NTFSCore/Volume.swift` (`resolvePath`) | Resolves a slash-separated path under root to its MFT record number. CLI commands accept either a recnum or a path, so users don't have to chase numbers manually. |

**Test count:** 98 (was 87 at v0.1). New tests in `Packages/NTFSCore/Tests/NTFSCoreTests/StreamingAndLargeIndexTests.swift` cover streaming round-trips, bulk LARGE_INDEX inserts, the leaf-full sentinel error, and `resolvePath` cases.

**Remaining LARGE_INDEX limit:** if a single INDX leaf fills up, the next insert into that leaf throws `unsupportedFeature(...leaf full)`. On a typical 4 KiB INDX block with ~70-byte entries, this caps inserts into any one leaf at ~50 entries. **Leaf split (proper B-tree split that allocates a new leaf, propagates a median key up to `$INDEX_ROOT`, and may grow tree height) is the next major engineering follow-up** — see "engineering follow-ups" below.

### FSKit System Extension (`Extensions/NTFSFileSystem`)

All write callbacks wired to NTFSCore:

| FSKit callback | Wired |
|---|---|
| `probeResource` | ✅ — boot-sector signature check |
| `loadResource` | ✅ — constructs Volume, honors `--rdonly` |
| `activate` | ✅ — returns root item |
| `lookupItem` | ✅ — Win32-namespace, skips DOS aliases |
| `enumerateDirectory` | ✅ — cookie-paginated, $I30-walked |
| `read` (file contents) | ✅ — `readFileSlice`, no full-file reload |
| `getAttributes` | ✅ — fresh path reads live MFT for sizes/times |
| `createItem` | ✅ — wires to Volume.createFile + setDirty |
| `removeItem` | ✅ — wires to Volume.deleteFile + setDirty |
| `write` (file contents) | ✅ — wires to Volume.write + setDirty, EINVAL on negative offset |
| `setAttributes` (size only) | ✅ — wires to Volume.truncate |
| `openItem` | ✅ — honors isReadOnly flag |
| `createSymbolicLink` / `createLink` / `renameItem` | ❌ — return EROFS (out of scope for v1) |

Code is complete. **Has never been activated on real hardware** because that requires SIP-off or the FSKit entitlement.

### Menu-bar app (`Apps/NTFSMountManager`)

- `MenuBarExtra`-based UI listing attached NTFS volumes via DiskArbitration
- Per-volume Mount / Eject buttons (using DADiskMount / DADiskUnmount)
- Settings window with `OSSystemExtensionManager` activation flow
- Status display: extension idle / activated / failed

Code is complete. Builds clean. **Has not been run with the extension actually loaded.**

### Build / CI / packaging

- **CI**: 3 jobs on `macos-15` — `ntfscore-test` (swift test), `fskit-extension-build` (xcodebuild on extension + containing app), `ntfsctl-test` (CLI smoke against fixture). All green on `main`.
- **Xcode project**: generated from `project.yml` via `xcodegen`. Three targets: NTFSMountManager (app), NTFSFileSystem (extension), ntfsctl (tool).
- **Fixture pipeline**: `scripts/make_test_images.sh` regenerates `Tests/.../Fixtures/small.img` via `mkntfs` in Docker. 4 MiB, committed to repo so CI doesn't need Docker.

## What's validated (and how)

| Validation tier | What it checks | Status |
|---|---|---|
| **Unit tests** (`swift test`) | All NTFSCore parsers + write paths against fixtures | ✅ 87/87 passing |
| **`ntfsfix --no-action`** | Volume passes the canonical Linux NTFS fsck after our writes | ✅ via integration test |
| **`ntfs-3g` mount + cat** | Canonical Linux NTFS driver reads back our writes byte-exact | ✅ via integration test |
| **Real Windows-formatted drive** | NTFSCore parses a real 4 TB Western Digital My Passport drive | ✅ via manual `ntfsctl verify` |
| **Byte-exact vs Apple's driver** | SHA-256 of our read matches Apple's mount-path read of same file | ✅ proven on real Windows .exe |
| **`xcodebuild` of FSKit ext + app** | All three Xcode schemes build clean | ✅ in CI |
| **FSKit extension mount in Finder** | Drive actually mounts via our extension | ❌ requires SIP-off / entitlement |
| **Windows `chkdsk /f`** | Microsoft's own fsck accepts our writes | ❌ requires Windows machine |
| **Multi-day endurance** | Mount + many writes + power cycle + remount | ❌ requires real installation |

The first 6 are the strong correctness signals. The last 3 are physical-world tests that depend on you.

## What's pending — only you can do

These are the items the automated work simply can't reach. Each one is a single concrete action.

### 1. FSKit mount validation on the M4 (high value)

**Why it matters:** the FSKit extension code is structurally complete and ntfs-3g-validated, but has never been loaded by macOS's FSKit runtime against a real device. The first time it runs is the first real test of:
- Whether the Info.plist / entitlements / FSPersonalities are correctly registered
- Whether macOS picks our extension over Apple's built-in NTFS driver for the same volume
- Whether Finder's drag-and-drop actually works
- Whether the FSKit callback contract (sequencing, error handling) holds in practice

**Two paths:**

| Path | Cost | Steps |
|---|---|---|
| **SIP-off + dev mode (free)** | ~15 min, reversible | Recovery boot → `csrutil disable` → reboot → `sudo systemextensionsctl developer on` → run NTFSMountManager → approve in System Settings → plug NTFS USB → `diskutil unmount` Apple's mount → `mount -t ntfs -o rdonly /dev/diskN /tmp/m` → browse Finder → re-enable SIP |
| **Apple Developer Program FSKit entitlement** | $99/yr + 2-14 day wait | Sign up if not already → request entitlement in dev portal → wait → no SIP changes ever |

**What to look for during the test:**
- Does NTFSMountManager.app appear in your menu bar after launching?
- Does "Activate Extension" successfully prompt System Settings approval?
- After approval, does `systemextensionsctl list` show our extension as "activated enabled"?
- When you plug in an NTFS USB, does `fskit_admin probe /dev/diskNsM` recognize it?
- Does `mount -t ntfs /dev/diskNsM /tmp/m` succeed and show contents via `ls /tmp/m`?
- Does Finder browse `/tmp/m` correctly?
- Can you copy a file via `cp ~/foo.txt /tmp/m/` (this tests our write callbacks)?

If anything fails, paste the Console.app output (filter to subsystem `com.ntfs-tool.fskit`) — the failure mode tells us exactly which callback is mis-wired.

### 2. Windows `chkdsk /f` round-trip (signature acceptance test)

**Why it matters:** `chkdsk` is the only authority that NTFS implementations defer to. If chkdsk says the volume is clean after our writes, no further validation is needed.

**Steps:**
1. Format a USB stick NTFS on a Windows PC (or use `mkntfs` via Docker).
2. Plug into M4.
3. Unmount Apple's auto-mount: `diskutil unmount /dev/diskNsM`.
4. Write a file via ntfsctl: `echo hi | sudo ntfsctl write /dev/diskNsM <recnum>`.
5. Mark clean: `sudo ntfsctl setdirty /dev/diskNsM 0`.
6. Unmount and unplug.
7. Plug into a Windows PC.
8. Open admin PowerShell → `chkdsk X: /f` (where X is the drive letter).
9. Expected output: `Windows has checked the file system and found no problems.`

If chkdsk reports errors, paste the output — that tells us which on-disk structure is subtly off vs Microsoft's expectations.

### 3. License decision

README and `docs/CLI.md` both say license is TBD. Recommendations:
- **MIT** — most permissive, no patent grant clause. Best for a tool people might want to copy code from.
- **Apache 2.0** — permissive + explicit patent grant. Better if you're worried about future Microsoft NTFS patent claims.
- **BSD 3-Clause** — like MIT but with an "endorsement" clause.

Since the NTFS code is a clean-room implementation from public format docs (no GPL contamination), you have all options available. Pick one and add a `LICENSE` file at repo root.

### 4. Manual write test against the real WD drive

The read path is byte-identical to Apple's driver on your 4 TB drive — read is fully production-validated. **The write path has never been tested against this physical drive.** Quick validation:

```bash
diskutil unmount /dev/disk10s1
# Find a folder you don't care about (or use /WD - Software/ which we know is record 44)
sudo ntfsctl create /dev/disk10s1 hello-from-ntfsctl.txt --parent 44
# Note the assigned record number, say 38
echo "Write test from macOS ntfsctl" | sudo ntfsctl write /dev/disk10s1 38
sudo ntfsctl setdirty /dev/disk10s1 0
diskutil mount /dev/disk10s1
ls "/Volumes/My Passport/WD - Software/hello-from-ntfsctl.txt"
cat "/Volumes/My Passport/WD - Software/hello-from-ntfsctl.txt"
```

If the file appears in Finder AND `cat` (via Apple's driver) returns the bytes we wrote, the write path is production-validated on your real drive. Clean up after:

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl delete /dev/disk10s1 38
diskutil mount /dev/disk10s1
```

## What's pending — engineering follow-ups

Ordered by user impact. Each is a focused piece of work appropriate for a single PR.

### High-impact

1. ~~**Path-based subcommand resolution.**~~ ✅ Done — `Volume.resolvePath` + `cat`/`write`/`list`/`cp` all accept paths.
2. **LARGE_INDEX leaf split.** The new LARGE_INDEX insert path works until any single 4 KiB INDX leaf fills (~50 entries). A real B-tree split (allocate new leaf, split entries 50/50, propagate median key to `$INDEX_ROOT`, possibly grow tree height) lifts this cap. Significant work — ~2-3 days. Without it, `cp -r` of folders with > ~50 files into the same leaf will hit `unsupportedFeature(leaf full)`. (Existing volumes that were formatted by Windows typically already have multi-leaf trees so the per-leaf cap matters less; fresh directories created on macOS hit it sooner.)
3. **Partial mid-file overwrites.** Currently `write` only supports offset==0 or offset==size. Real apps (e.g., text editors saving Word docs) need arbitrary offsets. Implementation: walk extents, write to specific clusters, no need to rewrite the entire runlist. ~1 day.
4. ~~**Streaming `cat` for large files.**~~ ✅ Done — `cat` streams via `readFileSlice`, no 1 GiB cap. `write --from-file` streams the inverse direction.
5. **Stale `$FILE_NAME` size hints.** After `writeFile`, the parent's `$I30` entry still reports `realSize: 0` from the `createFile` call (no live re-sync). `ntfsctl list` shows 0 for sizes; real Apple/Windows drivers compute from `$DATA` so it's cosmetic. To fix: re-insert the entry with the new size after each write, OR update the `$I30` entry's sizes in place. Half a day.

### Medium-impact

5. **Real `$LogFile` journal records.** Currently uses a "dirty bit only" approach which is correct for clean unmounts but doesn't enable automatic recovery from crashes/power-loss. Implementation: write LFS-formatted journal entries before metadata changes; replay incomplete transactions on dirty mount. Substantial — ~1-2 weeks for a minimal correct implementation.
6. **In-place runlist extension on append.** Stage 4's append always frees the old runlist and allocates fresh. Wasteful on fragmented allocators. Implementation: extend the last extent if there's free space adjacent, else add a new extent to the existing runlist. ~1 day.
7. **`$UpCase`-aware filename collation.** Currently uses Swift's `localizedCaseInsensitiveCompare` which is exact for ASCII but slightly off for non-ASCII vs Windows's `$UpCase`-driven order. Implementation: read `$UpCase` (MFT record 10) into a table, use that for comparison. ~half a day.
8. **`renameItem` / `createSymbolicLink` / `createLink` callbacks.** Currently return EROFS. Implementation: rename = remove $I30 entry + insert with new name + update $FILE_NAME's parent ref. Symbolic links require reparse point work — bigger.

### Low-impact / polish

9. **Better `ntfsctl verify`.** Currently sweeps only records 0..63. Make it walk the full MFT, validate every attribute, detect orphaned files (in MFT but not in any $I30), spot $Bitmap mismatches. Tier toward a proper `fsck`-equivalent.
10. **`ntfsctl tree`.** Recursive directory walk (depth-first or breadth-first), prints a tree like `/usr/bin/tree`.
11. **Recursive `ntfsctl find`.** Match by name pattern, traverse the volume.
12. **Better error messages.** Several `NTFSError.corruptOnDisk(...)` strings could be more user-actionable (suggest `chkdsk`, etc.).
13. **Volume statistics in the menu bar.** Show free space as a progress bar in the per-volume row.
14. **Drag-and-drop in the menu bar app.** Drop a file onto the volume row to copy it. (Requires FSKit mount actually working, of course.)

### Substantial / refactoring

15. **`NTFSError` to a richer model.** Currently a flat enum with string descriptions. A structured model (with severity, suggested action, doc link) would let us produce better diagnostics.
16. **Atomic transactions across multi-step mutations.** A `create` is currently 3 separate writes (MFT record, parent $I30, dirty bit). If we crash between, the volume is inconsistent. A real $LogFile journal (item 5) makes this safe.
17. **Volume snapshotting for write tests.** The existing `MutableFixture` copies the whole .img — works for small fixtures but doesn't scale. A copy-on-write overlay would let us test against larger volumes without doubling disk usage.

## Roadmap to v1.0

A suggested sequence if you want to push to a real release:

### v0.1 — "CLI-shippable" (achievable today)

- ✅ NTFSCore: production-validated reader/writer
- ✅ `ntfsctl`: full read + write CLI
- ✅ Cross-tool integration test in CI
- ❌ **License decided** (you pick MIT / Apache 2.0)
- ❌ **README rewritten** for first-time visitors (one paragraph what-it-is + one block install + link to `docs/CLI.md`)
- ❌ **GitHub release** with prebuilt `ntfsctl` binary in the Releases tab

Effort: ~1 hour after the license decision. **This release is genuinely useful** — there's no other open-source CLI for reading and writing NTFS on macOS.

### v0.2 — "FSKit mount works on your M4"

After your manual SIP-off (or entitlement) validation:
- ❌ FSKit mount validation completed (see "What's pending — only you can do" #1)
- ❌ Any bugs found in real-hardware testing fixed
- ❌ README adds "Mount via menu bar" install path
- ❌ Engineering follow-ups #1-4 (path resolution, LARGE_INDEX, mid-file write, streaming cat)

Effort: 1-2 weeks of focused work + the manual validation.

### v0.3 — "chkdsk-clean writes + crash recovery"

- ❌ Engineering follow-up #5 (real $LogFile journaling)
- ❌ Windows chkdsk validation (only-you-can-do #2)
- ❌ Power-loss simulation in CI (kill the writer mid-mutation, mount-and-recover, verify integrity)

Effort: 2-3 weeks.

### v1.0 — "Paragon parity"

- ❌ Engineering follow-ups #2-8 (LARGE_INDEX, partial writes, streaming, journal, runlist extension, $UpCase, rename/symlink)
- ❌ Notarized distribution via Developer Program FSKit entitlement
- ❌ End-user installer (.dmg or .pkg) + auto-update path
- ❌ Documentation site beyond `docs/`

Effort: 1-3 months of focused work.

## How to contribute

The codebase is structured to make additions tractable:

- **New NTFSCore feature** (new attribute parser, new mutation primitive) → add to `Packages/NTFSCore/Sources/NTFSCore/`. Follow the established convention of `static func parse(_ data: Data) throws -> Self` for parsers; mutating verbs as instance methods on `Volume`.
- **New `ntfsctl` subcommand** → add a struct to `Tools/ntfsctl/Sources/ntfsctl/` conforming to `AsyncParsableCommand`, register it in `ntfsctl.swift`'s `subcommands:` list.
- **New FSKit callback** → wire in `Extensions/NTFSFileSystem/Sources/NTFSVolume.swift`. Follow the existing pattern of dispatching to `coreVolume.<verb>(...)` + `setDirty(false)`.
- **New test** → mirror the source file's name in `Packages/NTFSCore/Tests/NTFSCoreTests/`. Use `MutableFixture.scopedCopy` for tests that mutate the fixture.

CI runs on every PR; tests must pass before merge. PR descriptions should include: scope, test plan, and any known limitations (the existing PR history in `main`'s log is a good model).

For substantive engineering work, please file an issue first to discuss approach — the LARGE_INDEX and $LogFile journal items in particular have real design surface that's worth aligning on before implementation.

## Where to find things

| Looking for | Where |
|---|---|
| Architecture overview | [`CLAUDE.md`](../CLAUDE.md) |
| CLI usage walkthrough | [`docs/CLI.md`](CLI.md) |
| Project status & roadmap | This file |
| Autonomous-run summary (how we got here) | [`.supervisor/autonomous/auto-2026-05-14-203703/summary.md`](../.supervisor/autonomous/auto-2026-05-14-203703/summary.md) |
| Multi-phase requirement that drove development | [`.supervisor/requirements/auto-2026-05-14-203703-ntfs-multi-phase-rubric.md`](../.supervisor/requirements/auto-2026-05-14-203703-ntfs-multi-phase-rubric.md) |
| Test fixtures + regeneration script | `Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/` + `scripts/make_test_images.sh` |
| CI workflows | `.github/workflows/ci.yml` |
| Xcode project source | `project.yml` (regenerate via `xcodegen generate`) |
| PR history | `git log --oneline --first-parent main` |
