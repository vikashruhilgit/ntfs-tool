# Project Status — What's Done, What's Pending, What's Next

This document is the single source of truth for project state. Updated when major work lands.

**Last updated:** 2026-08-04, after **v0.7.4 — WINDOWS `chkdsk` IS CLEAN. Gate 2 is CLOSED.** A full 11,568-file / 741 MiB `cp -r` onto a Windows-quick-formatted volume now passes `chkdsk` with **"Windows has scanned the file system and found no problems"** — all three stages, 16,069 file records, 24,951 index entries, 0 unindexed files, no bitmap error. This is the first time Windows has accepted a volume written by this driver, and it closes the external correctness gate the project had deferred to since v0.2.

Five defects were found and fixed to get there, **four of them invisible to our own `verify --deep`**:

1. **Data-run LENGTH encoded unsigned-minimal.** Windows decodes that field as SIGNED, so a 184-cluster run written as the single byte `0xB8` reads as −72 → `Attribute record (80, "") … is corrupt`. Only runs of 128–255 clusters (~512 KiB–1 MiB) set the high bit in a one-byte field, which is why exactly that size band failed. Isolated from on-disk bytes: the predictor "top length byte has bit 7 set" matched chkdsk's verdict **41/41 flagged and 10,004/10,004 clean**. Fixed in `Volume`/`Mkntfs.encodeRunlist`.
2. **`$ATTRIBUTE_LIST` appended instead of sorted.** NTFS requires ascending `(type, name, startingVCN)` within a record; both migration builders appended type 0x20 after `$FILE_NAME` (0x30) → hardware records stored `[0x10, 0x30, 0x20]` → `Attribute records … are unsorted`. A since-corrected comment asserted stream position did not matter. Fixed with a shared sorted-insert helper.
3. **`readFileSlice` rejected migrated files outright**, while `readFile` resolved them — so a migrated file was readable whole but not streamable, breaking `ntfsctl cat`, `cp --from-volume`, and the FSKit kernel read callback. The v0.7 audit that routed 12 callsites through the merge seam missed this one because it resolves attributes itself.
4. **`$MFT` growth disabled mid-transaction.** `$MFT` grows in 256-record chunks, so ~every 256 records one allocation must grow it, and whichever callsite asks first wins. `createFile` may grow; the two migration sites may not (the documented grow×leaf-split hazard). When a migration drew the short straw the copy died — observed at file 8,180 of 11,500, while an earlier identical run crossed ~62 boundaries without colliding. Fixed by reserving headroom at transaction ENTRY (`ensureMFTHeadroom`), **not** by enabling growth at the migration sites, which would reopen the hazard.
5. **A failed write leaked its whole cluster allocation.** `writeFile` persists the allocation before streaming payload; any throw before commit left the clusters allocated with no owner → `The Volume Bitmap is incorrect`. Seen as one contiguous 2,564-cluster run, exactly the size of one corpus file that a concurrent build was rewriting mid-copy. Now released on every pre-commit failure path (best-effort, non-throwing, so it cannot mask the original error).

**The pattern behind all five: our reader was tolerant exactly where our writer was wrong** — it decodes run lengths unsigned, iterates attributes without regard to order, and `RunlistBitmapAudit` only ever asked "is every referenced cluster allocated?", never the reverse. So `verify --deep` certified volumes Windows rejected. The structural response is `Volume.auditBitmapForUnreferencedClusters` — a reverse `$Bitmap` audit sweeping EVERY non-resident attribute (not just unnamed `$DATA`: `$INDEX_ALLOCATION`, `$BITMAP:$I30`, named streams, non-resident `$ATTRIBUTE_LIST`) — surfaced in `verify --deep` as leaked clusters, leaked bytes, and the largest leaked ranges. Calibration: 0 leaked on a pristine `mkntfs` fixture; on hardware it computed **205,300 referenced clusters, byte-identical to chkdsk's own 205,300 used** (1,936,635 total − 1,731,335 available) — two implementations agreeing from opposite directions.

Also validated this cycle: `$MFT` auto-grow **256 → 16,069 records** across ~62 growth boundaries with 40 migrations, 0 orphans, deep audit clean.

Prior update — 2026-06-01, after the **`$I30` COLLATION ROOT-CAUSE FIX (v0.7.3)** — `ntfsctl`-written volumes now mount **on the real `ntfs-3g` driver** (validated via the new `scripts/ntfs-oracle.sh` Docker oracle) and read back byte-exact. The "drive corrupted on Windows" failure was traced to directory `$I30` index ordering: we sorted entries with Swift's locale-aware `localizedCaseInsensitiveCompare` instead of NTFS `COLLATION_FILE_NAME` (UTF-16 code units via `$UpCase`). Locale collation sorts `.` before `$` (NTFS is the reverse), so inserting into a real volume's root re-sorted the system entries; Windows/ntfs-3g binary-search that B-tree, missed `$Secure`, and declared the volume corrupt. Our own reader never caught it (it searched with the same wrong order — the weak-oracle trap, now closed by validating against real `ntfs-3g`). Also in v0.7.3: **`$MFT` auto-grow** — `ntfsctl` can now write to a freshly **Windows-formatted** volume. Hardware testing on a real 4 TB WD drive (quick-formatted on Windows) exposed that its `$MFT.$DATA` starts at exactly **16 records** and Windows grows the MFT on demand; `ntfsctl`'s allocator refused to grow `$MFT` (`"auto-grow is disabled in v0.2"`), so the **first** user-file create failed (it needs MFT record 16). Every prior success — including the 22,419-file copy — only worked because our own `mkntfs` over-allocated a 16,384-record MFT (the *same* weak-oracle blind spot the `mkntfs` removal uncovered). Fix: `allocateMFTRecord(allowGrowth:)` now calls the already-implemented `growMFTDataByClusters` (256-record chunks, also extends `$MFT.$BITMAP`) when out of materialized slots, enabled **only** at the safe `createFile` base-record allocation point (off mid-migration, avoiding the historical grow×leaf-split corruption hazard). Ceiling: ~32,768 records until cascading `$MFT.$BITMAP` growth is added (ample for large backups). New `MFTAutoGrowTests` build a 16-record-MFT fixture and prove grow×leaf-split stays deep-audit clean + 0 orphans, content survives reopen. **Pending external validation: the actual full-backup `cp -rT` onto the Windows-formatted drive (a manual hardware step).** Prior milestone — **`mkntfs` was REMOVED (v0.7.2)**. Hardware testing proved the pure-Swift formatter (v0.6) produced volumes that NTFSCore's own reader accepted but **Windows and macOS `livefiles_ntfs` reject as corrupt** — our reader never validated total-sectors/backup-BS geometry, `$Secure` B-trees, boot code, or `$MFT`/`$MFTMirr` placement conventions the way real drivers do. A spec-faithful formatter is an `ntfsprogs`-scale effort and out of scope; a half-correct one (valid-to-us, corrupt-to-Windows) is worse than none, so the `ntfsctl mkntfs` CLI command was removed. **Format NTFS volumes on Windows (or `mkntfs-3g`); `ntfsctl` operates on existing volumes.** An internal `Volume.formatNTFS` remains as a clearly-labelled NTFSCore-only test-fixture builder (not user-accessible, not portable). Root-cause lesson: `mkntfs` was merged at v0.6 on a weak oracle ("passes our own reader") — anything that writes a format for *other* systems to consume must be validated against those systems before shipping. **Prior milestone (v0.7.2): the move + conflict model** landed (`cp --move` cross-device cut, `mv` skip/replace conflict policy, and the `rename` `$I30` atomicity audit closed) — completing the copy / move / skip / replace capability matrix across host↔volume and within-volume. `cp --move` (alias `--remove-source`) deletes each source only after its copy succeeds — skipped (`-n`) or failed sources are preserved, emptied dirs removed depth-first only when fully moved, `--dry-run` previews deletions. `mv` default-replaces (delete + insert-before-remove atomic rename, so the source is never lost even on a mid-replace abort) or `-n`-skips; a case-only-rename / self-move data-loss guard prevents deleting the source when the destination resolves to the source record itself. **285 NTFSCore tests + 33 ntfsctl tests pass, 2 skips, 0 failures, CLI release builds.**

**🎉 HARDWARE MILESTONE (v0.7.1, 2026-05-31):** the full **22,419-file / 39.60 GiB** phone-backup `cp -rT` onto a freshly-`ntfsctl mkntfs`'d 4 TB WD My Passport **completed in full** (prior caps: ~350 → ~1,611 → ~6,139 → ~7,997 → ALL). `verify --deep` PASSED — 0 orphans / 0 leaked-extensions / 0 dangling / 0 free-but-referenced / 0 out-of-range / 0 double-allocated / 0 unreadable, **11,658,166 runlist clusters audited clean**, only **6 extension records** for the whole tree (the multi-extension `$ATTRIBUTE_LIST` machinery correctly demoted to the rare fallback — the locality allocator kept directory indexes contiguous so they never migrated). macOS `livefiles_ntfs` read-only-mounts and browses the result; its known >4 GiB read bug is Apple's, not ours (our bytes are spec-correct, proven via raw `dd` + independent decoders). **Windows `chkdsk` was the one pending external validation gate at the time; it PASSED on 2026-08-04 (v0.7.4) — see the top of this document.**

