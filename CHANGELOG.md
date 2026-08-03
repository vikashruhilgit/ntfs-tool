# Changelog

All notable changes to ntfs-tool. Format roughly follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — `ntfsctl tree` + `ntfsctl find` over one shared `$I30` walker

### Added

- **`NTFSCore.DirectoryWalker` — the single general-purpose directory traversal in the codebase.** A depth-first, pre-order **cursor** (`public mutating func next() async -> WalkEvent?`) over an explicit frame stack, deliberately *not* an `AsyncStream` producer task — that default-unbounded buffering would let the producer race ahead and re-accumulate the whole tree. A directory is enumerated only when the walk reaches it, and its children only on the call *after* the directory itself was emitted.
  - **Cycle-safe:** `visited: Set<UInt64>` seeded with the start record. An already-visited directory is still emitted as an entry but never descended into twice, so a genuine on-disk `$I30` cycle terminates.
  - **Depth-bounded:** the bound is checked *before* the `enumerate` call, so `maxDepth: 0` issues no device reads at all.
  - **Per-node error containment:** `next()` never throws. An unreadable directory — including the start directory — yields one `.error` event carrying that node's path, record number, depth and underlying error; the walk continues with the next sibling.
  - **DOS-alias filtering in one place** (`dropRedundantDOSAliases`), so `isLastSibling` is computed against the filtered listing and 8.3-aliased entries do not double. A DOS entry is dropped **only when the same MFT record also carries a non-DOS name** — a blanket `namespace != .dos` filter (which `ntfsctl list` shipped with, and which this release also fixes) makes a file whose only `$FILE_NAME` is an 8.3 alias vanish from the listing entirely.
  - **Honest memory bound, stated in the doc comment:** O(sum of the sibling arrays along the current root-to-node path) — *not* O(depth), because `Volume.enumerate` returns a materialized `[DirectoryEntry]` per directory — plus one `UInt64` per directory descended into retained in `visited` for the whole walk. The guarantee is that the whole tree is never accumulated, not that memory is O(depth).
- **`ntfsctl tree <device> [path] [--depth N] [--recnum]`** — `/usr/bin/tree`-style renderer (`├── `, `└── `, `│   `) ending in a `N directories, M files` summary. An unreadable directory renders as an inline `[error: …]` line and does not abort the render.
- **`ntfsctl find <device> [path] --name <glob> [--depth N] [--type f|d] [--recnum]`** — `find -name` semantics: case-insensitive `fnmatch(3)`/`FNM_CASEFOLD` against each entry's **name** (not its path). Prints one full path per match; unreadable directories go to stderr without aborting.
- Both subcommands are **thin consumers** — neither contains descent logic of its own (enforced by test: zero occurrences of `enumerate(directory:` in either file) — and both adopt the post-v0.2.0 `TargetResolver` contract where a bare argument is **always** a path and `--recnum` is opt-in. `list`/`cat` keep their pre-v0.2.0 auto-parse behavior, untouched.
- **Tests:** `DirectoryWalkerTests` (7) covering depth bounding against an independent `enumerate` oracle, termination on a **genuine on-disk cycle** (built via `Volume.rename` into a descendant, which has no ancestor guard), per-node error containment via a `FaultingBlockDevice` decorator that fails exactly the one read covering a subdirectory's MFT record, and the streaming guarantee (frame-stack depth is 1 after exactly one `next()`). `TreeFindTests` (9) pins the summary counts against an independent two-level `enumerate` walk. Suites: NTFSCore 269 executed / 2 skipped / 0 failures; ntfsctl 33 / 0 failures.

### Known limitations

- `tree`/`find` exit **0** when the walk root resolves but cannot be enumerated (e.g. a file target), diverging from `list`, which exits 1 on the same input. Deliberate and test-pinned, but it means a script cannot distinguish "no matches" from "the search root could not be read".
- With `--recnum <N>` for a non-root record, `find` prints paths relative to the search root with a leading `/`, so they look absolute but only genuinely are when `N == 5` — NTFSCore has no reverse record→path lookup.
- Pre-existing purpose-coupled recursion in `Rm.swift`, `Cp.swift`, `Verify.swift` and `Reclaim.swift` was **not** refactored onto the walker (out of scope; the first two carry data-loss risk, the latter two are MFT-reachability sweeps rather than directory renderers).

## [Unreleased] — v0.7.3 — write to real Windows-formatted volumes (`$I30` collation + `$MFT` auto-grow) + ntfs-3g oracle

### Fixed

- **ROOT CAUSE of "drive corrupted on Windows": wrong `$I30` directory-index collation.** `IndexBuilder.collationFilenameSortsBefore` used Swift's `localizedCaseInsensitiveCompare` (locale-aware Unicode collation) instead of NTFS `COLLATION_FILE_NAME` (UTF-16 code units mapped through `$UpCase`, compared as unsigned 16-bit). Locale rules reorder punctuation — e.g. they sort `.` (0x2E) **before** `$` (0x24), the opposite of NTFS. Directory `$I30` indexes are sorted B-trees that **Windows and ntfs-3g binary-search**; inserting into a real volume's root re-sorted the system entries into an order those drivers reject, so a name lookup for `$Secure` missed → mount fails → "the file or directory is corrupted and unreadable." Our own reader never caught it because it binary-searched with the *same* wrong collation (classic weak oracle). Fixed by implementing true `COLLATION_FILE_NAME` via a new `UpcaseTable.upcase(_:)` per-code-unit accessor. **Verified against the real `ntfs-3g`/`ntfsfix` driver:** an `ntfsctl`-written volume now mounts cleanly and reads back byte-exact.
- **New cross-validation oracle (`scripts/ntfs-oracle.sh`).** Formats a fresh image with the real `mkntfs`, copies into it with `ntfsctl`, then validates with real `ntfsfix` + `ntfscat` checksum read-back — all in Docker, no physical drive or Windows. This is the authority the project lacked: "passes our own reader" proved nothing. New `CollationFileNameTests` lock the ordering (incl. the `$`-before-`.` case and the exact fresh-root entry order).
- **`ntfsctl` can now write to a freshly Windows-formatted NTFS volume (MFT auto-grow).** A real Windows quick-format starts `$MFT.$DATA` at just **16 records** (the base system files) and grows the MFT on demand; ours over-allocated a ≥16 MiB / 16,384-record `$MFT`. `allocateMFTRecord` refused to grow `$MFT` (`"auto-grow is disabled in v0.2"`), so on a real Windows drive the **very first** user-file create failed — it needs MFT record 16, one past the initial allocation. Every prior success (incl. the 22,419-file hardware copy) only worked because *our* `mkntfs` over-allocated the MFT — the same weak-oracle blind spot the `mkntfs` removal exposed.
  - `allocateMFTRecord(allowGrowth:)` now invokes the (already-implemented, already-tested) `growMFTDataByClusters` when it runs out of materialized slots: it grows `$MFT.$DATA` by a 64-cluster / 256-record chunk and extends `$MFT.$BITMAP` to expose the new slots, then retries.
  - Growth is enabled **only** for the base-record allocation at the start of `createFile` — a safe point (no transactional state read/built yet; the parent is re-read afterward). It stays **off** for extension-record allocation mid-migration, side-stepping the historical "grow + leaf-split interaction" corruption hazard the old comment flagged. The base allocation's 256-record runway means mid-transaction extension allocations virtually always find a ready slot.
  - **Ceiling:** `$MFT.$BITMAP` growth is bounded by its existing allocatedSize (no cascading bitmap-of-bitmap growth yet) — on a typical 4 KiB `$BITMAP` that caps the MFT at ~32,768 records. Far above the old 16-record wall and adequate for large backups; past it, a clear `unsupportedFeature` is thrown.
  - New `MFTAutoGrowTests` (3 tests) build a **16-record `$MFT` fixture** that mirrors the real Windows drive (test-only `Mkntfs.Options.mftInitialClustersOverride`) and prove: (1) the first create grows the MFT and succeeds past slot 16; (2) 3,200 files across 4 subdirectories — driving dozens of growth rounds **and** `$I30` leaf-splits/height-grows — leave a spotless whole-volume deep audit (0 free-but-referenced / out-of-range / double-allocated) and 0 orphans; (3) content survives growth + reopen-from-disk byte-exact.

