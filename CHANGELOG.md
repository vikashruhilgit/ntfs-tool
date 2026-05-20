# Changelog

All notable changes to ntfs-tool. Format roughly follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — v0.5.0 candidate

### Added

- **v0.5 Fix B Step 4: unnamed `$DATA` (type 0x80) migration write path — lifts the per-file `$DATA`-overflow cap that aborted a hardware `cp -r` at file 350 ("would overflow record … type 0x80").** Generalizes Step 3's `$INDEX_ALLOCATION` (0xA0) migration so it ALSO handles a file's own non-resident unnamed `$DATA`: when the `$DATA` runlist would overflow the base MFT record's slack, the attribute is migrated to a freshly-allocated extension MFT record and a resident `$ATTRIBUTE_LIST` (type 0x20) is added to the base. `$STANDARD_INFORMATION` (0x10) and `$FILE_NAME` (0x30) stay resident in the base record (chkdsk requirement). Reads follow the `$ATTRIBUTE_LIST` to the extension and return content byte-identical.
  - **Generalized shared builder, reused from Step 3 — no behavior change to the 0xA0 (`$INDEX_ALLOCATION`) path.** The migration helper introduced in Step 3 (`AttributeMigration` + `MFTRecord.buildExtensionRecord` + the compute-first transactional commit) is generalized to accept any overflowing attribute type rather than being `$INDEX_ALLOCATION`-specific; the existing 0xA0 directory-overflow path runs through the same generalized code unchanged. The discrimination guard now fires for both 0xA0 and 0x80 overflows.
  - **Same compute-first transactional commit:** full in-memory build of both records before any disk write; the extension record is written first, then the base. On any throw between MFT-slot allocation and the final base commit, `reclaimOrphanedMFTRecord` releases the extension slot (clears IN_USE + frees the `$MFT.$BITMAP` bit) so partial migrations never leak slots — failure is fail-closed, never corruption.
  - **chkdsk-clean on-disk shape:** base record carries the resident `$ATTRIBUTE_LIST` body (listing base + extension attributes, sorted per NTFS canon); the extension record carries the non-resident `$DATA` runlist with `baseFileReference` packed back at the base (`(UInt64(seq) << 48) | (recnum & 0x0000_FFFF_FFFF_FFFF)`) — same shape Step 3 produces for `$INDEX_ALLOCATION`.
  - **Deferred limitations (fail-closed, never corruption):** a SUBSEQUENT write to an already-migrated file, and a ranged `readFileSlice` of a migrated file, are not yet supported — both hit a clean error rather than a partial mutation. Full-file reads of migrated files are complete. Tracked alongside the Step 3 post-migration write-path follow-up in STATUS.md.
  - **New unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/`: end-to-end `$DATA`-overflow migration + byte-layout assertions, `$ATTRIBUTE_LIST`-aware full-file read round-trip on a migrated file, and a guard test asserting the deferred subsequent-write / ranged-read paths fail cleanly with no MFT slot leak.
  - **Hardware validation (the file-350 `cp -r` to the real WD My Passport) still pending** — user manual step.

- **v0.5 Fix B Step 3: `$INDEX_ALLOCATION` migration write path — lifts the v0.4 per-directory ~350-file `cp -r` cap.** When inserting a new entry causes `$INDEX_ALLOCATION:$I30`'s runlist to overflow the base MFT record's slack, the attribute is migrated to a fresh extension MFT record and a resident `$ATTRIBUTE_LIST` (type 0x20) is built on the base listing every attribute the file owns (base + extension). `$STANDARD_INFORMATION` (0x10) and `$FILE_NAME` (0x30) stay resident in the base record (chkdsk requirement). Per-directory capacity is now bounded only by free clusters + MFT slots on the volume.
  - **New file:** `Packages/NTFSCore/Sources/NTFSCore/AttributeMigration.swift` (~305 lines). Pure-Swift byte builder — `AttributeMigration.buildIndexAllocationMigration(...)` returns `(newBaseBytes, newExtBytes)`. `$ATTRIBUTE_LIST` body is sorted per NTFS canon (type ascending, then name UTF-16, then lowestVCN).
  - **`baseFileReference` packing matches `AttributeListEntry.mftReference`:** `(UInt64(seq) << 48) | (recnum & 0x0000_FFFF_FFFF_FFFF)` — same 48-bit recnum / 16-bit sequence layout used by `$ATTRIBUTE_LIST` entries.
  - **New helper:** `MFTRecord.buildExtensionRecord(...)` builds a valid extension FILE record with `baseFileReference` set, IN_USE-only flags (no DIRECTORY bit on the extension itself), `mftRecordNumber` populated, USA fix-up applied.
  - **Compute-first transactional commit in `Volume.migrateIndexAllocationOnOverflow`:** full in-memory build of both records before any disk write; extension record written first, then base. On any throw between MFT-slot allocation and final base commit, `reclaimOrphanedMFTRecord` releases the extension slot (clears IN_USE + frees the `$MFT.$BITMAP` bit) so partial migrations don't leak slots.
  - **Overflow discrimination at the three catch sites** (was lines 969 / 1534 / 2151): `isOverflowDescription(_:)` now matches both `"would overflow parent record"` (Step A / `$INDEX_ROOT`) and `"would overflow record"` (Steps B/C / `$INDEX_ALLOCATION` / `$BITMAP`). Throw strings in `rewriteResidentAttribute` and `rewriteEntireAttribute` are augmented with `, type 0x{HEX}` so the migration helper only fires for `$INDEX_ALLOCATION` (0xA0). `$BITMAP`-only overflows (rare; `$INDEX_ALLOCATION` is far larger in practice) fall through to the v0.4 height-grow path.
  - **Step 3.5 — non-resident `$ATTRIBUTE_LIST` — deferred.** If the resident `$ATTRIBUTE_LIST` body itself wouldn't fit in base record slack, migration throws `unsupportedFeature("Fix B Step 3.5: $ATTRIBUTE_LIST exceeds parent slack — non-resident $ATTRIBUTE_LIST not yet implemented")` and the v0.4 cap continues to hold. Practically unreachable until a directory has many attributes (e.g., many alternate data streams + named EAs).
  - **Post-migration write path — pending follow-up.** The migration itself lands and the read path traverses `$ATTRIBUTE_LIST` correctly (Step 1+2 below). Subsequent WRITES into an already-migrated directory (e.g., inserting more files after migration) go through paths that don't yet follow `$ATTRIBUTE_LIST` on the WRITE side — see commit `bd250a9` on main and STATUS.md follow-up #11. This PR's tests assert reopen + read-path round-trip is durable; further-growth on already-migrated directories needs a separate follow-up.
  - **3 new unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/AttributeListMigrationTests.swift`: `testAttributeListMigrationOnIndexAllocationOverflow` (end-to-end migration + byte-layout assertions + `$ATTRIBUTE_LIST`-aware resolve + orphan walk), `testAttributeListRoundTripPostMigration` (post-migration reopen round-trip, read path complete), `testNonIndexAllocationOverflowThrowsClean` (discrimination guard rejects non-`$INDEX_ALLOCATION` overflows cleanly with no MFT slot leak). **120/120 NTFSCore tests pass.**
  - **Hardware validation (22,419-file `cp -r` to the real WD My Passport) still pending** — user manual step.