Prior update — after the **v0.7.1 per-directory index-allocation locality lane (the ROOT-CAUSE fix)** landed — this is the fix that *should have come first*. The ~8,000-file single-directory cap was a **fragmentation symptom, not an NTFS structural limit**: pre-v0.7.1 every directory INDX block was allocated via the GLOBAL next-fit hint shared with file `$DATA`, so during a `cp -r` file-data clusters interleaved between consecutive INDX-block allocations and scattered them → one `$INDEX_ALLOCATION` runlist extent per block → linear runlist growth → overflow of the 1 KB base MFT record at ~8 k files. The fix is the Windows/Paragon/Tuxera-equivalent **PRIMARY mechanism**: a **per-directory index-allocation locality lane + contiguous in-memory chunk targeting, allocate-on-use** (`Volume.allocateIndexClusters(near:)` + `indexLocalityHint(forExtents:)`, `indexChunkClusters = 256`, an upper-25% index lane base). It aims each new INDX block at the directory's runlist tail (or, for the first block, the high index lane away from the `$DATA` front), so consecutive blocks land contiguous and coalesce. **Measured: 222 extents → 1 extent at 4,000 interleaved entries on a 512 MiB image, with NO `$ATTRIBUTE_LIST` migration at all** (the `$I30` cap mechanism never fires). Critically this is **allocate-on-use** — each INDX cluster is marked in `$Bitmap` ONE AT A TIME at build+splice time, never reserved up front, so there is no leaked-on-crash tail and no new crash window; the "chunk" is purely an in-memory target LCN range. The multi-extension `$ATTRIBUTE_LIST` path (v0.7 / PR #35) is now correctly **repositioned as the rare last-resort fallback** for genuinely fragmented/pathological volumes — still proven by the unchanged PR #35 suite (7 tests, all green) plus a new fragmented-volume degrade test (swiss-cheese free space → the single-cluster fallback `findFreeRun(256)→findFreeRun(1)` engages AND, organically, the PR #35 migration fires: ~83 extents + `$ATTRIBUTE_LIST` migration, while the directory still grows and reads back). New no-leak tests: a delete of a locality-grown 2,500-entry directory returns the free-cluster count to baseline exactly (0 leaked) with a clean deep audit + 0 orphans, and a crash-simulating abort mid-INDX-growth (via the `.afterI30CommitBeforeReturn` createFile fault hook, which throws right after the `$I30` commit that runs the INDX allocate+splice) leaves 0 free-but-referenced / 0 double-allocated clusters, 0 orphans, and no dropped entries. **221 NTFSCore tests pass (was 217), 1 pre-existing skip, 0 failures (222 executed, +4 new), CLI release builds.** AC-9 hardware re-validation remains a pending MANUAL step (full 22,419-file `cp -rT` onto a freshly-`mkntfs`'d volume; expect full completion or a far higher cap; `verify --deep` clean). Prior update — after the **v0.7 multi-extension `$ATTRIBUTE_LIST` for `$INDEX_ALLOCATION:$I30`** landed — lifts the ~file-7,997 single-directory cap that PR #34 documented as the next structural ceiling (when a directory's migrated `$INDEX_ALLOCATION` runlist fills its EXTENSION MFT record). v0.7 implements the multi-extension write path (`AttributeMigration.buildAdditionalExtensionForAttribute` + the existing extension-first transactional discipline), the canonical read-path merge seam (`Volume.mergeMultiExtensionAttribute`) routed at all 12 audited callsites (including `RunlistBitmapAudit.auditDataRunlistAgainstBitmap` / `resolveDataExtents` — `verify --deep` and `dump` walk merged extents, no double-counting), and a positive `verify --deep` assertion on the multi-extension shape (`testMultiExtensionVerifyDeepClean`). **Per-directory capacity is now bounded only by free clusters + MFT slots — no algorithmic cap from extension-record size.** The PR #34 `unsupportedFeature("multi-extension $ATTRIBUTE_LIST required")` error path is now unreachable for `$INDEX_ALLOCATION:$I30` overflow. **217 NTFSCore tests pass (was 216), 1 pre-existing skip, 0 failures, CLI release builds.** Prior update — after the **v0.6 self-contained NTFS reformat** landed (`ntfsctl mkntfs <device> --yes`): pure-Swift quick-format equivalent to `mkntfs -Q`, output mountable by macOS livefiles_ntfs / Linux ntfs-3g / Windows. **The project is now self-sufficient for the full test loop on macOS** — no Homebrew, no macFUSE, no Linux VM, no Windows required for reformat-between-runs in the v0.5.x cap-measurement loop. New: `BootSector.serialize()`, `UpcaseTable` (auditable Unicode-derived 128 KiB blob), `AttrDefTable` (NTFS 3.1 spec 2,560-byte table), `Mkntfs.format` orchestrator, `BlockDevice.size()` (fstat for .img, ioctl(DKIOCGETBLOCKSIZE|DKIOCGETBLOCKCOUNT) for /dev/disk*), `Volume.formatNTFS` entry point, CLI safety gate (`--yes` required). 39 new NTFSCore tests: AC-3 round-trip on a 256 MiB .img, AC-4 hand-decoded boot-sector byte assertions, AC-5/AC-6 spec-conformance for $UpCase and $AttrDef (independent of our decoder, per PR #26 lesson). **206 NTFSCore tests pass (was 167)**, 1 skip, 0 failures, CLI release builds. Prior update — **v0.5.2 regression-fix pair** landed (closes two holes PR #29's hardware re-run exposed on 2026-05-27): **(Bug A) leaf-split migration-catch gap on two formerly-uncaught call sites** — `rewriteParentForLeafSplit` was called from six sites in `Volume.swift` after PR #29's refactor, and two of them (the call inside `heightGrowIndexRoot`, and the call in `promoteThroughInteriorChain`'s `!cascadeExhaustedChain` early-return branch) remained outside any `isOverflowDescription` catch. Overflows on those paths escaped uncaught, leaving the directory un-migrated and the cp aborted (`WhatsApp Images` recnum 2998 was the active insertion target on the 2026-05-27 hardware run, with `dump` reporting `Migrated ($ATTR_LIST): no` post-error). Fixed by introducing `rewriteParentForLeafSplitMigrating` — a thin async wrapper that mirrors the existing cascade-exhausted catch pattern and is now called by the two formerly-uncaught sites. **(Bug B) atomic `$I30` insert ↔ MFT-record commit on `createFile`** — post-error `verify --deep` on 2026-05-27 reported `2 dangling $I30 entries`; cause was `createFile` freeing the orphan MFT slot on any post-commit throw. Fixed by threading an `inout i30Committed` flag through `insertIntoParentI30` so the catch on throw chooses the correct policy: clean rollback (free the MFT slot) if no parent-side byte was written, orphan-base retention (keep IN_USE=1) if a parent-side write hit disk. The `(record absent, $I30 present)` dangling state is now structurally unreachable from any throw inside `createFile`. **AC-1 caveat for Bug A (honest disclosure):** the 4 MiB `small.img` fixture exhausts MFT slots / free clusters at ~2100 files before the IA runlist can grow large enough to overflow base-record slack at the uncaught sites, so the new `LeafSplitMigrationCatchTests` cannot demonstrate the strict baseline-fail shape on `small.img` — they serve as post-fix correctness verification + forward regression guards. Bug A wrapper correctness is established by code-reading + hardware evidence. **167 NTFSCore tests pass (was 159)**, 1 skip, 0 failures, CLI builds. **Hardware re-validation pending** — user must truly reformat the drive (`mkntfs -Q`) before re-running the full-corpus `cp -rT` for a clean baseline measurement. Prior update 2026-05-26, after the v0.5 post-migration `$INDEX_ALLOCATION` leaf-split routing fix landed — **lifts the hardware ~file-6,139 single-directory `cp -r` cap** by making `rewriteParentForLeafSplit` extension-aware (routes the `$INDEX_ALLOCATION:$I30` / `$BITMAP:$I30` rewrite to the extension record that actually holds the migrated attribute, with extension-first commit matching `migrateAttributeOnOverflow`'s transactional discipline; also threads `extraRecordWrites` through the cascade → height-grow return path that previously orphaned an INDX leaf's worth of entries). Confirmed against `main` @ 751cd9f: pre-fix the first post-migration leaf split throws `corruptOnDisk: rewriteEntireAttribute: target type 0x000000A0 not found` within ~16 inserts of migrating; post-fix 1,500+ post-migration inserts proceed cleanly, audit clean, orphan-free. 159 NTFSCore tests pass (was 156). See the dedicated v0.5 follow-up below. Next structural ceiling: the migrated `$INDEX_ALLOCATION` runlist eventually filling the EXTENSION record (1024 B) — needs a multi-extension `$INDEX_ALLOCATION`; not reachable on the 4 MiB `small.img` fixture. Prior update 2026-05-23, after the v0.5.1 `truncate` clean-error fix + FSKit `makeFreshAttributes` size fix landed, **closing the file-attribute-path extension-awareness audit** (`Volume.truncate` now throws a clean `unsupportedFeature` — not a false `corruptOnDisk` — on a migrated file, before mutating anything; FSKit's `makeFreshAttributes` reads migrated-file size via `allAttributesOf` — see the dedicated v0.5.1 follow-up below; 145 NTFSCore tests pass). Prior update 2026-05-22, after the v0.5 `$ATTRIBUTE_LIST`-aware delete + base-free leaked-extension reclaim landed (`Volume.deleteFile` now frees migration extension records and their clusters; `Volume.freeExtensionRecord`; `reclaim-orphans --confirm` reclaims confirmed-base-free leaked extensions via `MFTConsistency.splitLeakedExtensions`'s authoritative base-free check — see the dedicated v0.5 follow-up below; 143 NTFSCore tests passed). Prior update 2026-05-20, after two complementary v0.5 fixes landed together. **(1) v0.5 Fix B Step 4 — unnamed `$DATA` (type 0x80) migration write path:** generalizes Step 3's `$INDEX_ALLOCATION` (0xA0) MFT-record-overflow migration so it ALSO handles a file's own non-resident unnamed `$DATA` — when the `$DATA` runlist would overflow the base record's slack (the bug that capped a hardware `cp -r` at file 350 with "would overflow record … type 0x80"), `$DATA` is migrated to a fresh extension MFT record and a resident `$ATTRIBUTE_LIST` is added to the base, same compute-first transactional pattern, shared builder reused from Step 3 (no behavior change to the 0xA0 path). **(2) v0.5 next-fit cluster allocator with rolling search hint** (`Bitmap.findFreeRun` wrap-around + `Volume._allocHint`): cuts `$DATA` runlist fragmentation on sequential `cp -r` writes. The two are complementary — the allocator reduces how often a runlist grows large enough to overflow; Step 4 handles the case when it overflows anyway. Both build on v0.5 Fix B Step 3 — `$INDEX_ALLOCATION` migration write path — (read path + migration commit), which itself builds on Step 1+2's `$ATTRIBUTE_LIST` parse/serialize + `Volume.resolveAttribute` / `allAttributesOf` read-path foundation. Earlier in the cycle: v0.4 `$INDEX_ROOT` multi-level split (Phases 3(A)–(D); per-dir capacity bounded only by free clusters + MFT slots), bitmap dirty-range tracking (~400-500× per-file speedup on USB), and the v0.3 leaf-split silent-orphan fix validated on real 4 TB WD hardware (22,419-file phone-backup cp -r → clean `unsupportedFeature` abort at file 63, **0 orphans** vs. 11 silent orphans pre-v0.3). Hardware validation against the real WD My Passport is still pending — user manual step.

**Audit status:** every FATAL + CRITICAL item from [`AUDIT-REPORT.md`](../AUDIT-REPORT.md) is closed. WARNING #9 (streaming bitmap reader) and #11 (pre-baked test Docker image) deferred to v0.3.
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
| `Bitmap.swift` | $Bitmap reader + bit-level allocator (allocate/free/findFreeRun). v0.5: `findFreeRun` wraps around the volume so a high next-fit hint never strands free space below it. | 10 + 14 + 7 tests |
| `Volume.swift` | Top-level coordinator. enumerate, readFile, readFileSlice, createFile, deleteFile, write, truncate, allocateClusters, freeClusters, setDirty. | covered across all suites |
| `VolumeInformation.swift` | $VOLUME_INFORMATION parser + serializer (incl. dirty bit). | covered |
| `BlockDevice.swift` | Sendable protocol; FileHandleBlockDevice impl (read + write). | covered |
| `UTF16.swift` | LE UTF-16 decoder shared by Attribute / FileName / IndexEntry. | covered |
| `Endian.swift` | Little-endian fixed-width Data accessors with bounds checking. | covered |
| `Errors.swift` | Typed `NTFSError` enum. | — |