## [Unreleased] — v0.7.2 (cont.) — `mkntfs` REMOVED

### Removed

- **`ntfsctl mkntfs` — the pure-Swift NTFS formatter (added v0.6) is removed.** Hardware testing proved its output was accepted by NTFSCore's own (lenient) reader but **rejected as corrupt by Windows and macOS `livefiles_ntfs`**. Concrete defects found: total-sectors off-by-one (fixed, but insufficient), zero BPB geometry (hidden-sectors/track/heads), non-conventional `$MFT`/`$MFTMirr` placement, no boot code, and — fundamentally — no spec-valid `$Secure` (`$SDS`/`$SDH`/`$SII` B-trees + SD hashes). A faithful formatter is an `ntfsprogs`-`mkntfs.c`-scale effort (out of scope), and a half-correct one that yields "valid-to-us / corrupt-to-Windows" volumes is actively harmful. **To format an NTFS volume, use Windows or `mkntfs-3g`; `ntfsctl` operates on existing volumes.**
  - Removed: the `mkntfs` CLI subcommand (`Tools/ntfsctl/Sources/ntfsctl/Mkntfs.swift`) and its registration.
  - Retained (NTFSCore-internal, clearly relabelled, NOT user-facing, NOT portable): `Volume.formatNTFS` / `Mkntfs` / `UpcaseTable` / `AttrDefTable` / `BootSector.serialize` — used solely to build large writable `.img` fixtures for the allocator / migration / locality test suites (a committed fixture can't be 512 MiB). These produce volumes valid for our own reader only.
  - Lesson recorded in `docs/STATUS.md`: `mkntfs` was merged on a weak oracle ("passes our own reader"). Anything that writes an on-disk format for *other* systems to consume must be validated against those systems before shipping.

### Docs

- **`docs/CLI.md` stale-content sweep** — corrected pre-v0.2/v0.3 claims that contradicted shipped behavior:
  - Replaced "file lookup is by MFT record number, not by path" / "a future iteration could add path-resolution" with the current model: **paths are primary** for every targeting subcommand; `--recnum` (or `--parent-recnum`) opts into the legacy numeric form, and a bare argument is always a path.
  - Rewrote the Reading and Writing workflow examples to lead with the path form.
  - Fixed the `--offset` docs: in-place mid-file patch is supported (not just rewrite/append).
  - Subcommand table: `create` now documents `--parent <path>` (default `/`) + `--parent-recnum` (was wrongly "`--parent <recnum>` default 5"); `rm` now documents `--force` (required for recursive) + `--dry-run` + `--recnum`; `delete`, `truncate`, `list` clarified as path-first.
  - Replaced the "~30-50 files per directory / no leaf split" cap reminder and the "LARGE_INDEX = too many entries" troubleshooting entry — per-directory capacity is bounded only by free clusters + MFT slots (validated at 22,419 files).
- **`ntfsctl --help` top-level abstract** no longer says "Command-line companion to the NTFSCore reader. Read-only in v1; write subcommands land with Block G." — it now reflects the shipped read/write CLI and the "operates on existing volumes; format on Windows" workflow.

## [Unreleased] — v0.7.2 (move + conflict model: cp --move + mv skip/replace + rename atomicity)

Completes the copy/move/skip/replace model. `cp` gains a cross-device **cut** (`--move`), `mv` gains skip/replace conflict handling, and the underlying `Volume.rename` is made abort-atomic so a replace can never lose the source. The dominant safety property throughout: **a source is never deleted unless its copy/move succeeded** — skipped (`-n`) and failed transfers keep their source, `--dry-run` previews deletions without touching anything, and `mv` replace is transactional (insert-before-remove rename, so the source survives a mid-flight abort).

### Added

- **`cp --move` (alias `--remove-source`) — cross-device cut.** After each file's copy SUCCEEDS, its source is deleted: the host file for host→volume, the volume file (via the extension-record-aware delete) for `--from-volume`. Deletion is per-file and strictly post-success — a skipped file (`-n` collision / non-regular source) or a failed file keeps its source. With `-r`, an emptied source directory is removed depth-first only after ALL its children moved; a directory with a skipped/failed child is preserved. `--dry-run --move` previews and is inert (writes/deletes nothing). The summary reports the moved-file count + freed bytes. The volume→host path opens the device writable only when `--move` is set; plain pulls stay read-only.
- **`mv -n` / `--no-clobber` + default replace.** `mv` no longer hard-refuses an existing destination. When the destination name already exists: `-n` **skips** (no-op, exit 0); the default **replaces** (delete the existing destination, then atomically move the source onto its name). Replace targets an existing file or an EMPTY directory; a populated-directory destination is refused (would orphan its contents). Case-only renames and exact self-moves are handled as no-data-loss special cases (the source record is never deleted when the dest lookup resolves back to the source itself).
- **Completed copy/move/skip/replace matrix.** Documented in `docs/CLI.md`: `cp` / `cp --move` (host↔volume, both directions), `mv` (within-volume rename/relocate), `-T` merge, and the `-n` skip vs default-replace conflict policies — one consistent model with a single safety rule across all cells.

### Fixed

- **`Volume.rename` `$I30` mutation is now abort-atomic (insert-before-remove).** The new `$I30` entry is inserted under the destination parent BEFORE the old entry is removed from the source parent, so an abort mid-rename can never leave the record unreachable from both parents — the source is never lost. Closes `AUDIT-TODO(rename-i30-atomicity)`. This is the prerequisite that makes `mv` default-replace safe: the actual source-never-lost guarantee comes from rename atomicity, not from operation ordering alone.

### Tests

- **226 NTFSCore tests pass, 1 pre-existing skip, 0 failures; ntfsctl 24 tests, 0 failures; CLI release builds.**
- `RenameAtomicityTests` (NTFSCore) — proves `Volume.rename` is insert-before-remove: the source record stays reachable through a simulated mid-rename abort.
- `CpMoveIntegrationTests` (ntfsctl) — `cp --move` host→volume and `--from-volume --move`: sources deleted only after a successful copy, skipped/failed sources preserved, emptied directories removed depth-first only when fully moved, `--dry-run --move` inert, freed-bytes accounting.
- `MvIntegrationTests` (ntfsctl) — `mv` skip (`-n`), default replace, replace refuses a non-empty directory, replace transactional abort never loses the source, case-only rename keeps data, exact self-move is a no-op (not data loss), and the plain no-conflict rename still works.

## [Unreleased] — v0.7.1 (per-directory index-allocation locality lane — the ROOT-CAUSE fix)

The ~8,000-file single-directory cap was a **fragmentation symptom, not an NTFS structural limit.** Real NTFS drivers (Windows ntfs.sys, Paragon, Tuxera, ntfs-3g) keep a directory's `$INDEX_ALLOCATION` runlist tiny by allocating its INDX blocks contiguously (per-directory locality), so it never approaches the MFT-record size limit. Pre-v0.7.1 we allocated every INDX block via the GLOBAL next-fit hint shared with file `$DATA`; during a `cp -r`, file-data clusters interleaved between consecutive INDX-block allocations and scattered them → one runlist extent per block → linear runlist growth → base-record overflow at ~8 k files. v0.7 (below) treated the symptom (split the giant runlist across extension records); v0.7.1 stops the runlist from getting giant in the first place — the fix that should have come first.

### Added

- **Per-directory index-allocation locality lane (`Volume.allocateIndexClusters(near:)`).** Allocates ONE cluster for a directory INDX block, biasing toward the directory's runlist tail (or, for the first INDX block, an upper-25%-of-volume index-lane base away from the `$DATA` front). Probes `findFreeRun(count: indexChunkClusters, startingAt: hint)`; on a healthy lane the run starts AT the hint so the new block is contiguous with the directory's existing index and coalesces into ONE runlist extent. Replaces the GLOBAL-hinted `allocateClusters(1)` at the 5 directory-INDX allocation sites (leaf-split/promote/cascade/height-grow paths in `Volume.swift`). Deliberately does NOT advance the global `_allocHint` — the index lane stays separate from the `$DATA` lane.
- **`Volume.indexLocalityHint(forExtents:)`** — derives the per-directory hint as `lastNonSparseExtent.startLCN + clusterCount`. Migration-safe: callers pass the `$ATTRIBUTE_LIST`-aware merged `allocationExtents`, so the hint tracks the true runlist tail even after a PR #35 multi-extension migration.
- **`indexChunkClusters = 256`** — the in-memory contiguous target the search aims at; gives the index lane headroom so it survives many subsequent single-block allocations before relocating, which is what keeps the runlist coalesced.
- **Allocate-on-use discipline (NO up-front `$Bitmap` reservation).** Each INDX cluster is marked allocated in `$Bitmap` ONE AT A TIME, at the moment it is actually built + spliced into the runlist — exactly as before. The "chunk" is purely an in-memory target LCN range; the on-disk `$Bitmap` mutation stays per-block and transactional. There is no reserved-but-unmarked tail to leak on crash and no new crash window vs. `allocateClusters(1)`.

### Fixed

- **The ~file-7,997 single-directory cap, at its root.** Measured on a 4,000-entry directory driven with the real `cp -r` interleave (per-file non-resident `$DATA` writes between INDX-block allocations) on a 512 MiB image: the `$INDEX_ALLOCATION` runlist dropped from **222 extents → 1 extent**, with **NO `$ATTRIBUTE_LIST` migration** triggered at all (pre-fix the same directory both fragmented to 222 extents AND migrated — the `$I30` cap mechanism fired). A coalesced runlist is a handful of bytes and fits the base MFT record forever.

### Changed

- **Multi-extension `$ATTRIBUTE_LIST` (v0.7 / PR #35) repositioned as the rare last-resort fallback** for genuinely fragmented/pathological volumes, rather than the primary capacity mechanism. It remains fully functional and is still proven end-to-end by the unchanged PR #35 suite; on a swiss-cheese-fragmented volume both the new single-cluster degrade chain and the PR #35 migration engage organically.

### Tests

- **217 → 221 NTFSCore tests pass, 1 pre-existing skip, 0 failures (222 executed, +4 new), CLI release builds.** `MultiExtensionIndexAllocationTests` (the 7-test PR #35 suite) pass UNCHANGED, confirming the fallback still works.
- `DirectoryIndexLocalityTests.swift` (new this subtask):
  - `testFragmentedVolumeFallsBackAndStillGrows` (AC-4/AC-7) — swiss-cheese-fragments a 64 MiB volume so no 256-cluster run survives, drives a directory across multiple INDX blocks, and asserts the index STILL grows correctly: the `$INDEX_ALLOCATION` runlist has MULTIPLE extents (the `findFreeRun(256)→findFreeRun(1)` degrade chain engaged; observed ~83 extents + an organic `$ATTRIBUTE_LIST` migration), every created file enumerates, and sampled files read back to their written length.
  - `testNoLeakAfterDeletingLocalityGrownDirectory` (AC-5) — drives a 2,500-entry locality-grown (multi-INDX-block) directory, deletes every file then the directory, and asserts the free-cluster count returns to baseline EXACTLY (0 leaked), `auditAllDataRunlistsAgainstBitmap().isClean == true` with 0 free-but-referenced / 0 double-allocated clusters, and 0 orphans. Proves the allocate-on-use guarantee: delete frees exactly what was referenced because nothing was reserved ahead.
  - `testNoLeakAfterAbortedDirectoryGrowth` (AC-5) — drives a directory locality-grown, then crash-simulates an abort mid-INDX-growth via `_setCreateFileFaultHook(.afterI30CommitBeforeReturn)` (throws right after the `$I30` commit that runs the INDX allocate+splice), and asserts the deep audit is clean (0 free-but-referenced, 0 double-allocated), 0 orphans, and no pre-abort entry is dropped — confirming no leaked-on-crash tail.
- `testLargeDirectoryIndexStaysContiguous` (AC-3, added by the prior subtask) — the 222→1-extent payoff with no migration.

### Known caveats

- **AC-9 hardware re-validation remains a pending MANUAL step.** Reformat a drive (`mkntfs -Q`), then run the full 22,419-file phone-backup `cp -rT … | tee` into a single directory and `verify --deep`. With a contiguous index runlist (~8 bytes for the whole directory) this run should finally complete, or cap far, far higher. Multi-extension `$ATTRIBUTE_LIST` (PR #35) remains the correct rare fallback if a real volume is fragmented enough to force it.

## [Unreleased] — v0.7 candidate (multi-extension `$ATTRIBUTE_LIST` for `$INDEX_ALLOCATION:$I30`)

### Added

- **Multi-extension `$INDEX_ALLOCATION:$I30` write path.** When a directory's migrated `$INDEX_ALLOCATION` extension's own runlist fills its MFT record, a second extension is allocated and the runlist is split at an extent boundary. The base's resident `$ATTRIBUTE_LIST` grows by one entry — two 0xA0:$I30 entries with disjoint VCN ranges, each referencing its own extension record. Lifts the ~file-7,997 single-directory cap that PR #34 documented as the next structural ceiling. Per-directory capacity is now bounded only by free clusters and free MFT slots on the volume.
- **`AttributeMigration.buildAdditionalExtensionForAttribute`** — pure builder with measurement-driven split-point heuristic (smallest suffix extent count such that the surviving prefix's encoded runlist is ≤ 50% of `record_size − fixed_attribute_overhead`; splits at extent boundary only).
- **`Volume.mergeMultiExtensionAttribute(in:rawType:name:)`** — canonical read-path merge seam. Concatenates the extents of multiple `Attribute` values for the same `(rawType, name)` in VCN order, enforcing the NTFS contiguity invariant. Routed at all 12 audited read-side callsites in `Volume.swift` and `RunlistBitmapAudit.swift`; the audit verdict table is captured at the helper's declaration.
- **Transactional discipline:** compute-first; write new extension first, then existing-extension truncation + base `$ATTRIBUTE_LIST` rewrite committed together; new MFT slot reclaimed on throw. Test-only `_setMultiExtensionFaultHook` seam lets the transactional-failure test fire between the new-extension write and the base update.

### Fixed

- **Silent half-read on multi-extension shape.** Pre-v0.7, `Volume.resolveAttribute` (and several other call sites) walked the flat attribute list with `.first(where:)` — for multi-extension `$INDEX_ALLOCATION` / `$DATA` this returned only the VCN-0 attribute and missed every entry living in the suffix extension (measured: 19 of 416 names missing on round-trip readback before the fix). All routed callsites now stitch the extensions together via `mergeMultiExtensionAttribute`.

### Tests

- **216 → 217 NTFSCore tests pass, 1 pre-existing skip, 0 failures, CLI release builds.**
- `MultiExtensionIndexAllocationTests.swift`:
  - `testSecondMigrationAddsAdditionalExtension` — second migration succeeds; base carries two 0xA0:$I30 entries with disjoint VCN ranges and distinct extension recnums.
  - `testMultiExtensionIATransactionalFailure` — fault hook injected between new-ext write and base update; new MFT slot is reclaimed, base is byte-identical to pre-fault, no orphan, no dangling.
  - `testMultiExtensionIASpecConformantBytes` — base's `$ATTRIBUTE_LIST` body hand-decoded byte-by-byte (PR #26 lesson — NOT round-tripped through our own parser); exactly two 0xA0:$I30 entries, lowestVCN-ordered, distinct mftReferences.
  - `testMultiExtensionIAReadbackRoundTrip` — close + reopen + enumerate root after driving past one extension's capacity; every inserted name is present.
  - `testMergeMultiExtensionAttribute_unitContract` — direct synthetic-input exercise of the helper: out-of-order input, single-match short-circuit, no-match nil.
  - `testMultiExtensionVerifyDeepClean` (AC-7) — drives the multi-extension shape, runs `auditAllDataRunlistsAgainstBitmap`, asserts `isClean == true` and `doubleAllocatedClusters == 0`.

### Known caveats

- **Hardware re-validation pending** (user manual step): reformat the drive, copy the full 22,419-file phone-backup corpus into a single directory, and run `verify --deep`. Either completes fully OR surfaces the *next* deeper ceiling (likely non-resident `$BITMAP:$I30` or non-resident `$INDEX_ROOT`). Both are release-quality outcomes; whichever fires gets documented honestly.
- **Multi-extension `$DATA` (0x80) is not implemented in v0.7.** The shape is identical (would reuse `buildAdditionalExtensionForAttribute` + `mergeMultiExtensionAttribute`) but isn't driven by any known hardware failure mode. The v0.5 `unsupportedFeature` path remains fail-closed for that case.
- **Non-resident `$ATTRIBUTE_LIST`** (when the resident `$ATTRIBUTE_LIST` body itself exhausts base slack) is unchanged from v0.5 — distinct ceiling, distinct error path.

## v0.6 — self-contained NTFS reformat

### Added

- **`ntfsctl mkntfs <device>` — pure-Swift NTFS volume formatter.** Equivalent
  to `mkntfs -Q` (quick format). Output is mountable by macOS
  `livefiles_ntfs`, Linux `ntfs-3g`, and Windows. **The project is now
  self-sufficient for the full test loop on macOS** — no Homebrew, no
  macFUSE, no Linux VM, no Windows required to reformat a drive between
  cap-measurement runs. Closes the multi-day reformat-detour cost that
  the v0.5.x cap-measurement runs were paying.
- **`NTFSCore` library additions:**
  - `BootSector.serialize() -> Data` — inverse of `parse`. 512 bytes,
    canonical NTFS jump stub (`EB 52 90`) + BPB + 64-bit total/MFT/mirror
    cluster fields + signed `clustersPerMFTRecord` + `0xAA55` signature.
  - `UpcaseTable.swift` — 131,072-byte (128 KiB) canonical `$UpCase` table,
    derived from Unicode default case mappings via Swift's `String.uppercased()`.
    Auditable generator at `scripts/generate_upcase_table.swift`.
    Clean-room (NOT copied from GPL `mkntfs-3g` / `ntfsprogs`).
  - `AttrDefTable.swift` — 2,560-byte (16 × 160) NTFS 3.1 standard
    `$AttrDef` table. Derived from the public NTFS on-disk spec.
  - `Mkntfs.swift` — top-level orchestrator: geometry planner +
    system-file record builders for records 0..15 + one-shot writer
    (boot sector, `$MFT`, `$MFTMirr`, `$AttrDef`, `$UpCase`, `$LogFile`,
    `$Bitmap`, backup boot sector) with `F_FULLFSYNC` at the end.
  - `BlockDevice.size()` — `fstat()` for `.img` files,
    `ioctl(DKIOCGETBLOCKSIZE|DKIOCGETBLOCKCOUNT)` for raw `/dev/disk*`.
  - `Volume.formatNTFS(device:deviceSizeBytes:label:quick:volumeSerial:)`
    convenience entry point.
- **Safety gate (AC-9):** `mkntfs` refuses to run without `--yes`. Prints
  device path + size + label first, then errors out without writing
  anything.

### Tests

- **39 new NTFSCore tests (was 167 → 206 + 1 skip; CLI builds release).**
  - `UpcaseAttrDefTests.swift` (8 + 9 = 17 tests): AC-5/AC-6 spec-conformance
    against hand-decoded references (PR #26 lesson — not round-tripped
    through our decoder). ASCII a-z, Latin-1, Greek σ→Σ, ß fixed-point,
    surrogate halves; `$AttrDef` name/type/min/max byte-level checks.
  - `BootSectorSerializeTests.swift` (15 tests): AC-4 hand-decoded
    byte-level checks at all critical offsets (3, 11, 13, 21, 40, 48,
    56, 64, 68, 72, 510).
  - `MkntfsTests.swift` (7 tests): AC-3 end-to-end round-trip — format
    a 256 MiB temp `.img`, then re-open via `Volume(device:)`, parse
    records 0..11, verify the `$MFT` runlist decodes to a single
    contiguous extent, root is a directory, backup BS parses cleanly.

### Validation

- **AC-1 (CLI smoke):** `ntfsctl mkntfs fixture.img --label TEST --yes`
  → `ntfsctl info fixture.img` reports correct geometry → `ntfsctl
  verify --deep fixture.img` reports 0 parse errors, 0 orphans, 0
  dangling, 0 double-allocated, 0 out-of-range. Confirmed against a
  256 MiB `.img` on this machine.
- **AC-2 (independent reader mount):** documented but DEFERRED to manual
  step. The .img can be loop-mounted via `livefiles_ntfs`,
  Linux `ntfs-3g`, or `chkdsk` on Windows.
- **AC-10 (hardware reformat):** user runs `sudo ntfsctl mkntfs
  /dev/disk10s1 --label MyData --yes` against the real WD My Passport
  before the next v0.5.x cap-measurement `cp -rT`. NOT part of `swift
  test`. Documented in `docs/CLI.md`.

### Documentation

- `docs/CLI.md` — new "Reformat (`mkntfs`)" section with usage,
  safety notes, and scope (data-volume format, not bootable Windows).
- `docs/STATUS.md` — milestone entry: project is now self-sufficient
  for the full test loop on macOS.

### Clean-room compliance

Every new on-disk constant (`$UpCase` mapping rules, `$AttrDef` 16-entry
table, NTFS boot-sector field layout, MFT record header layout, attribute
header layout, runlist encoding) is derived from the public NTFS 3.1
spec (Linux-NTFS docs at flatcap.github.io + Microsoft's NTFS file
system reference). No code or constants were copied from GPL sources
(`ntfsprogs` / `mkntfs-3g` / Linux kernel `fs/ntfs3` / NTFS-3G).
File headers cite each constant's source.

## [Unreleased] — v0.5.2 candidate

### Fixed

- **v0.5.2 (Bug A): leaf-split migration catch gap on two formerly-uncaught call sites — closes the regression hole that PR #29's "cap lifted" claim left behind.** PR #29's hardware re-run (2026-05-27) aborted a `cp -rT` with `rewriteEntireAttribute: new attribute (504 bytes) would overflow record (used 1020, record 1024, type 0xA0)`, and `dump` on the active insertion target (`WhatsApp Images`, recnum 2998) reported `Migrated ($ATTR_LIST): no` — migration had never fired on that directory despite the type-0xA0 overflow. **PR #29's framing of "lifts the ~file-6,139 cap" was incomplete**: after PR #29's refactor `rewriteParentForLeafSplit` was called from six sites in `Volume.swift`, and two of them remained outside any `isOverflowDescription` catch: the call inside `heightGrowIndexRoot` (only enclosing catch was a generic `freeClusters; rethrow`), and the call in `promoteThroughInteriorChain`'s `!cascadeExhaustedChain` early-return branch (structurally outside the cascade-exhausted catch immediately below). Overflows on those paths escaped uncaught, leaving the directory un-migrated and the cp aborted. **Fix:** new `rewriteParentForLeafSplitMigrating` thin async wrapper catches `$IA`-typed overflow, runs `migrateIndexAllocationOnOverflow`, refreshes the parent, and retries once — mirrors the inlined cascade-exhausted catch pattern that the other four call sites are inside. The two formerly-uncaught sites now call the wrapper; the other four call the raw function unchanged. Non-`$IA`-typed overflows rethrow so `$INDEX_ROOT` / `$BITMAP` failures surface identically to before. **AC-1 caveat (honest disclosure):** on the 4 MiB `small.img` fixture, MFT-slot / free-cluster exhaustion is hit at ~2100 files BEFORE the directory's $IA runlist can grow large enough to overflow base-record slack at the uncaught sites, so the failing-on-baseline reproduction required by the brief could not be cleanly demonstrated within fixture limits. The new tests (`LeafSplitMigrationCatchTests.swift`) pass on both pre-fix and post-fix code on `small.img`; they serve as post-fix correctness verification + forward regression guards. Wrapper correctness is established by code-reading (mirrors the cascade-exhausted catch already passing all baseline tests) plus the hardware evidence above. Follow-up: build a larger fixture (16 MiB+ via `mkntfs` in the Linux VM) to assert the strict baseline-fail shape — tracked in STATUS.md.

- **v0.5.2 (Bug B): atomic `$I30` insert ↔ MFT-record commit on `createFile` — closes the dangling-entry rollback hole that PR #29's hardware re-run exposed.** Post-error `verify --deep` on the 2026-05-27 hardware run reported `Dangling ($I30 entry but MFT slot free): 2` — two directory entries pointing at recnums whose IN_USE flag had been cleared. Math: `6216 reachable user files − (6220 in-use base − 6 extension) = 2 dangling`. Cause: `createFile`'s pre-fix discipline freed the orphan MFT slot on ANY post-commit throw, which left `$I30` dangling if the parent-side write had already happened. **Fix:** reorder `createFile` to compute-first / commit-MFT-first / commit-`$I30` / track-`i30Committed`. Mirror `migrateAttributeOnOverflow`'s discipline. Thread an `inout i30Committed: Bool` flag through `insertIntoParentI30` so each branch (resident `$INDEX_ROOT` rewrite, `LARGE_INDEX` leaf insert via `IndexAllocationWriter`, `LARGE_INDEX` promote + recursive call) sets the flag IMMEDIATELY before any parent-side write. On throw: if the flag is false, reclaim the MFT slot (clean rollback); if true, retain the MFT slot as an orphan-base record (recoverable via `ntfsctl reclaim-orphans` — strictly safer than dangling). The `(record absent, $I30 present)` dangling state is now structurally unreachable from any throw inside `createFile`. Only three terminal states remain: `(absent, absent)` clean rollback, `(present, absent)` orphan-base, `(present, present)` success. **Out-of-scope (explicitly):** `rename` / `delete` atomicity audits are deferred — `rename`'s signature was updated for compile-time compatibility (threads a discarded local) with an `AUDIT-TODO(rename-i30-atomicity)` comment marking the follow-up.

### Tests

- **5 new NTFSCore unit tests across two new files; 167 NTFSCore tests pass (was 159), 1 skip, 0 failures, CLI builds clean.**
  - `Packages/NTFSCore/Tests/NTFSCoreTests/CreateFileAtomicityTests.swift` (Bug B — 3 tests). `testFaultAfterI30CommitLeavesOrphanNotDangling` (the dangerous abort window: forces a throw AFTER `$I30` insert has hit disk; asserts the post-abort state has IN_USE=1 on the new MFT record so `$I30` is not dangling — using independent raw MFT-record byte decoders with USA fixup inlined, per AC-6 / PR #26 lesson; `Volume.enumerate` / `MFTRecord.parse` / `IndexRoot.parse` are NOT used to verify the shape under test). `testFaultBeforeI30CommitRollsBackCleanly` (the safe abort window: forces a throw BETWEEN the MFT write and `$I30` commit; asserts the post-abort state is fully clean — IN_USE=0 on the recnum AND `$I30` does not list the name). `testHappyPathCreateLeavesConsistentState` (no fault hook; the `#if DEBUG` seam must not affect non-test runtime).
  - `Packages/NTFSCore/Tests/NTFSCoreTests/LeafSplitMigrationCatchTests.swift` (Bug A — 2 forward guards). Two sustained-insert assertions that no Bug-A overflow shape escapes uncaught. The fixture-size caveat is documented in the test header.

### Notes

- **PR #29's "cap lifted" claim was incomplete.** This release fixes the two regression holes the 2026-05-27 hardware re-run exposed (Bug A leaf-split catch gap + Bug B `$I30`/MFT atomicity). After tagging v0.5.2 the user should: (1) truly reformat the drive (`mkntfs -Q` in Linux VM, or Windows quick format); (2) re-run the full-corpus `cp -rT --progress` on a freshly-formatted volume; (3) `verify --deep` — must report 0 dangling, 0 orphans, 0 leaked extensions, 0 unreachable. **That** is the clean baseline measurement of where the cap actually sits with both fixes in place. Anything less is chasing a moving target on a non-reformatted drive whose state carries over prior bugs.

## [Unreleased] — v0.5.1 candidate

### Fixed

- **v0.5: post-migration `$INDEX_ALLOCATION` leaf-split routing — lifts the hardware ~file-6,139 single-directory `cp -r` cap.** Once a directory's `$INDEX_ALLOCATION:$I30` migrated to an extension MFT record (the v0.5 Step 3 machinery), the LEAF-SPLIT rewrite path (`rewriteParentForLeafSplit` → `rewriteEntireAttribute`) still rewrote it in the BASE record's byte stream — but the base no longer holds it; the migrant lives in the extension. Confirmed against `main` @ 751cd9f via a controlled probe: the first post-migration leaf split throws `corruptOnDisk: rewriteEntireAttribute: target type 0x000000A0 name '$I30' not found` within ~16 inserts of migrating — the directory could not grow past migration at all. On the real 4 TB WD hardware (next-fit allocation kept the resident runlist compact) migration first fired around file 6,139 and immediately hit this wall; the `would overflow record … type 0xA0` in the hardware log is the migration TRIGGER, the fatal error is this "target not found". **Fix:** `rewriteParentForLeafSplit` is now `async` and extension-aware (`ParentRewrite { baseBytes, extensionWrites }`). When the base carries a `$ATTRIBUTE_LIST`, the rewrite locates `$INDEX_ALLOCATION:$I30` / `$BITMAP:$I30` via that list (new `rewriteMigratedAttributeInExtension` + `rewriteEntireAttributeWithHeaderUpdate`) and rewrites them in the EXTENSION record's bytes, returning those rewritten bytes for the caller. All split call sites thread `extraRecordWrites` through `ComputedSplit` and commit extension records BEFORE the base — matching `migrateAttributeOnOverflow`'s compute-first, extension-first transactional discipline. When `$INDEX_ALLOCATION` and `$BITMAP` share one extension record, both edits are applied to a single buffer and emitted as one write. Probe result: post-migration inserts go from **16** (main) to **2,092** (fixed) on `small.img` — a 130× lift, bounded only by the 4 MiB fixture's capacity, not by any structural index ceiling.

- **v0.5: cascade → root-overflow → height-grow corruption fix (`splitLeafAndPromote` `missing=36`).** While validating the routing fix above, a secondary corruption surfaced: the cascade → root-overflow → `heightGrowIndexRoot` path returned a `ComputedSplit` that DROPPED `grown.extraRecordWrites`. With the routing fix in place, `heightGrowIndexRoot` computes the grown `$INDEX_ALLOCATION` into its extension record's bytes and returns it — dropping that field committed a base `$INDEX_ROOT` pointing at fresh intermediate VCNs whose backing extension runlist write was never persisted, orphaning a whole INDX leaf's worth of entries (~36). The pre-existing `splitLeafAndPromote` consistency guard caught it as `post-split state mismatch — missing=36`. Fixed by threading `extraRecordWrites: grown.extraRecordWrites` through the cascade-height-grow return at `Volume.swift:2341`.

- **v0.5.1: `truncate` returns a clean `unsupportedFeature` (not a false `corruptOnDisk`) on a migrated file.** A "migrated" file — one whose unnamed `$DATA` was moved out of the base MFT record into an extension record, leaving an `$ATTRIBUTE_LIST` (type 0x20) on the base — was not recognized by `Volume.truncate(at:newSize:)`. The truncate paths read base-only `$DATA` and free its extents (which on a migrated file live in the extension record, so they'd be missed), and the lacks-`$DATA` guard would mis-report a healthy migrated file as `corruptOnDisk`. `truncate` now detects the `$ATTRIBUTE_LIST` on the base and throws `NTFSError.unsupportedFeature("truncate: MFT record N has $ATTRIBUTE_LIST (migrated $DATA in extension); truncating a migrated file is not yet supported")` for ALL `newSize` (including 0) — **before** freeing any clusters or writing anything, so the rejected truncate leaves volume state byte-identical. Truncating a migrated file remains deferred (fail-closed, never corruption); non-migrated files take the same byte-precise shrink path as before.

- **v0.5.1: FSKit reports the correct size for migrated files.** The FSKit extension's `makeFreshAttributes` previously read a file's `$DATA` size from the base MFT record only, so a migrated file (whose `$DATA` lives in an extension record via `$ATTRIBUTE_LIST`) would report a wrong/zero size to Finder. It now reads the size via `coreVolume.allAttributesOf(recordNumber:)`, which walks `$ATTRIBUTE_LIST` into the extension record and surfaces the migrated unnamed `$DATA` at its exact `realSize`.

### Changed

- **v0.5.1: file-attribute-path extension-awareness audit CLOSED.** With the `truncate` clean-error fix and the FSKit `makeFreshAttributes` size fix above, every file-attribute mutation/read path was confirmed migration-aware (`$ATTRIBUTE_LIST`-aware) or cleanly deferred. The remaining paths were confirmed already-correct / already-deferred: `rename` (operates on `$FILE_NAME` + the parent `$I30`, which stay resident in the base record — unaffected by `$DATA` migration), `write` and `writeFile` (a subsequent write to an already-migrated file fails closed with a clean error, never a partial mutation — tracked as a deferred follow-up), and `deleteFile` (already `$ATTRIBUTE_LIST`-aware as of v0.5 — frees extension records and their migrated clusters). No further file-attribute-path extension-awareness work is outstanding for v0.5.

### Tests

- **3 new NTFSCore unit tests in `Packages/NTFSCore/Tests/NTFSCoreTests/IndexAllocationGrowthTests.swift`; 159 NTFSCore tests pass (was 156), 1 skip, 0 failures.** Covers the post-migration `$INDEX_ALLOCATION` leaf-split routing fix above: `testPostMigrationGrowthLiftsCeilingAndIsAuditClean` (AC-1/AC-6 regression — forces migration, drives 1,500 post-migration inserts that exercise the cascade → height-grow path, asserts all enumerated, reopen-clean, orphan-free, `auditAllDataRunlistsAgainstBitmap` clean; would FAIL on `main` within ~16 inserts), `testPostMigrationGrowthLayoutIsSpecConformant` (AC-4 — hand-decodes the base `$ATTRIBUTE_LIST` body byte-by-byte with an independent reader, asserts canonical `(type, name, lowestVCN)` sort order, the migrant entry points at the extension with matching sequence, and the extension's rewritten `$INDEX_ALLOCATION` non-resident header + runlist are spec-clean — mirrors the PR #26 `MigratedDataSpecConformanceTests` independent-reader pattern), and `testPostMigrationGrowthToExhaustionLeavesNoLeak` (AC-6 transactional — drives growth to exhaustion, asserts the termination is a cluster/slot exhaustion (`outOfSpace` or `$MFT.$DATA` can't auto-grow) and never a structural index error, then asserts no orphan extension and audit clean post-reopen).

- **2 new NTFSCore unit tests; 145 NTFSCore tests pass (was 143), 1 skip, 0 failures.** In `Packages/NTFSCore/Tests/NTFSCoreTests/AttributeListMigrationTests.swift`: `testAllAttributesOfReturnsMigratedDataWithCorrectSize` (forces a `$DATA` migration with a known byte length, confirms the base record no longer holds the unnamed `$DATA`, and asserts `allAttributesOf` surfaces the migrated non-resident `$DATA` at exactly the bytes written — the indirect proof for the FSKit `size` read, which can't be swift-tested) and `testTruncateMigratedFileThrowsCleanUnsupported` (asserts `truncate` on a migrated file throws `unsupportedFeature` — never `corruptOnDisk` — for both a non-zero shrink and 0, and that no clusters were freed and the file still reads its original bytes via the migrated `$DATA`, proving the guard bails before mutating anything).

- **Independent spec-conformance regression tests for multi-extent and migrated `$DATA` (closes the PR #13 independent-cross-read gap for fragmented files).** Two new test files assert our serialized layouts against a hand-written, spec-strict decoder — NOT our own `DataRun.decode` round-trips, which could mask a defect:
  - `Packages/NTFSCore/Tests/NTFSCoreTests/MultiExtentDataTests.swift` — drives the REAL `encodeRunlist` / non-resident `$DATA` serializer across signed-width boundaries (incl. 5-byte deltas, large absolute LCNs, backward deltas), checks the header coverage fields (`lastVCN` / `allocatedSize` / `initializedSize`) match the runlist, and does an end-to-end independent physical-cluster read that reassembles the payload byte-exact. Includes `testMultiExtentDataAttributeIsSpecConformant`.
  - `Packages/NTFSCore/Tests/NTFSCoreTests/MigratedDataSpecConformanceTests.swift` — after forcing an organic `$DATA` migration, hand-decodes the base `$ATTRIBUTE_LIST`, the extension record header + `baseFileReference`, and the extension `$DATA` header + runlist per the on-disk spec, and reassembles the content byte-exact.

### Notes

- **Multi-extent `$DATA` portability blocker: suspected encoding root cause DISPROVEN; real cause remains OPEN.** A release-blocker report attributed the failure (spec-strict readers raising `Input/output error` on multi-extent `$DATA` files we wrote) to a multi-extent runlist / migration / fixup encoding bug. Independent spec-strict verification (the two test files above) disproved that premise: the runlist encoding, header coverage, physical placement, migration / `$ATTRIBUTE_LIST` linkage, `$MFT` growth (auto-grow disabled in v0.2), and USA/fixup are all spec-conformant. **No fix was made — there was no encoding bug to fix.** The real hardware I/O-error is not reproducible in the `.img`-fixture toolchain and remains OPEN pending hardware-side diagnostics (see `docs/STATUS.md` for the next-step hardware diagnostic plan and the proposed `ntfsctl verify` runlist-resolution follow-up).

## [Unreleased] — v0.5.0 candidate

### Added

- **v0.5: 64-bit cluster→byte-offset regression guard.** Centralized the cluster→device-byte-offset arithmetic in a named `UInt64` helper `Volume.deviceByteOffset(forLCN:) -> UInt64` and added a `>4 GB` regression test (`testClusterByteOffsetIs64BitAboveFourGiB`) ensuring no 32-bit wraparound above 4 GB (a cluster above LCN 1,048,576 on a 4096-byte-cluster volume yields a byte offset above 4 GiB that must stay 64-bit). No behavior change — purely a centralization + guard against regressing into the 32-bit blockmap bug class that afflicts macOS's `livefiles_ntfs` (see the Notes entry at the end of this section).

- **v0.5: `$ATTRIBUTE_LIST`-aware delete + `reclaim-orphans` of base-free leaked extensions — no more leaked extension records after `rm -r` of a migrated tree.** Two complementary halves close the loop opened by the Step 3/4 migration write paths (which create extension MFT records but, until now, had no symmetric teardown):
  - **Delete-path fix — `Volume.deleteFile(at:)` now frees `$ATTRIBUTE_LIST` extension records and their migrated clusters.** When a base record carries a `$ATTRIBUTE_LIST` (type 0x20), `deleteFile` walks it and, for each distinct extension record, frees that record's non-resident clusters AND its slot (IN_USE off, sequence bumped, `$MFT.$BITMAP` bit cleared) before freeing the base — so deleting a migrated file (or a directory whose `$INDEX_ALLOCATION` migrated) no longer leaves its extension records and migrated clusters leaked. Non-migrated files take the same fast path as before (no extra reads). Idempotent: a re-run, or a recycled/already-free extension slot, is a clean no-op (no double-free, sequence-number guarded).
  - **New `Volume.freeExtensionRecord(at:)`** — frees ONE extension record fully (non-resident clusters first, then the slot), idempotent, shared by `deleteFile` and the reclaim path.
  - **`reclaim-orphans --confirm` now reclaims confirmed-base-free leaked extension records (clusters + slot).** A leaked extension (one whose owning base isn't in the parsed in-use set) is reclaimable ONLY when its base record is AUTHORITATIVELY read off disk and confirmed IN_USE=0; everything else (base in use, base unparseable, base absent) defers to `chkdsk /f`. The split is computed by the new pure `MFTConsistency.splitLeakedExtensions(_:leakedExtensions:basesConfirmedFree:)` → `LeakedExtensionSplit { baseFreeExtensions, baseUnresolvedExtensions }`, default-deny so a live file's extension is never freed. So a volume already leaked by an older build is now cleanable with `ntfsctl` alone, no Linux/Windows machine required.
  - **8 new unit tests; 143 NTFSCore tests pass (was 135).** In `AttributeListMigrationTests.swift`: `testDeleteMigratedFileFreesExtensionRecordsAndClusters` (base + extension freed, free-cluster count restored to the pre-write baseline, zero leaked extensions on reopen), `testDeleteMigratedFileIsIdempotent`, `testFreeExtensionRecordFreesClustersAndSlotThenIdempotent`, and `testDeleteOneMigratedFileLeavesAnotherMigratedFileIntact` (XCTSkips on the 4 MiB fixture — two concurrent ~250-fragment migrations don't fit; the per-record guarantee is also covered by the classifier tests). In `MFTConsistencyTests.swift`: four `splitLeakedExtensions` cases (base confirmed free → reclaimable; base unconfirmed → deferred; base absent from records → deferred; mixed).

- **v0.5: resident `$BITMAP:$I30` growth — lifts the fixed 64-INDX-block-per-directory cap that aborted a hardware `cp -r` at file 1611.** A directory's resident `$BITMAP:$I30` attribute (type 0xB0, name `$I30`) was created with a fixed 8-byte body tracking only 64 `$INDEX_ALLOCATION` INDX blocks; allocating a 65th block threw `unsupportedFeature("updateBitmap: block index 64 exceeds bitmap capacity 64; growing $BITMAP not yet supported")`. On the real 22,419-file WD My Passport phone-backup `cp -r` this killed the copy at file 1611. The fix grows the resident bitmap in place:
  - **`Volume.updateBitmapAttribute(attrs:blockIndices:)`** now appends zero bytes when a requested block index falls beyond the current body, rounding the new length UP to a multiple of 8 bytes (NTFS index-bitmap alignment), then sets the bit. Growth is append-only zero-fill — never a rebuild, truncate, or reorder — so every previously-set bit survives. The growth is re-checked inside the multi-index loop so a later index in the same call can trigger a second growth.
  - **Parent-record-overflow stays fail-closed:** if the grown resident bitmap ever exceeded the base MFT record's slack, the existing rewrite path (`rewriteEntireAttribute`, routed through the 0xB0 attribute rewrite in `rewriteParentForLeafSplit`) detects the overflow and throws a clean `NTFSError.unsupportedFeature` while building its output into a fresh buffer — no partial write reaches disk. At the v0.5 8-byte growth increment this boundary is effectively unreachable.
  - **2 new unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/IndexBitmapGrowthTests.swift`: `testI30BitmapGrowsPast64Blocks` (drives root past 64 INDX blocks — reaching 65 — then reopens and asserts the bitmap body grew past 8 bytes, block-64's bit is set, all first-64 bits survive, every inserted name enumerates, and the full-MFT walk reports zero orphans) and `testI30BitmapGrowthIsEightByteAligned` (the grown body length is always a multiple of 8, live and on-disk).
  - **Follow-up NOT done yet:** very large directories needing more than a resident `$BITMAP:$I30` can hold (parent-record slack exhausted) require a non-resident `$BITMAP` / type-0xB0 base-record migration (analogous to the Step 3/4 `$INDEX_ALLOCATION` / `$DATA` migrations). Tracked in STATUS.md.
  - **Hardware validation (the file-1611 `cp -r` to the real WD My Passport) still pending** — user manual step.

- **v0.5 Fix B Step 4: unnamed `$DATA` (type 0x80) migration write path — lifts the per-file `$DATA`-overflow cap that aborted a hardware `cp -r` at file 350 ("would overflow record … type 0x80").** Generalizes Step 3's `$INDEX_ALLOCATION` (0xA0) migration so it ALSO handles a file's own non-resident unnamed `$DATA`: when the `$DATA` runlist would overflow the base MFT record's slack, the attribute is migrated to a freshly-allocated extension MFT record and a resident `$ATTRIBUTE_LIST` (type 0x20) is added to the base. `$STANDARD_INFORMATION` (0x10) and `$FILE_NAME` (0x30) stay resident in the base record (chkdsk requirement). Reads follow the `$ATTRIBUTE_LIST` to the extension and return content byte-identical. Complementary to the next-fit allocator below: the allocator reduces how often a `$DATA` runlist grows large enough to overflow; this handles the case when it overflows anyway (huge or genuinely fragmented file).
  - **Generalized shared builder, reused from Step 3 — no behavior change to the 0xA0 (`$INDEX_ALLOCATION`) path.** The migration helper introduced in Step 3 (`AttributeMigration` + `MFTRecord.buildExtensionRecord` + the compute-first transactional commit) is generalized to accept any overflowing attribute type rather than being `$INDEX_ALLOCATION`-specific; the existing 0xA0 directory-overflow path runs through the same generalized code unchanged. The discrimination guard now fires for both 0xA0 and 0x80 overflows.
  - **Same compute-first transactional commit:** full in-memory build of both records before any disk write; the extension record is written first, then the base. On any throw between MFT-slot allocation and the final base commit, `reclaimOrphanedMFTRecord` releases the extension slot (clears IN_USE + frees the `$MFT.$BITMAP` bit) so partial migrations never leak slots — failure is fail-closed, never corruption.
  - **chkdsk-clean on-disk shape:** base record carries the resident `$ATTRIBUTE_LIST` body (listing base + extension attributes, sorted per NTFS canon); the extension record carries the non-resident `$DATA` runlist with `baseFileReference` packed back at the base (`(UInt64(seq) << 48) | (recnum & 0x0000_FFFF_FFFF_FFFF)`) — same shape Step 3 produces for `$INDEX_ALLOCATION`.
  - **Deferred limitations (fail-closed, never corruption):** a SUBSEQUENT write to an already-migrated file, and a ranged `readFileSlice` of a migrated file, are not yet supported — both hit a clean error rather than a partial mutation. Full-file reads of migrated files are complete. Tracked alongside the Step 3 post-migration write-path follow-up in STATUS.md.
  - **New unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/`: end-to-end `$DATA`-overflow migration + byte-layout assertions, `$ATTRIBUTE_LIST`-aware full-file read round-trip on a migrated file, and a guard test asserting the deferred subsequent-write / ranged-read paths fail cleanly with no MFT slot leak.
  - **Hardware validation (the file-350 `cp -r` to the real WD My Passport) still pending** — user manual step.

- **v0.5: next-fit cluster allocator with rolling search hint — cuts `$DATA` runlist fragmentation on `cp -r`.** The cluster allocator previously did first-fit-from-cluster-0: every allocation linear-scanned `$Bitmap` from cluster 0 and grabbed the first scattered free holes. After an `rm -r` punched scattered holes near the start of the volume, every subsequent small-file write refilled those holes one cluster at a time — producing massively fragmented `$DATA` runlists. On the real 22,419-file WD My Passport phone-backup `cp -r`, a thumbnail at file ~350 produced a 696-byte `$DATA` attribute (~200 fragments) that overflowed its base MFT record. The fix is a next-fit allocator modeled on Windows NTFS's rolling allocation pointer / `fs/ntfs3`'s `data_zone` hint (rolling-hint subset only — no MFT-zone reservation):
  - **`Bitmap.findFreeRun(count:startingAt:)` now wraps around.** It scans `[startingAt, clusterCount)` first, then `[0, startingAt)`, returning the first run found across both passes. A free run never spans the wrap boundary (each pass has its own accumulator), and a stale hint `>= clusterCount` clamps to a full scan from 0. `startingAt == 0` is byte-for-byte the old single full scan, so first-fit callers are unaffected.
  - **`Bitmap.allocate(_:startingAt:)`** gains a `startingAt` parameter (default 0) forwarded to `findFreeRun`.
  - **`Volume._allocHint`** — a per-`Volume`, in-memory rolling pointer to the cluster immediately after the last one allocated. `allocateClusters` searches from `_allocHint` and advances it to `(startLCN + clusterCount) % clusterCount` after each success; `allocateClustersFragmented`'s greedy fallback advances it after every sub-run too. `freeClusters` deliberately does NOT rewind the hint (rewinding would send the next write back to refill just-freed holes, re-introducing fragmentation). `Volume` is an actor, so hint mutations are already serialized.
  - **Caveat — no on-disk persistence (v0.5):** `_allocHint` resets to 0 on each fresh `Volume` open (each `ntfsctl` invocation), but persists across all files within a single long-lived `cp -r` process — which is the workload that matters.
  - **7 new unit tests** in `Packages/NTFSCore/Tests/NTFSCoreTests/AllocatorTests.swift` cover contiguous sequential runs, wrap-around reaching free space below the hint, draining all free space with no stranding, fragmented allocation exhausting the volume, hint advancement, and hint wrap at end-of-volume. One existing `BitmapTests` assertion was updated to the new wrap-around contract.

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

### Changed

- **v0.5: `verify --deep` polish — skips zeroed/uninitialized `$MFT` tail slots; deep verdict now consistent with the audit's `isClean`.** The deep runlist↔`$Bitmap` sweep now skips zeroed/uninitialized MFT tail slots (records past the last in-use slot in `$MFT`'s allocated-but-uninitialized tail) rather than mis-parsing them, and the command's pass/fail verdict is now driven directly by the audit's `isClean` result so `verify --deep` and the underlying audit always agree.

### Notes

- **macOS `livefiles_ntfs` >4 GB read limitation — documented; FALSE ALARM, our writes are spec-correct.** A 22,419-file `cp -rT` to a real 4 TB WD My Passport copied 6,139 files cleanly, then macOS's native NTFS reader raised `Input/output error` on the *content* of late/fragmented files (e.g. `WhatsApp Documents/bn.pdf`). This was first feared to be a multi-extent `$DATA` portability blocker in OUR driver; it was conclusively diagnosed as a defect in macOS 15's new userspace `livefiles_ntfs` reader, which mishandles NTFS data at device byte-offsets above 4 GB (log signature `ntfs:cluster_read_ext: Error from blockmap operation: Input/output error (5)`). Failures correlate exactly with LCN > 1,048,576 (= 4 GiB ÷ 4096-byte cluster). Our on-disk data was proven correct three independent ways: (1) `ntfsctl dump bn.pdf` → single extent, LCN 1260225, in range, `$Bitmap` ALLOCATED, runlist spec-correct; (2) `ntfsctl cat bn.pdf | shasum` == source sha `45b9219026bb9b135c43fc213c9eabe16c0b9565`; (3) a no-driver raw `dd if=/dev/diskNs1 bs=512 skip=10081800 count=1056 | head -c 540566 | shasum` == the same source sha. **No fix was made — there is no defect in our writes.** `livefiles_ntfs` must not be used as the sole validator above 4 GB — use `ntfs-3g` / Windows `chkdsk`, or a raw `dd`+sha spot-check. See `docs/STATUS.md` (macOS `livefiles_ntfs` >4 GB read limitation) and the portability spot-check recipe in `docs/CLI.md`.

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