- **v0.5 Fix B Step 1+2: `$ATTRIBUTE_LIST` entry parse/serialize and read-path foundation (`Volume.resolveAttribute` / `allAttributesOf`)** so attributes migrated to extension MFT records via `$ATTRIBUTE_LIST` are correctly resolved. Backwards-compatible: no-op when `$ATTRIBUTE_LIST` is absent. The write/migrate path landed in Step 3 above.

- **Phase 1 — `Volume.beginBulkInsert(into:)` / `endBulkInsert()`** — bulk-insert mode that defers the per-file `$I30` size-hint refresh (`refreshParentI30Size`) during high-volume operations. cp -r wraps each destination directory's batch of file inserts in begin/end; the per-file size-hint INDX-block rewrite is skipped (size hints can be re-applied via a future `ntfsctl refresh-sizes`). Size hints in `$I30` are cosmetic (Windows Explorer file-size column); file content is byte-correct on disk regardless.
- **Phase 2 — INDX-leaf coalescing.** New `BulkLeafCache` in `IndexAllocationWriter` holds parsed leaf state across consecutive inserts during a bulk-insert window. When 50 files all land in the same leaf, that's 50 4-KiB-leaf reads + 50 4-KiB-leaf writes collapsed into one read + one final write at `endBulkInsert`. Leaf splits transparently flush the pre-split leaf to disk so the split path sees up-to-date entries. Combined with Phase 1, expected ~3-5× cp -r speedup on USB-attached drives. New unit tests `testBulkInsertSkipsSizeHintRefresh` (Phase 1) + `testBulkInsertCoalescesLeafWrites` (Phase 2). Tests: 111/111 pass.
- **`cp --progress` now reports timing** — each progress line shows `elapsed=Xs rate=Y/s`, plus a final-summary line with files/s and MiB/s. Lets users measure the impact of perf work directly without external `time` wrappers.
- **Bitmap dirty-range tracking — fixes persistBitmap perf catastrophe.** `Volume.persistBitmap` previously wrote the ENTIRE in-memory `$Bitmap` to disk on every `allocateClusters` / `freeClusters` call. For a 4 TB volume that's ~128 MiB of writes per file allocation → ~5 sec per file on USB-attached drives. Now `Bitmap` tracks the dirty byte range from `markAllocated` / `markFree`, and `persistBitmap` writes only that range (sector-aligned). Hardware-validated **2026-05-19 against a 4 TB WD My Passport: cp -r jumped from 0.2 files/sec to ~100 files/sec sustained (peak 192 files/sec)** — a ~400-500× per-file speedup. The 22 k-file phone-backup workload should now complete in ~4 minutes, competitive with Apple's NTFS driver.
- **Phase 3(A) — `$INDEX_ROOT` height-grow.** When a leaf split's median promotion would overflow the parent MFT record's slack (the v0.3 ~60-file/dir clean-abort point), `splitLeafAndPromote` now allocates 2 new intermediate INDX blocks, bisects `$INDEX_ROOT`'s interior entries into them, and replaces the resident `$INDEX_ROOT` with a tiny new root: one interior entry pointing at the left intermediate + LAST sentinel pointing at the right. Tree depth goes from 2 (root → leaves) to 3 (root → intermediates → leaves). Compute-first transactional pattern (same as v0.3's leaf-split fix): all in-memory builds happen before any disk write; failures free intermediates cleanly. New unit test `testHeightGrowIndexRootLiftsLeafSplitCap` asserts inserts continue past v0.3's ~75 ceiling with 0 orphans.
- **Phase 3(B) — promote median into intermediate INDX block (depth-3+ trees).** After Phase 3(A) height-grew the tree, subsequent leaf splits need to promote their median into the leaf's direct parent — an INTERMEDIATE interior INDX block, not `$INDEX_ROOT`. New helpers: `findInteriorParentChainForLeaf` (key-based descent walk that returns the chain of intermediates from `$INDEX_ROOT` down to the leaf's direct parent), `spliceInteriorEntries` (extracted from the existing token-based splice for reuse at any tree level), `promoteThroughInteriorChain` (handles the depth-3 fits case).
- **Phase 3(C) — recursive interior-block split + cascade promote.** When an intermediate INDX block itself overflows on insertion of the promoted median, `promoteThroughInteriorChain` now bisects that intermediate (allocates 1 new cluster for the right half, writes left half over the original block's location, writes right half to the new cluster), and **cascades the bisection median up to the level above** in the same loop iteration. The loop continues up the chain — each level either fits (cascade stops, just rewrite that intermediate) or overflows (split + recurse). All allocated clusters are tracked in `extraClustersAllocated` for atomic rollback on commit failure.
- **Phase 3(D) — height-grow root after cascade.** Final capping layer removed: when the recursive cascade promotes the bisection median all the way up to `$INDEX_ROOT` AND the root would still overflow, `heightGrowIndexRoot` is called on top of the cascade's already-accumulated state. Refactored signature accepts pre-accumulated `cascadeAccumulatedExtents` + `cascadeBitmapVCNs` so the merged runlist + bitmap reflect both the cascade's writes and the new intermediate INDX blocks. **Directory capacity is now bounded only by free clusters and MFT slots on the volume — no algorithmic cap.** The small fixture caps at ~1077 inserts due to MFT-slot exhaustion (slot 1100 past $MFT.$DATA's allocatedSize); real 4 TB volumes have ~500 million MFT slots, so a single directory can hold any practical number of files. Tests: 113/113. Hardware validation deferred to user.

## v0.3.0 — 2026-05-19

### Fixed

- **LARGE_INDEX leaf-split silent-orphan bug.** Previously, after ~4 leaf splits in the same directory, the next insert that would overflow `$INDEX_ROOT`'s interior-entry budget partially mutated disk (rewriting the original leaf to its left half, writing right-half data to a new cluster that was never linked into `$INDEX_ALLOCATION`) before throwing — silently orphaning 10-15 previously-inserted entries. **Fix:** reordered `Volume.splitLeafAndPromote` so the parent MFT record is built in memory first; if it would overflow, the throw fires BEFORE any leaf disk write, the freshly-allocated cluster is released, and disk state is identical to before the split attempt. Repro test (`testLeafSplitOrphansBugUnderCpRWorkload`) now passes: 75/75 inserts visible on reopen, 0 missing, 0 orphans. See [`docs/V0.3-LEAF-SPLIT-DEBUG-NOTES.md`](docs/V0.3-LEAF-SPLIT-DEBUG-NOTES.md). The remaining limit (`$INDEX_ROOT` itself needs to split into a multi-level tree) now produces a clean `unsupportedFeature` abort with no data loss.

### Added

- **`ntfsctl reclaim-orphans`** — sweep MFT for IN_USE-but-unreachable records and clear them (clear IN_USE flag + free `$MFT.$BITMAP` bit). Dry-run by default; `--confirm` to actually clean; `-v` for per-orphan name/parent. Native equivalent of `ntfsfix` / `chkdsk /f` for the orphan-reclaim case — no Linux/Windows required. Recovery tool for volumes inherited from pre-v0.3 buggy builds. See the [recipe in CLI.md](docs/CLI.md#reclaim-orphaned-mft-records-left-by-older-buggy-builds).
- **Nested-cp orphan regression test** (`testCpRecursiveNestedDirsOrphanFreeUnderPressure`) — creates `gallery/backup/` two-deep, fills the leaf until overflow, walks reachability vs IN_USE the same way `ntfsctl verify` does. 0 orphans across 107 inserts.

### Changed

- `Volume.deleteOrphan` (private) renamed to `Volume.reclaimOrphanedMFTRecord` (public). Same operation — flip IN_USE off + free the `$MFT.$BITMAP` bit. Used by createFile's rollback AND by the new `reclaim-orphans` subcommand.

## v0.2.0 — 2026-05-18

This release closes every FATAL + CRITICAL item from the [red-team audit](AUDIT-REPORT.md) and most of the WARNINGs. The CLI is ready for general use on real pre-existing Windows-formatted drives (was: failed immediately on any drive with > 2032 existing files).

### Added — capabilities

- **`ntfsctl scan`** — enumerate attached NTFS partitions; no more eyeballing `diskutil list`.
- **`ntfsctl cp [--from-volume] [-r]`** — bidirectional host↔volume copy with `--progress`, `--dry-run`, `-n` (no-clobber), `-v` (verbose), `--no-free-check`. Streams large files; auto-creates intermediate dirs.
- **`ntfsctl rm [-r]`** — file or recursive directory delete; refuses root; requires `--force` for recursive (with `--dry-run` preview).
- **`ntfsctl mv`** — path-based rename / move; auto-creates intermediate destination dirs.
- **Streaming I/O** — `cat` and `write --from-file` are chunked; no 1 GiB cap.

### Added — correctness

- **MFT `$BITMAP`-based allocator** (T1.1) — replaces the linear 2048-record scan that failed silently on real Windows drives with > 2032 files. Bumps `$MFT.$DATA.realSize` when allocating past the high-water mark.
- **LARGE_INDEX leaf split** (T1.2) — directories grow past the ~50-entry single-leaf cap. DCIM-sized folders work.
- **LARGE_INDEX size hint refresh** (T1.3) — `$I30` entries' `$FILE_NAME` size fields update after each write. Windows Explorer / Dropbox / OneDrive see accurate sizes.
- **mtime updates on write** (T1.4) — `$STANDARD_INFORMATION.mtime` bumps to "now" on every write. Photo organizers + sync tools no longer mis-dedupe.
- **`$FILE_NAME` size refresh after write** — resident-`$INDEX_ROOT` parents got this in the prior iteration; LARGE_INDEX parents got it with T1.3.
- **Mid-file random write** — `write --offset N` patches in place (no allocation) for `0 < N ≤ size - bytes.count`.
- **Byte-precise truncate** — shrinks to any size (was: only 0 or cluster-aligned).
- **Auto-promote small directories to LARGE_INDEX** on `$INDEX_ROOT` overflow.

### Added — safety

- **Volume marked dirty before writes** (`Volume.beginWriteSession()` / `endWriteSession()`) — crashes mid-write now leave Windows aware that `chkdsk` should scan on next mount. **Was: silent corruption that Windows would trust.**
- **`fcntl(F_FULLFSYNC)` before clearing dirty bit** — survives fast-unplug; data hits media before dirty=0 lands.
- **Exclusive `flock()` on writable device open** — concurrent `ntfsctl` writers fail-fast instead of racing.
- **`rm -r /` explicit refusal** + `--force` required for recursive — eliminates one-typo full-volume wipes.
- **`--recnum` flag** — bare arguments are now ALWAYS paths. A file literally named "38" no longer silently targets MFT record 38. **Backward-incompatible** for scripts passing numeric recnums (use `--recnum N`).
- **Full-MFT `verify`** — sweeps the entire MFT bounded by `$MFT.$DATA.allocatedSize`; orphan + dangling-`$I30` detection. **Was: silent false-pass on volumes with > 4096 records.**

### Added — distribution

- **MIT LICENSE.**
- **GitHub Release CI workflow** — tag push `v*` builds the release `ntfsctl` binary, smoke-tests it against the committed fixture, drafts a release with the binary + tarball + SHA-256 sums. You publish.

### Changed

- README rewritten for first-time visitors.
- CLI `--parent` on `create` now defaults to `"/"` (path) instead of `5` (recnum). Pass `--parent-recnum N` for the legacy numeric form.

### Known limits (deferred)

- **`$LogFile` journaling** — only the dirty bit is managed. Clean unmount = always safe. Power loss mid-write = manual `chkdsk /f` recovery. Real journaling is a 1-2 week separate effort.
- **`$MFT.$DATA` growth auto-invoke** — `growMFTDataByClusters` is implemented and works in isolation, but isn't auto-called from `allocateMFTRecord` in v0.2 because the interaction with a second LARGE_INDEX leaf split (when `$INDEX_ROOT` accumulates a second interior entry post-growth) corrupts state in a subtle way. On real drives `$MFT.$DATA.allocatedSize` is huge (12.5% of volume reserved); auto-grow mostly matters for tiny fixtures.
- **Symlinks / hardlinks / reparse points / ADS / LZNT1 / EFS** — explicit non-goals for v1.
- **Streaming bitmap reader** — `$Bitmap` is loaded whole into RAM (~250 MB for 8 TB volumes). Defer to v0.3 hardening.
- **Daemon mode / setuid helper** — security-sensitive; defer.
- **FSKit mount in Finder** — requires SIP-off or Apple Developer FSKit entitlement; user-side validation.

## v0.1 (2026-05-17) — Phase 5e Block G stage 5

Earlier rolling delivery; see git log for per-PR details. Highlights:

- NTFSCore Swift library: 87 tests, full read + write, validated against `mkntfs` fixtures + `ntfs-3g` round-trip.
- `ntfsctl` CLI with `info` / `list` / `cat` / `create` / `delete` / `write` / `truncate` / `setdirty` / `verify`.
- FSKit System Extension (code complete; mount validation pending).
- SwiftUI menu-bar app (code complete; needs FSKit mount).