**87 tests total** across 12 test files. Plus an integration test (`IntegrationTests.swift`) that runs ntfsfix + ntfs-3g round-trip in Docker — skipped gracefully when Docker isn't reachable.

### `ntfsctl` CLI (`Tools/ntfsctl`)

13 subcommands covering read + write:

| Subcommand | Done | Notes |
|---|---|---|
| `info` | ✅ | Volume metadata + free-space stats |
| `scan` | ✅ | **NEW.** Enumerate attached NTFS partitions (no more `diskutil list` eyeballing). `--include-images` probes `.img` files too. |
| `list` | ✅ | Directory enumeration, short + long format. Accepts MFT recnum OR path. |
| `verify` | ✅ | **Full-MFT sweep** + orphan detection + dangling-$I30 detection. Bounds itself by $MFT's $DATA realSize. **Extension-record aware (v0.5):** distinguishes base records from v0.5 Fix B migration extension records — reports an `Extension records: N (linked)` line, no longer false-flags them as orphans, and surfaces a `leaked extension (base record free)` error class. |
| `cat` | ✅ | File content to stdout. Streaming (no 1 GiB cap), supports `--offset`/`--length`. Accepts MFT recnum OR path. |
| `create` | ✅ | New file/directory with $I30 insertion. Auto-promotes small dirs to LARGE_INDEX on overflow. |
| `delete` | ✅ | File deletion with cluster free + $I30 removal. Works against LARGE_INDEX parents. |
| `write` | ✅ | Stdin → file content (rewrite, append, **or mid-file overwrite**). `--from-file` streams from a host file (no 1 GiB cap). Accepts MFT recnum OR path. |
| `cp` | ✅ | **Bidirectional** host↔volume copy (`--from-volume` inverts). `-r` recursive. `--progress` / `--dry-run` / `-n` (no-clobber) / `-v` (verbose). Free-space pre-check by default. |
| `rm` | ✅ | **NEW.** Remove file(s) or directory tree(s). `-r` recursive. Accepts paths or recnums. |
| `mv` | ✅ | **NEW.** Rename or move a file/directory by path. Works across directories; auto-creates intermediate destination dirs. |
| `truncate` | ✅ | Byte-precise resize (any size, including non-cluster-aligned shrinks). Doesn't grow yet. |
| `setdirty` | ✅ | $VOLUME_INFORMATION dirty bit toggle |
| `reclaim-orphans` | ✅ | **NEW (v0.3).** Sweep MFT, clear IN_USE on records unreachable from root, free $MFT.$BITMAP bit. Recovery tool for volumes left with orphans by older buggy builds (pre-v0.3 leaf-split bug). Dry-run by default; pass `--confirm` to clean. Native equivalent of `ntfsfix` / `chkdsk /f` for this specific failure class — no Linux/Windows machine required. **Extension-record aware (v0.5):** only orphaned BASE records are reclaimed; a v0.5 Fix B migration extension record (legitimate or leaked) is NEVER freed (a defensive guard enforces this), since freeing a live base's extension slot would corrupt that file. Leaked extensions are reported with a `chkdsk /f` recommendation rather than auto-freed. |

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

**Test count:** 102 (was 87 at v0.1, 98 in the previous iteration). New tests cover streaming round-trips, bulk LARGE_INDEX inserts, the leaf-full sentinel, `resolvePath`, mid-file overwrite, byte-precise truncate, in-dir rename, and cross-dir move.

### Post-v0.1+ work (this iteration, on top of v0.1+)

