# Changelog

All notable changes to ntfs-tool. Format roughly follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — v0.3.0 candidate

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