| Capability | Where | What changed |
|---|---|---|
| **Mid-file random write** | `Volume.write` (calls `overwriteRange`) | When `0 < offset` and `offset+bytes ≤ existingSize`, patches the right clusters in place (non-resident) or read-modify-writes (resident). No allocation, no MFT touch — fast enough for SQLite / Word save-pattern workloads. |
| **Byte-precise truncate** | `Volume.truncate` (calls `shrinkNonResidentTo`) | Drops the trailing extents past `ceil(newSize/cluster)`, sets realSize to the exact byte. Trailing partial cluster slack is fine — reads stop at realSize. |
| **`$FILE_NAME` size refresh** | `Volume.refreshParentI30Size` (called from `write` + `writeFile`) | After write, patches the parent's resident `$I30` entry's size hints so `ntfsctl list --long` shows the new size. (LARGE_INDEX parents: deferred — would require B-tree walk to find + rewrite the leaf entry.) |
| **Rename / move** | `Volume.rename(at:toName:inDirectory:)` | Removes old $I30 entry, rewrites `$FILE_NAME` body with new name + parent ref, inserts new $I30 entry. Supports both in-dir rename and cross-dir move. |
| **Reverse `cp` (volume → host)** | `Tools/ntfsctl/Sources/ntfsctl/Cp.swift` (`--from-volume`) | Pulls files/trees off the volume to a host path, streaming via `readFileSlice`. Mirror of host→volume cp. |
| **`cp` ergonomics** | Same | `--progress` shows file count + bytes + percentage as it runs; `--dry-run` counts without writing; `-n` skips existing destinations; `-v` prints each entry; `--no-free-check` skips the host→volume free-space pre-check. |
| **`rm [-r]`** | `Tools/ntfsctl/Sources/ntfsctl/Rm.swift` | Bulk delete: file by path or recnum, or recursive directory tree. |
| **`mv`** | `Tools/ntfsctl/Sources/ntfsctl/Mv.swift` | Path-based rename / move via `Volume.rename`. Auto-creates intermediate destination dirs. |
| **`scan`** | `Tools/ntfsctl/Sources/ntfsctl/Scan.swift` | Walks `/dev/disk*s*` probing each as NTFS, prints size + free space + serial. `--include-images` for `.img` files in cwd. |
| **Full-MFT `verify`** | `Tools/ntfsctl/Sources/ntfsctl/Verify.swift` | Sweeps every MFT slot (bounded by `$MFT`'s logical size), reachability-walks from root, reports orphans + dangling $I30 entries + parse errors. Closer to an `fsck` than the old 0-63 sweep. |
| **Actionable error hints** | various CLI files | Path-not-found and "in use" errors now include actionable suggestions in the message text. |

**LARGE_INDEX leaf-split silent-orphan bug — FIXED (2026-05-18).** Previously, after ~4 leaf splits in the same directory, the next insert that would overflow `$INDEX_ROOT`'s interior-entry budget partially mutated disk (rewriting the original leaf to its left half, writing right-half data to a new cluster that was never linked into `$INDEX_ALLOCATION`) before throwing — silently orphaning 10-15 previously-inserted $I30 entries. Root cause: `splitLeafAndPromote` performed leaf disk writes BEFORE the in-memory parent-record overflow check. Fix: reordered so the parent record is built (and overflow check fires) ahead of any leaf disk write; on overflow the freshly-allocated cluster is released via `freeClusters`. The repro test (`testLeafSplitOrphansBugUnderCpRWorkload`) now passes — 75 inserts, 75 visible on reopen, 0 missing. See [`docs/V0.3-LEAF-SPLIT-DEBUG-NOTES.md`](V0.3-LEAF-SPLIT-DEBUG-NOTES.md) for the full investigation log. The remaining limit (the case where `$INDEX_ROOT` itself needs to split into a multi-level B-tree) is a separate, smaller item — when reached, insert now throws `unsupportedFeature` cleanly with no data loss.

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
| `createSymbolicLink` / `createLink` | ❌ — return EROFS (out of scope for v1) |
| `renameItem` | ✅ — fully implemented (EBADF/ENOTDIR/EINVAL guards, then real rename logic; never returns EROFS) |

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
| **Unit tests** (`swift test`) | All NTFSCore parsers + write paths against fixtures | ✅ 145 tests, 0 failures (1 skip: two concurrent migrations don't fit the 4 MiB fixture); incl. extension-record classifier, `$ATTRIBUTE_LIST`-aware delete, migrated-file `truncate` clean-reject + `allAttributesOf` size proof |
| **`ntfsfix --no-action`** | Volume passes the canonical Linux NTFS fsck after our writes | ✅ via integration test |
| **`ntfs-3g` mount + cat** | Canonical Linux NTFS driver reads back our writes byte-exact | ✅ via integration test |
| **Real Windows-formatted drive** | NTFSCore parses a real 4 TB Western Digital My Passport drive | ✅ via manual `ntfsctl verify` |
| **Byte-exact vs Apple's driver** | SHA-256 of our read matches Apple's mount-path read of same file | ✅ proven on real Windows .exe |
| **`ntfsctl` write → Apple's driver read on real hardware** | Apple's NTFS driver reads our writes byte-exact on re-mount of the user's 4 TB WD My Passport | ✅ proven 2026-05-18 against v0.2.0 candidate `bac8d31` (see §4 below) |
| **v0.3 leaf-split clean-abort on real hardware** | 22,419-file phone-backup `cp -r` against same WD drive; expected to hit parent-record overflow ~file 63 (same trigger as v0.2 silent-orphan bug). Pass condition: clean `unsupportedFeature` abort + `verify` shows 0 orphans. | ✅ proven 2026-05-19 against v0.3.0 candidate — 0 orphans after partial cp (was 11 silent orphans pre-v0.3) |
| **`xcodebuild` of FSKit ext + app** | All three Xcode schemes build clean | ✅ in CI |
| **FSKit extension mount in Finder** | Drive actually mounts via our extension | ❌ requires SIP-off / entitlement |
| **Windows `chkdsk /f`** | Microsoft's own fsck accepts our writes | ❌ requires Windows machine |
| **Multi-day endurance** | Mount + many writes + power cycle + remount | ❌ requires real installation |

The first 6 are the strong correctness signals. The last 3 are physical-world tests that depend on you.

## What's pending — only you can do

These are the items the automated work simply can't reach. Each one is a single concrete action.

### 1. FSKit mount validation on the M4 (the only gate left)

**Why it matters:** the FSKit extension is structurally complete and builds
clean, but has **never been loaded by macOS's FSKit runtime**. The first run is
the first real test of Info.plist / entitlements / `FSPersonalities`
registration, whether macOS picks our extension over Apple's driver, whether
Finder drag-and-drop works, and whether the callback contract holds.

**Verified on this machine (2026-08-04):** macOS **26.1**, Xcode **26.1.1**,
SIP **enabled**, and `systemextensionsctl developer` refuses to run
("cannot be used if System Integrity Protection is enabled"). So Path A really
does require the reboot — there is no way around it from a running system.

| Path | Cost |
|---|---|
| **SIP-off + developer mode** | ~15 min, reversible |
| **Apple Developer Program FSKit entitlement** (`com.apple.developer.fskit.fsmodule` is restricted) | $99/yr + 2-14 day wait, no SIP change |

**Steps (Path A):**
1. Shut down. Hold the power button until *Loading startup options* -> **Options**
   -> Continue -> your user + password -> menu bar **Utilities -> Terminal**:
   `csrutil disable`, then reboot. Verify with `csrutil status`.
2. `sudo systemextensionsctl developer on`
3. `xcodebuild -project NTFSMountManager.xcodeproj -scheme NTFSMountManager -configuration Debug build`
4. **Move the built app to `/Applications` before launching.**
   `OSSystemExtensionManager` refuses to activate an extension whose containing
   app lives elsewhere, and the error it gives is unhelpful.
5. Launch it, trigger activation, approve in
   **System Settings -> General -> Login Items & Extensions** (macOS 26 moved this
   out of Security & Privacy).
6. `systemextensionsctl list` -> expect `activated enabled`.
   `activated waiting for user` means the approval did not land.
7. **Plug in a scratch NTFS USB stick** and find it:
   `diskutil list external physical`. Note the identifier (e.g. `/dev/disk6s1`);
   it can change on every replug, so re-check rather than reusing an old one.
8. Watch the logs in a second terminal, and leave this running for the rest of
   the test — it is the only view into which callback failed:
   `log stream --predicate 'subsystem == "com.ntfs-tool.fskit"' --level debug`
9. Release Apple's automount and create a mount point:
   `diskutil unmount /dev/diskNsM` then `sudo mkdir -p /tmp/m`.
10. Mount with OUR driver: `sudo mount -t ntfs_tool /dev/diskNsM /tmp/m`.
    Then check who actually took it: `mount | grep diskN` — the filesystem type
    in that line tells you whether ours or Apple's driver won.
11. `ls /tmp/m`, browse in Finder, then `cp ~/foo.txt /tmp/m/` to exercise the
    write callbacks.
12. `sudo umount /tmp/m` and eject: `diskutil eject /dev/diskN`.
13. Re-enable SIP when done (same Recovery procedure, `csrutil enable`).

**`FSName` is `ntfs_tool`, deliberately not `ntfs`.** Apple's own driver at
`/System/Library/Filesystems/ntfs.fs` claims `ntfs`, and a collision makes it
ambiguous which driver actually mounted a volume — the very question this gate
exists to answer. A distinct name selects ours explicitly and makes `mount`
output unambiguous.

**Correction:** earlier revisions of this document told you to run
`fskit_admin probe`. **That binary does not exist on macOS 26.1** (verified —
not in `/usr/bin` or `/usr/sbin`). Ignore any instruction referencing it. The
exact FSKit mount invocation on macOS 26 is unconfirmed; step 8 is the starting
point, and `mount | grep diskN` will show which driver actually took the volume.

Use a scratch stick. This code path has never executed, so expect the first run
to fail somewhere — most likely candidates are entitlement rejection under free
signing, the activation-from-`/Applications` requirement, or callback
sequencing.

### 2. Windows `chkdsk` round-trip — ✅ DONE (2026-08-04, v0.7.4)

**PASSED.** `chkdsk f:` (read-only) on a 7.9 GB stick Windows-quick-formatted
and then written entirely by `ntfsctl`:

```
Stage 1: 16069 file records processed. File verification completed.
         40 large file records processed. 0 bad file records processed.
Stage 2: 24951 index entries processed. 0 unindexed files scanned.
Stage 3: Security descriptor verification completed. 4441 data files processed.

Windows has scanned the file system and found no problems.
No further action is required.
```

Corpus: 11,568 files / 741 MiB, `$MFT` grown 256 → 16,069 records, 40 migrated
files carrying `$ATTRIBUTE_LIST`. Before the v0.7.4 fixes the same corpus
produced 41 `Attribute record (80, "") … is corrupt` + 39
`Attribute records … are unsorted` + `The Volume Bitmap is incorrect`.

**Run it read-only first.** `chkdsk X:` without `/f` reports problems without
repairing them; `/f` silently fixes and destroys the evidence of what we got
wrong. Every defect in v0.7.4 was diagnosed from a read-only run plus a raw
`dd` of `$MFT`.

**Reproducing the loop** (roughly 15 min per cycle):
1. Quick-format the stick on Windows — NOT a full format, and not our own
   formatter. A quick format leaves `$MFT` at 256 records so the auto-grow and
   headroom paths are actually exercised; a volume with a large pre-allocated
   `$MFT` silently skips them (the weak-oracle trap that hid the bug).
2. `diskutil unmount /dev/diskNsM` — Apple's FSKit mount holds the device open.
3. `ntfsctl create <dev> <dir> --directory`, then `ntfsctl cp -r --progress <corpus> <dev> /<dir>/`.
4. `ntfsctl verify --deep <dev>` — must report 0 orphans AND **0 leaked clusters**.
   The leaked-cluster line predicts chkdsk's bitmap verdict directly.
5. `ntfsctl setdirty <dev> 0`, `diskutil eject`, then `chkdsk X:` on Windows.

Keep the source tree quiet during the copy: a concurrent build rewriting a
source file mid-read is what triggered the v0.7.4 cluster leak.

**Still unproven by this gate:** `chkdsk /f` (write-mode repair) has never been
run, and no power-loss / eject-mid-write recovery has been tested. A crash
inside the write window still leaks clusters by design — that is chkdsk's job,
and only an in-process error is now self-healing.

### 3. License decision — ✅ DONE

**MIT**, in [`LICENSE`](../LICENSE) at repo root, linked from the README. The
NTFS implementation is a clean-room port from public format docs, so no GPL
obligation attaches. `docs/CLI.md` carries no license section (it never said
"TBD" — this entry did).

### 4. Manual write test against the real WD drive — ✅ DONE (2026-05-18, v0.2.0 candidate)

Hardware round-trip validated on the user's 4 TB WD My Passport against v0.2.0
(release binary built from `bac8d31`). End-to-end sequence:

```
diskutil unmount /dev/disk10s1
echo "hardware round-trip $(date)" > /tmp/htest.txt
sudo ntfsctl cp /tmp/htest.txt /dev/disk10s1 /hello-from-ntfsctl.txt -v
# → cp /tmp/htest.txt -> recnum 16 (49 B); done: 1/1 files, 49 B/49 B
diskutil mount /dev/disk10s1
cat "/Volumes/My Passport/hello-from-ntfsctl.txt"
# → hardware round-trip Mon May 18 12:27:18 IST 2026   ← byte-exact via Apple's driver
diskutil unmount /dev/disk10s1
sudo ntfsctl rm /dev/disk10s1 /hello-from-ntfsctl.txt
diskutil mount /dev/disk10s1
# → drive re-mounts cleanly, ntfsctl verify post-test returned to baseline
#   (42 in-use, 26 user, 0 orphans, 0 dangling)
```

That validates:
- The `cp` host→volume write path on real hardware (bitmap allocator T1.1,
  LARGE_INDEX insert, dirty-bit + fsync session safety).
- Apple's NTFS driver accepts our writes byte-exact on re-mount (the strong
  cross-driver signal — would-be corruption surfaces here).
- The `rm` path correctly removes the entry; subsequent re-mount + verify
  show the volume back to baseline.
- The `verify` full-MFT sweep (104,192 records on this drive) runs cleanly.

Remaining hardware tests deferred to user:
- **Windows `chkdsk /f` round-trip** (item §2 below) — only authority that
  Microsoft itself trusts. Requires a Windows machine.
- **Long-running stress test** (copy a few GB of phone-backup data over a
  real session, eject + remount, verify integrity). Optional.

## What's pending — engineering follow-ups

Ordered by user impact. Each is a focused piece of work appropriate for a single PR.

### High-impact

1. ~~**Path-based subcommand resolution.**~~ ✅ Done.
2. ~~**LARGE_INDEX leaf split.**~~ ✅ Done (T1.2 in v0.2; silent-orphan bug fixed in v0.3 — `splitLeafAndPromote` now computes parent-record overflow check before any leaf disk write). Directories grow past the single-leaf cap; tested to 75+ inserts. Validated on real 4 TB WD My Passport drive (22,419-file phone-backup cp -r → fails at file 63 with clean `unsupportedFeature` abort, **0 orphans**, was 11 silent orphans pre-v0.3). The actual remaining cap is `$INDEX_ROOT` itself needing to split (multi-level interior tree) — see follow-up #11 below.
3. ~~**Partial mid-file overwrites.**~~ ✅ Done.
4. ~~**Streaming `cat` for large files.**~~ ✅ Done.
5. ~~**Stale `$FILE_NAME` size hints.**~~ ✅ Done for both resident and LARGE_INDEX parents (T1.3).
6. ~~**`mtime` updates on write.**~~ ✅ Done (T1.4). `atime` deferred — most NTFS-on-Windows volumes have atime updates disabled by default (perf), no value-add for this CLI.
7. ~~**`$MFT.$DATA` growth.**~~ **Partial.** `growMFTDataByClusters()` + `growMFTBitmapToCoverBytes()` + runlist-aware MFT reads are implemented and tested in isolation (75-insert small-dir round-trip clean). NOT auto-invoked from `allocateMFTRecord` in v0.2 — the interaction with a second LARGE_INDEX leaf split corrupts state in a way I haven't been able to track down. Real Windows-formatted drives reserve ~12.5% of the volume for $MFT growth, so on a 4 TB drive `allocatedSize` covers hundreds of millions of records — plenty for phone-backup workloads without auto-grow. The framework is there; flip the retry loop in `allocateMFTRecord` back on once the second-split bug is found.
8. **`cp --resume`.** Skip files already present at destination (by name + size match, or optional SHA-256). Important for multi-GB copies over flaky USB. ~1 day.
9. **Streaming bitmap reader.** `$Bitmap` is loaded whole into RAM (~250 MB for 8 TB volumes). Chunk on demand. ~1-2 days. Defer to v0.4.
10. **`cp -r` bulk-write perf.** Three contributors. **(a)** ~~`refreshParentI30Size` deferral~~ ✅ Done (v0.4 Phase 1). `Volume.beginBulkInsert(into:)` / `endBulkInsert()` defer per-file size-hint refreshes. **(b)** ~~INDX-leaf coalescing~~ ✅ Done (v0.4 Phase 2). `BulkLeafCache` holds parsed leaf state across consecutive inserts; 50-file batches collapse 50 leaf reads + 50 leaf writes into 1 read + 1 final write. Combined ~3-5× speedup expected. **(c) async write pipelining** — issue write N+1 while N is in flight. Bigger refactor (~3-5 days); v0.4 Phase 4, conditional on whether (a)+(b) are enough.
11. **`$INDEX_ROOT` multi-level split.** ✅ **All four sub-phases done.** Phase 3(A) — `$INDEX_ROOT` height-grow (tree depth 2 → 3). Phase 3(B) — promote median into intermediate INDX block (depth-3 fits case). Phase 3(C) — recursive cascade (when an intermediate overflows, bisect + promote up the chain). Phase 3(D) — height-grow root after cascade exhausts the chain. **Per-dir capacity is now bounded only by free clusters and MFT slots on the volume — no algorithmic cap.** The small fixture caps at ~1077 inserts due to MFT-slot exhaustion (slot 1100 past `$MFT.$DATA`'s allocatedSize); real 4 TB volumes have ~500 million MFT slots, so a single directory can hold any practical number of files.

    **v0.5 follow-up — `$INDEX_ALLOCATION` runlist cap (file ~350 on real hardware): read + migration write path ✅ landed.** Step 1+2 read-path foundation (`Volume.resolveAttribute` / `allAttributesOf` + `$ATTRIBUTE_LIST` entry parse/serialize) landed earlier in v0.5. Step 3 — the migration write path — now lands: when `$INDEX_ALLOCATION:$I30`'s runlist would overflow the base record's slack, the attribute is migrated to a fresh extension MFT record and a resident `$ATTRIBUTE_LIST` (type 0x20) is built on the base. Compute-first transactional commit; orphan rollback via `reclaimOrphanedMFTRecord` on any failure between extension-slot allocation and final base write. 3 new unit tests; 120/120 NTFSCore tests pass.

    **v0.5 follow-up — unnamed `$DATA` runlist cap (file 350 on real hardware): migration write path ✅ landed (Step 4).** Step 4 generalizes Step 3's migration so it ALSO handles a file's own non-resident unnamed `$DATA` (type 0x80), not just directory `$INDEX_ALLOCATION` (0xA0). When the `$DATA` runlist would overflow the base MFT record (the bug that aborted a hardware `cp -r` at file 350 with "would overflow record … type 0x80"), `$DATA` is migrated to a freshly-allocated extension MFT record and a resident `$ATTRIBUTE_LIST` is added to the base — the `$DATA`-overflow safety net is now in place. The shared builder from Step 3 is generalized to accept any overflowing attribute type and reused unchanged, so the 0xA0 path has no behavior change. Same compute-first transactional commit (extension committed first, base second, orphan MFT slot reclaimed on any failure). Reads follow the `$ATTRIBUTE_LIST` to the extension and return content byte-identical. New unit tests cover the end-to-end `$DATA` migration, the migrated full-file read round-trip, and the fail-closed guard for the deferred paths. **Deferred (fail-closed with a clean error, never corruption):** a SUBSEQUENT write to an already-migrated file, and a ranged `readFileSlice` of a migrated file, are not yet supported — both hit a clean error rather than a partial mutation; full-file reads of migrated files are complete.

    **chkdsk-clean on-disk shape after migration:** the shape below describes the `$INDEX_ALLOCATION` (0xA0) directory migration; the `$DATA` (0x80) migration produced by Step 4 has the same structure — a resident `$ATTRIBUTE_LIST` body on the base plus an extension record whose `baseFileReference` is packed back at the base, with the non-resident `$DATA` runlist relocated to the extension. Both shapes are chkdsk-clean.
    - `$STANDARD_INFORMATION` (type 0x10) — stays resident in the base record (chkdsk requirement).
    - `$FILE_NAME` (type 0x30) — stays resident in the base record (chkdsk requirement).
    - `$ATTRIBUTE_LIST` (type 0x20) — resident on the base record; body lists every attribute the file owns (base + extension), sorted per NTFS canon (type ascending, then name UTF-16, then lowestVCN). Each entry's `mftReference` packs as `(UInt64(seq) << 48) | (recnum & 0x0000_FFFF_FFFF_FFFF)`.
    - Extension MFT record — IN_USE flag set, DIRECTORY bit clear, `baseFileReference` packed back at the base record's reference (same 48-bit recnum / 16-bit sequence layout). `mftRecordNumber` populated; USA fix-up applied.
    - `$INDEX_ROOT:$I30` (type 0x90) — stays resident in the base record.
    - `$INDEX_ALLOCATION:$I30` (type 0xA0, non-resident) — relocated to the extension record with its full runlist.
    - `$BITMAP:$I30` (type 0xB0) — stays in the base record in this PR (Step C bitmap migration is deferred).

    **v0.5 follow-up — next-fit cluster allocator with rolling hint ✅ landed.** Independent of the `$INDEX_ALLOCATION` migration above, this attacks the OTHER half of the file-350 abort: `$DATA` runlist fragmentation. The old allocator did first-fit-from-cluster-0, so after an `rm -r` punched scattered holes near the start of the volume, every subsequent small-file write refilled those holes one cluster at a time. On the real 22,419-file WD My Passport `cp -r`, a thumbnail at file ~350 produced a 696-byte `$DATA` attribute (~200 fragments) that overflowed its base MFT record. The fix: a next-fit allocator with a rolling per-`Volume` search hint (`_allocHint`) plus wrap-around `Bitmap.findFreeRun`, modeled on Windows NTFS's rolling allocation pointer / `fs/ntfs3`'s `data_zone` hint (rolling-hint subset only — no MFT-zone reservation). Sequential writes during a `cp -r` now allocate contiguous, single-extent runlists. `findFreeRun` scans `[hint, clusterCount)` then `[0, hint)` so no free space below the hint is stranded; a free run never spans the wrap boundary; `freeClusters` does NOT rewind the hint (rewinding would re-introduce fragmentation by refilling just-freed holes). **Caveat:** `_allocHint` is in-memory per-`Volume`-instance state — it resets to 0 on each fresh `Volume` open (each `ntfsctl` invocation) and is NOT persisted on disk in v0.5; it persists across all files within a single long-lived `cp -r` process, which is the workload that matters. 7 new unit tests in `AllocatorTests.swift`; 127/127 NTFSCore tests pass. Hardware re-validation of the 22,419-file `cp -r` deferred to user.

    **v0.5 follow-up — `verify` / `reclaim-orphans` extension-record awareness ✅ landed.** Once Steps 3/4 began creating extension MFT records (records with `baseFileReference != 0` holding migrated `$INDEX_ALLOCATION` / `$DATA`), the old orphan walk in both commands — `orphans = inUse \ reachable-from-$I30` — false-flagged every extension record as an orphan (they're legitimately in use but reachable ONLY via their base's `baseFileReference`, never via a `$I30` entry). `reclaim-orphans --confirm` would then have FREED them, detaching the migrated attribute and corrupting the base file. Both commands now share a pure, disk-I/O-free classifier (`MFTConsistency.classifyInUseRecords`, `Packages/NTFSCore/Sources/NTFSCore/MFTConsistency.swift`) that partitions IN_USE user records into base records, orphaned base records (the only reclaim target), legitimate extensions (base in use — never an orphan, never freed), and leaked extensions (base gone — a real defect, reported with a `chkdsk /f` recommendation but never auto-freed in v0.5). `verify` adds an `Extension records: N (linked)` line and a `leaked extension (base record free)` error class; `reclaim-orphans` adds a defensive guard/precondition so a future refactor can't re-route an extension into the reclaim set. 3 new unit tests in `MFTConsistencyTests.swift`; 133/133 NTFSCore tests pass; CLI builds clean.

    **v0.5 follow-up — resident `$BITMAP:$I30` growth ✅ landed.** A directory's resident `$BITMAP:$I30` attribute (type 0xB0, name `$I30`) was created with a fixed 8-byte body tracking only 64 `$INDEX_ALLOCATION` INDX blocks; allocating a 65th block threw `unsupportedFeature("updateBitmap: block index 64 exceeds bitmap capacity 64; growing $BITMAP not yet supported")`. On the real 22,419-file WD My Passport phone-backup `cp -r` this aborted the copy at file 1611. `Volume.updateBitmapAttribute(attrs:blockIndices:)` now grows the resident bitmap in place: when a requested block index falls beyond the current body it appends zero bytes, rounding the new length UP to a multiple of 8 bytes (NTFS index-bitmap alignment), then sets the bit. Growth is append-only zero-fill — never a rebuild, truncate, or reorder — so every previously-set bit survives; the growth re-checks inside the multi-index loop so a later index in the same call can trigger a second growth. **Parent-record-overflow stays fail-closed:** if the grown resident bitmap ever exceeded the base MFT record's slack, the existing rewrite path (`rewriteEntireAttribute`, routed through the 0xB0 rewrite in `rewriteParentForLeafSplit`) detects the overflow and throws a clean `NTFSError.unsupportedFeature` while building its output into a fresh buffer — no partial write reaches disk. **At the v0.5 8-byte growth increment this boundary is effectively unreachable**, so AC-3 was satisfied by documenting the boundary as unreachable + confirming the clean-throw path by reading `rewriteEntireAttribute`, not by manufacturing an overflow test. 2 new unit tests in `IndexBitmapGrowthTests.swift` (`testI30BitmapGrowsPast64Blocks` drives root to 65 INDX blocks, reopens, and asserts the body grew past 8 bytes, block-64's bit is set, all first-64 bits survive, every inserted name enumerates, zero orphans; `testI30BitmapGrowthIsEightByteAligned` asserts the body length stays a multiple of 8). Hardware re-validation of the file-1611 `cp -r` deferred to user.

    **v0.5 follow-up — `$ATTRIBUTE_LIST`-aware delete + `reclaim-orphans` of base-free leaked extensions ✅ landed.** The Step 3/4 migration write paths create extension MFT records but, until now, had no symmetric teardown — so `rm -r` of a migrated tree leaked every extension record and its migrated clusters, and an already-leaked volume could only be repaired with `chkdsk /f`. Two complementary halves close the loop. **(1) Delete-path fix:** `Volume.deleteFile(at:)` is now `$ATTRIBUTE_LIST`-aware — when a base record carries a `$ATTRIBUTE_LIST` (type 0x20) it walks the list and, for each distinct extension record, frees that record's non-resident clusters AND its slot (IN_USE off, sequence bumped, `$MFT.$BITMAP` bit cleared) before freeing the base. Non-migrated files take the same fast path as before; the operation is idempotent (re-run / recycled-slot = clean no-op, sequence-number guarded). New `Volume.freeExtensionRecord(at:)` frees ONE extension record fully (clusters then slot), shared by `deleteFile` and the reclaim path. **(2) Reclaim enhancement:** `reclaim-orphans --confirm` (`Tools/ntfsctl/Sources/ntfsctl/Reclaim.swift`) now reclaims confirmed-base-free leaked extension records (clusters + slot). A leaked extension is reclaimable ONLY when its owning base record is AUTHORITATIVELY read off disk and confirmed IN_USE=0 — the split is computed by the new pure `MFTConsistency.splitLeakedExtensions(_:leakedExtensions:basesConfirmedFree:)` → `LeakedExtensionSplit { baseFreeExtensions, baseUnresolvedExtensions }`, default-deny so a live file's extension (base in use, unparseable, or absent) is never freed and defers to `chkdsk /f`. A volume leaked by an older build is now cleanable with `ntfsctl` alone. **8 new unit tests** (4 delete/`freeExtensionRecord` in `AttributeListMigrationTests.swift` — frees base + extension, restores the free-cluster count to the pre-write baseline, zero leaked extensions on reopen, idempotent; 4 pure-classifier `splitLeakedExtensions` cases in `MFTConsistencyTests.swift`); **143 NTFSCore tests pass, 0 failures** (the two-concurrent-migrations test XCTSkips — the 4 MiB fixture can't host two ~250-fragment migrated files; that per-record "don't free the wrong record" guarantee is covered by the classifier tests). CLI builds clean.

    **v0.5.1 follow-up — `truncate` clean-error on migrated files + FSKit migrated-file size + file-attribute-path extension-awareness audit CLOSED ✅ landed.** Two complementary fixes close the file-attribute-path side of the Step 3/4 migration work. **(1) `Volume.truncate(at:newSize:)` clean-error:** a migrated file (base carries a `$ATTRIBUTE_LIST` (type 0x20), unnamed `$DATA` relocated to an extension record) was unrecognized by `truncate` — its paths read base-only `$DATA` and free its extents (which on a migrated file live in the extension, so they'd be missed), and the lacks-`$DATA` guard would mis-report a healthy migrated file as `corruptOnDisk`. `truncate` now detects the base `$ATTRIBUTE_LIST` and throws `NTFSError.unsupportedFeature("truncate: MFT record N has $ATTRIBUTE_LIST (migrated $DATA in extension); truncating a migrated file is not yet supported")` for ALL `newSize` (incl. 0), **before** freeing clusters or writing anything — the rejected truncate leaves volume state byte-identical (fail-closed, never corruption). **(2) FSKit migrated-file size:** `makeFreshAttributes` (Xcode-only target, not swift-testable) now reads `$DATA` size via `coreVolume.allAttributesOf(recordNumber:)`, which walks `$ATTRIBUTE_LIST` into the extension record and surfaces the migrated unnamed `$DATA` at its exact `realSize` — Finder now reports the correct size for migrated files instead of a base-only zero/wrong size. **Audit closed:** with these two fixes, every file-attribute mutation/read path is migration-aware or cleanly deferred. The other paths were confirmed already-correct / already-deferred: `rename` operates on `$FILE_NAME` + the parent `$I30` (both stay resident in the base record — unaffected by `$DATA` migration); `write` / `writeFile` to an already-migrated file fail closed with a clean error (the deferred post-migration write follow-up below — never a partial mutation); `deleteFile` is already `$ATTRIBUTE_LIST`-aware (v0.5 — frees extension records + their migrated clusters). **2 new unit tests** in `AttributeListMigrationTests.swift`: `testAllAttributesOfReturnsMigratedDataWithCorrectSize` (forces a `$DATA` migration with a known byte length, confirms the base no longer holds the unnamed `$DATA`, and asserts `allAttributesOf` surfaces the migrated non-resident `$DATA` at exactly the bytes written — the indirect proof for the un-swift-testable FSKit `size` read) and `testTruncateMigratedFileThrowsCleanUnsupported` (asserts `truncate` throws `unsupportedFeature` — never `corruptOnDisk` — for a non-zero shrink AND 0, with zero clusters freed and the file still reading its original bytes via the migrated `$DATA`, proving the guard bails pre-mutation). **145 NTFSCore tests pass** (was 143), 1 skip, 0 failures.

    **v0.5 follow-up — post-migration `$INDEX_ALLOCATION` leaf-split routing (lifts the hardware ~file-6,139 cap) ✅ landed.** Closes the "Post-migration write path" item in the follow-ups list below. Once a directory's `$INDEX_ALLOCATION:$I30` migrated to an extension MFT record (the v0.5 Step 3 machinery that lifts the original ~350-file cap), the LEAF-SPLIT rewrite path (`rewriteParentForLeafSplit` → `rewriteEntireAttribute`) still rewrote the attribute in the BASE record's byte stream — but the base no longer holds it; the migrant lives in the extension. Confirmed against `main` @ 751cd9f via a controlled probe: the first post-migration leaf split that must grow `$INDEX_ALLOCATION` throws `corruptOnDisk: rewriteEntireAttribute: target type 0x000000A0 name '$I30' not found` within ~16 inserts of migrating — so the directory could not grow past migration at all. On the real 4 TB WD hardware (next-fit allocation kept the resident runlist compact) migration first fired around file 6,139 and immediately hit this wall; the `would overflow record … type 0xA0` in the hardware log is the migration TRIGGER, the fatal error is this "target not found". **Fix:** `rewriteParentForLeafSplit` is now `async` + extension-aware (`ParentRewrite { baseBytes, extensionWrites }`). When the base carries a `$ATTRIBUTE_LIST`, the rewrite locates `$INDEX_ALLOCATION:$I30` / `$BITMAP:$I30` via that list, rewrites them in the EXTENSION record's bytes (new `rewriteMigratedAttributeInExtension`, `rewriteEntireAttributeWithHeaderUpdate`), and returns those rewritten extension bytes for the caller. All split call sites thread `extraRecordWrites` through `ComputedSplit` and commit extension records BEFORE the base — matching `migrateAttributeOnOverflow`'s compute-first, extension-first transactional discipline. If `$INDEX_ALLOCATION` and `$BITMAP` share the same extension record (the common case), both edits are applied to ONE buffer and emitted as ONE write so the second edit can't clobber the first. A SECONDARY corruption surfaced during testing — the cascade → root-overflow → `heightGrowIndexRoot` path was returning a `ComputedSplit` that DROPPED `grown.extraRecordWrites`, so a base `$INDEX_ROOT` pointed at fresh intermediate VCNs whose backing extension runlist write was never persisted, orphaning one whole INDX leaf's worth of entries (the pre-existing `splitLeafAndPromote` consistency guard caught it as `post-split state mismatch missing=36`). Threading `extraRecordWrites: grown.extraRecordWrites` through that return makes the post-split state self-consistent. **Validation:** the probe shows post-migration inserts go from **16** (main) to **2,092** (fixed) on `small.img` — a 130× lift — bounded only by the fixture's 4 MiB capacity, not by any structural index ceiling. **3 new unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/IndexAllocationGrowthTests.swift`: `testPostMigrationGrowthLiftsCeilingAndIsAuditClean` (AC-1/AC-6 — force migration, drive 1,500 post-migration inserts that exercise the cascade → height-grow path, assert all enumerated, reopen-clean, orphan-free, `auditAllDataRunlistsAgainstBitmap` clean — would FAIL on `main` within ~16 inserts), `testPostMigrationGrowthLayoutIsSpecConformant` (AC-4 — hand-decode the base `$ATTRIBUTE_LIST` body byte-by-byte with an independent reader, assert canonical `(type, name, lowestVCN)` sort order, the migrant entry points at the extension with matching sequence, and the extension's rewritten `$INDEX_ALLOCATION` non-resident header + runlist are spec-clean — same PR-#26 / `MigratedDataSpecConformanceTests` pattern), and `testPostMigrationGrowthToExhaustionLeavesNoLeak` (AC-6 transactional — drive growth to exhaustion, assert the termination is a cluster/slot exhaustion (`outOfSpace` or `$MFT.$DATA` can't auto-grow) and never a structural index error; assert no orphan extension, audit clean post-reopen). **159 NTFSCore tests pass** (was 156), 1 skip, 0 failures. **Next structural ceiling (named honestly):** once the migrated `$INDEX_ALLOCATION` runlist fills the EXTENSION record (1024 B), the same `would overflow record … type 0xA0` will fire IN the extension — the fix needed there is a SECOND extension record / multi-extension `$INDEX_ALLOCATION` (a `$ATTRIBUTE_LIST` carrying multiple 0xA0 entries at increasing `lowest_vcn`, each pointing at the right extension record). NOT reachable on the 4 MiB `small.img` fixture (small.img runs out of clusters first); defer until a larger fixture (`mkntfs` on a Linux VM) makes it reproducible.

    **v0.5 investigation — multi-extent `$DATA` portability blocker: suspected encoding root cause DISPROVEN; real cause remains OPEN (negative result).** A release-blocker report claimed the multi-extent `$DATA` files we write are unreadable by spec-strict NTFS readers (Apple's native macOS driver) due to a multi-extent runlist encoding bug. A thorough diagnosis DISPROVED that premise by INDEPENDENT spec-strict verification (a hand-written, spec-strict decoder, NOT our own `DataRun.decode`). The suspected encoding bug does NOT exist. The following were each proven spec-conformant and are now landed as PERMANENT regression guards:
    - **`Packages/NTFSCore/Tests/NTFSCoreTests/MultiExtentDataTests.swift`** — the REAL `encodeRunlist` is byte-perfect across all signed-width boundaries (incl. 5-byte deltas, large absolute LCNs, backward deltas); the non-resident `$DATA` header coverage fields (`lastVCN` / `allocatedSize` / `initializedSize`) are consistent with the runlist; and an END-TO-END independent physical-cluster read in runlist order reassembles the payload BYTE-EXACT. Includes `testMultiExtentDataAttributeIsSpecConformant` (a focused >=3-extent guard with a large absolute first LCN + a backward delta) and a single self-contained boundary-byte dump (`testDumpEncoderBoundaryBytes`).
    - **`Packages/NTFSCore/Tests/NTFSCoreTests/MigratedDataSpecConformanceTests.swift`** — for a migrated `$DATA` (extension record + resident `$ATTRIBUTE_LIST`), the `$ATTRIBUTE_LIST` entries, the extension `baseFileReference`, and the extension `$DATA` header + runlist are all spec-clean against the independent reader, and the physical content reassembles byte-exact.

    **Hypotheses ELIMINATED:** multi-extent runlist encoding; non-resident header coverage fields; physical placement/order; migration / `$ATTRIBUTE_LIST` linkage; `$MFT` self-growth (auto-grow is DISABLED in v0.2 per `Volume.allocateMFTRecord`, and a 4 TB `$MFT` is pre-sized, so the bulk copy never grew `$MFT`); USA/update-sequence-array fixup (read and write both source `blockSize` from `boot.bytesPerSector` — symmetric and spec-correct).

    **STILL OPEN:** the real hardware I/O-error is NOT reproducible in this `.img`-fixture toolchain; pinning it requires hardware-side diagnostics. **Next-step hardware diagnostics** (on the actual WD drive that fails):
    - (a) dump a FAILING file's raw 1024-byte MFT record and confirm whether its `$DATA` is in-base multi-extent or migrated to an extension record;
    - (b) dump and independently decode that file's actual on-disk `$DATA` runlist AND the `$MFT`'s own runlist;
    - (c) run `ntfs-3g` / `chkdsk` / `ntfsfix` against the drive (or a `dd` image of the affected region) to capture the SPECIFIC complaint;
    - (d) verify the file's clusters are marked allocated in the volume `$BITMAP`.

    **`verify` follow-up (brief AC-8):** consider having `ntfsctl verify` optionally RESOLVE each `$DATA` runlist (read each mapped cluster) to catch content-addressing bugs it currently misses — `verify` today only checks MFT reachability + parse, never that a file's mapped clusters are actually readable.

    **v0.7 — multi-extension `$ATTRIBUTE_LIST` for `$INDEX_ALLOCATION:$I30` ✅ landed (2026-05-28).** Lifts the ~file-7,997 single-directory cap that PR #34 documented as the next structural ceiling. Before v0.7, once a directory's migrated `$INDEX_ALLOCATION:$I30` runlist filled its EXTENSION MFT record (~1 KiB of runlist slack), the next `would overflow record … type 0xA0` fired inside the extension — PR #34 made that path throw a user-actionable `NTFSError.unsupportedFeature("multi-extension $ATTRIBUTE_LIST required for $INDEX_ALLOCATION:$I30 …")`. v0.7 implements the fix:
    - **Write path:** `AttributeMigration.buildAdditionalExtensionForAttribute` allocates a fresh extension MFT record, splits the existing extension's runlist at an extent boundary (split-VCN), and appends a SECOND `$ATTRIBUTE_LIST` entry naming the new extension at `lowestVCN = splitVCN`. Compute-first / extension-first transactional discipline (matches the existing `migrateAttributeOnOverflow` pattern): the new extension is written first, then the existing extension's truncation + the base's `$ATTRIBUTE_LIST` rewrite are committed together. A `#if DEBUG` `_setMultiExtensionFaultHook` seam allows injecting a fault between the new-extension write and the existing-extension/base commit; on throw the new MFT slot is reclaimed and the base is byte-identical to pre-fault (`testMultiExtensionIATransactionalFailure` covers this).
    - **Read path:** new `Volume.mergeMultiExtensionAttribute(in:rawType:name:)` is the canonical merge seam. Given a flat attribute list (base + all extensions, the output of `allAttributesOf`), it returns a single synthetic `Attribute` whose extent list is the union of all matching `(rawType, name)` entries sorted by VCN. Used at all 12 audited read-side callsites in `Volume.swift` and `RunlistBitmapAudit.swift` — including `auditDataRunlistAgainstBitmap` (line 243) and `resolveDataExtents` (line 601), so `verify --deep` and `dump` walk merged extents with no double-counting (each VCN is in exactly one extension's runlist).
    - **AC-7 (dump / verify --deep awareness):** `dump` (`Tools/ntfsctl/Sources/ntfsctl/Dump.swift`) drives every per-extent classification from `volume.auditDataRunlistAgainstBitmap` which already routes through `mergeMultiExtensionAttribute` — no routing change needed. `verify --deep` calls `auditAllDataRunlistsAgainstBitmap` which sweeps every base record's `$DATA` via the same merged path. `testMultiExtensionVerifyDeepClean` drives a directory to the multi-extension shape, reopens, runs the deep audit, and asserts `isClean == true` AND `doubleAllocatedClusters == 0`; it also re-reads both extensions' migrant `$INDEX_ALLOCATION:$I30` runlists directly and asserts their VCN ranges are disjoint and contiguous (no double-counting by construction). Note that `auditDataRunlistAgainstBitmap` audits `$DATA` (not `$INDEX_ALLOCATION` directly) — the AC-7 evidence is that a volume which carries the multi-extension `$INDEX_ALLOCATION` shape doesn't trip ANY of the audit's failure categories. The directory-side `$INDEX_ALLOCATION` audit is a separate feature, out of scope for v0.7.
    - **Per-directory capacity** is now bounded only by free clusters + MFT slots on the volume — no algorithmic cap from extension-record size. **The PR #34 `unsupportedFeature("multi-extension $ATTRIBUTE_LIST required")` error path is now unreachable for `$INDEX_ALLOCATION:$I30` overflow.** It remains the fail-closed path for hypothetical analogue overflows on attributes that don't yet have the multi-extension write path implemented (e.g. `$DATA` multi-extension is not implemented in v0.7 — see follow-ups below).
    - **Tests:** **217 NTFSCore tests pass (was 216), 1 pre-existing skip, 0 failures, CLI release builds.** New test added: `testMultiExtensionVerifyDeepClean` in `MultiExtensionIndexAllocationTests.swift` (the AC-7 evidence). Pre-existing coverage in the same file: `testSecondMigrationAddsAdditionalExtension`, `testMultiExtensionIATransactionalFailure`, `testMultiExtensionIASpecConformantBytes`, `testMultiExtensionIAReadbackRoundTrip`, `testMergeMultiExtensionAttribute_unitContract`.
    - **Hardware re-validation pending** — user manual step. Reformat the drive and re-run a full-corpus `cp -rT` past the ~file-7,997 mark; `verify --deep` must report 0 dangling, 0 orphans, 0 leaked extensions, 0 free-but-referenced / out-of-range / double-allocated clusters.
    - **Follow-ups deferred:** multi-extension `$DATA` (0x80) — same shape, different attribute type — would close the file-level analogue, but is not driven by any known hardware failure mode and is not implemented in v0.7. Non-resident `$ATTRIBUTE_LIST` (when the resident `$ATTRIBUTE_LIST` body itself exhausts base slack) remains the v0.5 fail-closed path. Both tracked in the Remaining v0.5 follow-ups list below.

    **v0.5.2 follow-up — leaf-split migration-catch gap on two formerly-uncaught call sites + `$I30` ↔ MFT-allocate atomicity ✅ landed (2026-05-28).** Closes two regression holes PR #29's 2026-05-27 hardware re-run exposed. **(Bug A)** PR #29's "cap lifted" claim was incomplete: after the refactor `rewriteParentForLeafSplit` was called from six sites in `Volume.swift`, and two of them (the call inside `heightGrowIndexRoot`, and the call in `promoteThroughInteriorChain`'s `!cascadeExhaustedChain` early-return branch) remained outside any `isOverflowDescription` catch. The hardware re-run aborted with `rewriteEntireAttribute: new attribute (504 bytes) would overflow record (used 1020, record 1024, type 0xA0)` and `dump` on the active insertion target (`WhatsApp Images`, recnum 2998) showed `Migrated ($ATTR_LIST): no` — migration never fired on the directory hosting the overflow. Fixed by introducing `rewriteParentForLeafSplitMigrating` — a thin async wrapper that catches `$IA`-typed overflow, runs `migrateIndexAllocationOnOverflow`, refreshes the parent, and retries once. The two formerly-uncaught sites now route through the wrapper; the other four call sites (already inside the existing catches at the resident-rewrite block and the cascade-exhausted block) call the raw function unchanged. **(Bug B)** Post-error `verify --deep` reported `Dangling ($I30 entry but MFT slot free): 2` — two `$I30` entries pointing at MFT recnums whose IN_USE flag had been cleared. Cause: `createFile`'s pre-fix discipline freed the orphan MFT slot on ANY post-commit throw, leaving `$I30` dangling if the parent-side write had already hit disk. Fixed by reordering `createFile` to compute-first / commit-MFT-first / commit-`$I30` / track-`i30Committed`, mirroring `migrateAttributeOnOverflow`'s discipline; an `inout i30Committed: Bool` flag is threaded through `insertIntoParentI30` and set IMMEDIATELY before each on-disk parent-side write (resident `$INDEX_ROOT` rewrite, `LARGE_INDEX` leaf insert, `LARGE_INDEX` promote + recursive call). On throw: flag false → reclaim MFT slot (clean rollback); flag true → retain MFT slot as orphan-base (recoverable via `ntfsctl reclaim-orphans`, strictly safer than dangling). The `(record absent, $I30 present)` dangling state is now structurally unreachable from any throw inside `createFile`. Only three terminal states remain: `(absent, absent)` clean rollback, `(present, absent)` orphan-base, `(present, present)` success. **AC-1 caveat for Bug A (honest disclosure):** the 4 MiB `small.img` fixture exhausts MFT slots / free clusters at ~2100 files before the IA runlist can grow large enough to overflow base-record slack at the uncaught sites, so the new `LeafSplitMigrationCatchTests` (2 forward guards) pass on both pre-fix and post-fix code on `small.img` — they serve as post-fix correctness verification + forward regression guards. Wrapper correctness is established by code-reading (mirrors the existing cascade-exhausted catch pattern at the cascade-migration block, which passes all 162 baseline tests) plus the hardware evidence above. **Out-of-scope (explicitly):** `rename` / `delete` atomicity audits are deferred (per the job brief risk table); `rename`'s signature was updated for compile-time compatibility (threads a discarded local) with an `AUDIT-TODO(rename-i30-atomicity)` comment marking the follow-up. **Tests:** 167 NTFSCore tests pass (was 159), 1 skip, 0 failures, CLI builds clean. New: `CreateFileAtomicityTests.swift` (3 cases — `#if DEBUG` fault-injection seam `_setCreateFileFaultHook` exercises `.afterMFTWriteBeforeI30Commit`, `.afterI30CommitBeforeReturn`, and a happy-path control; audit decoders walk raw MFT bytes with USA fixup inlined and raw `$INDEX_ROOT` entries — no NTFSCore decoder is used to verify the shape under test, per AC-6 / PR #26 lesson) and `LeafSplitMigrationCatchTests.swift` (2 sustained-insert forward guards with the fixture caveat documented in the test header). **Hardware re-validation pending — user manual step.** After tagging v0.5.2: (1) truly reformat the drive (`mkntfs -Q` in Linux VM, or Windows quick format); (2) re-run the full-corpus `cp -rT --progress` on a freshly-formatted volume; (3) `verify --deep` — must report 0 dangling, 0 orphans, 0 leaked extensions, 0 unreachable. That is the clean baseline measurement of where the cap actually sits with both fixes in place. **Follow-up: larger fixture for AC-1 strict baseline-fail.** Build a 16 MiB+ `medium.img` (via `mkntfs` in the Linux VM — see project CLAUDE.md tooling section) so `LeafSplitMigrationCatchTests` can demonstrate the strict pre-fix FAIL → post-fix PASS shape inside the test corpus. Tracked under "Remaining v0.5 follow-ups" below.

    **Remaining v0.5 follow-ups (deferred — not blocking this PR):**
    - **Larger test fixture (16 MiB+ `medium.img`)** to make AC-1's strict baseline-fail reproduction observable for `LeafSplitMigrationCatchTests` and to enable end-to-end runtime cross-object delete-selectivity tests on two concurrent migrated files. The current 4 MiB `small.img` exhausts MFT slots / free clusters before structural index ceilings can be reached. Generate via `scripts/` / `mkntfs` in the Linux VM (see project CLAUDE.md tooling section).
    - **`rename` / `delete` atomicity audits.** Bug B's fix (`createFile` ↔ `$I30` atomicity) is scoped to file creation only. A throw between `rename`'s source-side `$I30` remove and target-side `$I30` insert could leave the file unreachable from both directories — see the `AUDIT-TODO(rename-i30-atomicity)` comment in `rename`. The general mutation-atomicity audit (rename, delete, partial truncate of a migrated file) was explicitly out of scope for v0.5.2 per the job brief risk table.
    - **Very large directories — non-resident `$BITMAP:$I30` / type-0xB0 base-record migration.** Resident `$BITMAP:$I30` now grows (above), but a directory with so many INDX blocks that the grown resident bitmap exhausts the base MFT record's slack still hits the fail-closed `unsupportedFeature` throw. The next step is to migrate `$BITMAP` (type 0xB0) to a non-resident attribute / extension MFT record via `$ATTRIBUTE_LIST` (the same migration machinery Step 3/4 use for `$INDEX_ALLOCATION` (0xA0) and `$DATA` (0x80)). NOT done yet. Practically unreachable within v0.5's small-fixture scope; defer until a real-world directory demands it.
    - **`reclaim-orphans` of an orphan base that owns extension records** — `reclaimOrphanedMFTRecord` frees only the base slot; it does not follow the base's `$ATTRIBUTE_LIST` to free that base's extension records. So if a *true orphan base* (in-use, unreachable) owns extensions, `reclaim --confirm` frees the base and leaves the extensions IN_USE — they surface as `leaked extension (base record free)` on the next `verify`. This fails safe (a detectable leak resolvable by `chkdsk /f`, never corruption) and is the read-side analogue of the `$ATTRIBUTE_LIST`-on-the-write-side follow-ups below. Fix later by either excluding extension-owning orphan bases from the reclaim set (report them as needing `chkdsk /f`) or walking `$ATTRIBUTE_LIST` to free the extensions too.
    - ~~**Post-migration write path** — subsequent inserts into an already-migrated directory ...~~ ✅ Done (2026-05-26, see the dedicated v0.5 follow-up below). `rewriteParentForLeafSplit` is now extension-aware: when `$INDEX_ALLOCATION:$I30` / `$BITMAP:$I30` have migrated, the rewrite is routed to the extension record that actually holds the attribute, with extension-first commit matching `migrateAttributeOnOverflow`'s transactional discipline. Confirmed against `main` @ 751cd9f: pre-fix the first post-migration leaf split throws `corruptOnDisk: rewriteEntireAttribute: target type 0x000000A0 name '$I30' not found` within ~16 inserts of migrating; post-fix 1,500+ inserts proceed cleanly, audit clean, no orphans. Lifts the hardware ~file-6,139 abort that triggered this follow-up.
    - **Post-migration `$DATA` write + ranged read (Step 4)** — a SUBSEQUENT write to an already-migrated file (whose `$DATA` already lives on an extension record via `$ATTRIBUTE_LIST`), and a ranged `readFileSlice` of a migrated file, are not yet supported. Both fail closed with a clean error (never a partial mutation, never corruption); the migration itself and full-file reads of migrated files are complete. This is the `$DATA` (0x80) analogue of the post-migration write-path follow-up above and would be addressed by the same `$ATTRIBUTE_LIST`-on-the-write/slice-side work.
    - **Step 3.5 — non-resident `$ATTRIBUTE_LIST`.** If the resident `$ATTRIBUTE_LIST` body itself wouldn't fit in base record slack, migration throws `unsupportedFeature("Fix B Step 3.5: $ATTRIBUTE_LIST exceeds parent slack — non-resident $ATTRIBUTE_LIST not yet implemented")` and the v0.4 cap continues to hold. Practically unreachable until a directory has very many attributes (many alternate data streams + named EAs). Defer until a real-world fixture demands it.
    - **`$BITMAP`-only Step C migration.** If `$BITMAP:$I30` (rather than `$INDEX_ALLOCATION:$I30`) is the attribute that overflows, the v0.4 height-grow fall-through still applies. Note the resident `$BITMAP:$I30` now grows in place (see the resident-growth follow-up above), so this only matters once the grown resident bitmap itself exhausts base-record slack — at which point the non-resident `$BITMAP` migration follow-up above takes over. In practice `$INDEX_ALLOCATION` is far larger and overflows long before `$BITMAP`, so this is low priority.
    - **Runtime cross-object delete selectivity test.** That deleting one migrated file frees only its own extension records and not a sibling's is currently asserted only by the pure `splitLeakedExtensions`/classifier tests in `MFTConsistencyTests.swift` — the runtime `testDeleteOneMigratedFileLeavesAnotherMigratedFileIntact` XCTSkips because the 4 MiB `small.img` fixture can't host two concurrent ~250-fragment migrations. A real end-to-end runtime test is deferred pending a larger fixture (e.g. an 8–16 MiB `medium.img`).

### Medium-impact

5. **Real `$LogFile` journal records.** Currently uses a "dirty bit only" approach which is correct for clean unmounts but doesn't enable automatic recovery from crashes/power-loss. Implementation: write LFS-formatted journal entries before metadata changes; replay incomplete transactions on dirty mount. Substantial — ~1-2 weeks for a minimal correct implementation.
6. **In-place runlist extension on append.** Stage 4's append always frees the old runlist and allocates fresh. Wasteful on fragmented allocators. Implementation: extend the last extent if there's free space adjacent, else add a new extent to the existing runlist. ~1 day.
7. ~~**`$UpCase`-aware filename collation.**~~ ✅ Done (v0.7.3 — this is the `$I30` collation root-cause fix described in the header above). `IndexBuilder.swift` implements the NTFS `COLLATION_FILE_NAME` comparator over `$UpCase`-folded UTF-16 code units; the only surviving mention of `localizedCaseInsensitiveCompare` is a comment explaining the order is deliberately *not* that. This entry described the pre-v0.7.3 state and was simply never struck when the fix landed.
8. **`createSymbolicLink` / `createLink` callbacks.** Currently return EROFS. `createLink` (hard link) = add a second `$FILE_NAME` referencing the same base MFT record, insert the `$I30` entry, bump the hard-link count. Symbolic links require reparse point work — bigger. NOTE: `renameItem` was previously listed here too and is NOT blocked — it is fully implemented (`NTFSVolume.swift:431`).

### Low-impact / polish

9. ~~**Better `ntfsctl verify`.**~~ ✅ Largely done. The "sweeps only records 0..63" description is stale: `Verify.swift` walks the full MFT (bounded by `maxRecords` / `mftLogicalRecords`) and the `--deep` mode detects orphans, dangling `$I30` entries, free-but-referenced and double-allocated clusters, and audits runlists against `$Bitmap` — the capabilities this entry asked for. Remaining `fsck`-equivalent ambitions (repair, not just detect) are tracked separately.
10. ~~**`ntfsctl tree`.**~~ ✅ Done (2026-07-27). `Tree.swift` renders a depth-first `$I30` walk in `/usr/bin/tree` style (`├── `, `└── `, `│   `) with a trailing `N directories, M files` summary; `--depth N` bounds the descent and an unreadable directory becomes an inline `[error: …]` line instead of aborting the render. The traversal itself lives in the shared `NTFSCore.DirectoryWalker` (cursor-based, cycle-safe, depth-bounded), not in the subcommand — `Tree.swift` contains no descent logic of its own.
11. ~~**Recursive `ntfsctl find`.**~~ ✅ Done (2026-07-27). `Find.swift` matches each entry's **name** against a glob (`--name`, case-insensitive `fnmatch(3)` — `find -name` semantics, not `-path`), with `--type f|d` and `--depth N`, and prints one full path per match. Shares the same `NTFSCore.DirectoryWalker` as `tree`, so there is exactly one general-purpose directory walker in the codebase.
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

## Known external limitations

These are defects in tools OUTSIDE this project that affect how our (provably-correct) on-disk data is read back. They are recorded here so future hardware runs reference this note instead of re-investigating from scratch.

### macOS `livefiles_ntfs` >4 GB read limitation

**Symptom.** During v0.5, a 22,419-file `cp -rT` to a real 4 TB WD My Passport copied 6,139 files cleanly, then macOS's native NTFS reader raised `Input/output error` on the *content* of late/fragmented files (e.g. `WhatsApp Documents/bn.pdf`). The macOS unified-log signature, emitted by `livefiles_ntfs.dylib`, is:

```
ntfs:cluster_read_ext: Error from blockmap operation: Input/output error (5)
```

This was first feared to be a "multi-extent `$DATA` portability blocker" bug in OUR driver. **It was conclusively diagnosed as a FALSE ALARM:** the bug is in macOS 15's new userspace `livefiles_ntfs` reader mishandling NTFS data at device byte-offsets above 4 GB — NOT a defect in our driver.

**Our on-disk data was proven correct THREE independent ways** (for `bn.pdf`, source sha `45b9219026bb9b135c43fc213c9eabe16c0b9565`):

1. **Driver-level structural dump.** `ntfsctl dump <device> bn.pdf` → single extent, LCN 1260225, in-range, `$Bitmap` ALLOCATED, runlist spec-correct. Single-extent encoding is unambiguous — both our decoder and an independent spec-strict decoder agree.
2. **Driver-level content read.** `ntfsctl cat <device> bn.pdf | shasum` == the source sha (`45b9219026bb9b135c43fc213c9eabe16c0b9565`).
3. **No-driver raw read.** `dd if=/dev/diskNs1 bs=512 skip=10081800 count=1056 | head -c 540566 | shasum` (RAW read straight off the block device, no NTFS driver involved at all) == the source sha.

**Boundary math.** Failures correlate exactly with **LCN > 1,048,576 = 4 GB ÷ 4096-byte cluster**. Files whose data lives below 4 GB read fine in `livefiles`; provably-correct files above 4 GB throw EIO. For `bn.pdf` the sector number (`10,081,800` = LCN 1,260,225 × 4096 ÷ 512) fits in 32 bits, but the byte offset (`5.16e9`) overflows 32 bits — a 32-bit blockmap limitation in Apple's young `livefiles_ntfs`. Generalize the boundary as:

```
boundary LCN = 4 GiB / bytesPerCluster
             = 1,048,576  for a 4096-byte cluster
```

Any file whose runlist places data at an LCN above this boundary is at risk in `livefiles_ntfs` regardless of correctness.

**Conclusion.** Our writes are spec-correct NTFS; mature readers (Windows / `ntfs-3g` / `chkdsk`) will read them. `livefiles_ntfs` is an unreliable validator above 4 GB. (Caveat: Windows / `ntfs-3g` confirmation of these specific above-4-GB files is still recommended; until then frame the EIO as `livefiles`-specific. The `dd`+sha no-driver proof above stands on its own regardless — it bypasses every NTFS driver.)

**Guidance: `livefiles_ntfs` must not be used as the sole validator above 4 GB — use `ntfs-3g` / Windows `chkdsk`, or a raw `dd`+sha spot-check, instead.**

See the canonical portability spot-check recipe in [`docs/CLI.md`](CLI.md#prove-on-disk-correctness-independent-of-any-ntfs-driver-portability-spot-check) for the exact commands (including how to derive the `dd` `skip`/`count` from `ntfsctl dump`).

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
