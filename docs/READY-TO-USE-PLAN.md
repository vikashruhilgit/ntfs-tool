# Plan: ntfs-tool → "ready-to-use" v0.2 (audit-aware)

Consolidated plan that folds in the [Red Team Audit](../AUDIT-REPORT.md) findings.

**Goal:** make the CLI safe + functional for the phone-backup workflow on a real
pre-existing Windows-formatted drive (your 4 TB WD), AND publishable as a release.

## Why this plan is different from my first draft

The audit identified that the *actual* blocker for your stated use case isn't
LARGE_INDEX leaf split — it's the **MFT scan cap (FATAL #2)**. Your WD drive
likely has > 2032 existing files, which means `ntfsctl cp` would fail on the
very first `createFile` with a misleading `outOfSpace` error. Leaf split is the
*second* blocker, only hit on directories the copy creates fresh.

Also: there are several < 2-hour safety fixes (dirty-bit, fsync, rm-/-guard,
recnum-flag, flock, verify-cap) that turn the CLI from "destructive on crash"
into "safe enough for daily use." These should all land before anything else
substantive, because each one prevents a real-world data-loss class.

## Tier ordering (revised after audit)

### Tier 0 — Safety + correctness fixes (all small, do in one session)

These are the audit's FATAL/CRITICAL/WARNING items that take < 2 hours each.
Together they convert the tool from "destructive when interrupted" to "safe."
I can do all of these in-session today.

| # | Audit | Fix | Effort | Risk if not fixed |
|---|---|---|---|---|
| T0.1 | FATAL #1 | `setDirty(true)` at start of every write command (Write, Cp, Rm, Mv, Create, Delete, Truncate) | 30 min | Crash-mid-write leaves volume inconsistent + Windows trusts it (no auto-chkdsk) |
| T0.2 | CRITICAL #4 | Add `BlockDevice.synchronize()` (fcntl F_FULLFSYNC) + call before each `setDirty(false)` | 30 min | Fast-unplug loses cached writes while dirty=0 lands on disk |
| T0.3 | CRITICAL #5 | `rm -r` rejects MFT recnums < 16 + the root path; require `--force` for recursive | 1 hour | One `/` typo = full-volume wipe |
| T0.4 | CRITICAL #7 | Require `--recnum` flag for record-number targeting; bare args = paths | 1 hour | A file named "38" silently targets record 38 instead |
| T0.5 | WEAKNESS #12 | `flock(LOCK_EX)` on writable device open | 30 min | Two concurrent `ntfsctl cp` processes corrupt the bitmap |
| T0.6 | WARNING #10 | `verify` default scans the full $MFT logical size (no 4096 cap) | 30 min | Large volumes silently false-pass verify |
| T0.7 | LICENSE | Add `LICENSE` file (Apache 2.0 unless you prefer otherwise) + update README footer | 15 min | Project legally unpublishable; can't fork or redistribute |

**Total Tier 0: ~5 hours.** I can ship this as one PR today.

### Tier 1 — The actual workflow blockers

| # | Audit | Item | Effort |
|---|---|---|---|
| T1.1 | FATAL #2 | **MFT $BITMAP-based allocator.** Replace `findFreeRecordNumber`'s linear 2048-record scan with a lookup into `$MFT`'s `$BITMAP` attribute. Adds genuine support for drives with millions of files. **This is the #1 blocker for your 4 TB drive.** | 1-2 days |
| T1.2 | FATAL #3 | **LARGE_INDEX leaf split.** Fix the disabled scaffold in `splitLeafAndPromote`. Approach: instrument-then-debug — `verifyParentRecord(_:)` re-reads + re-parses the parent record after every write, throws with detail on any mismatch. Stop-loss: if 12h doesn't yield a fix, ship T1.2-fallback. | 2-3 days |
| T1.2-fallback | (mine) | `cp -r` auto-chunks source on `leaf full`: when an insert into a fresh dest dir fails, auto-create `Camera-1/`, `Camera-2/` siblings. Ugly but unblocks the workflow. Land only if T1.2 stop-loss fires. | half day |
| T1.3 | CRITICAL #6 | **$FILE_NAME size refresh for LARGE_INDEX parents.** B-tree walk to find the leaf entry + rewrite. Shares code with T1.2; lands as a side-effect. | (covered by T1.2) |
| T1.4 | WARNING #8 | **mtime/atime updates.** Set `$STANDARD_INFORMATION.mtime` + `$FILE_NAME` mtime on every write; bump `atime` on read paths (or document opt-out — atime updates have perf cost). | 1 day |

**Total Tier 1: ~5 days of focused work.**

### Tier 2 — Release shipping

| # | Item | Effort | Who |
|---|---|---|---|
| T2.1 | GitHub Release with prebuilt `ntfsctl` binary in CI on tag push | half day | me + you push tag |
| T2.2 | README rewrite for first-time visitors (one-paragraph what-it-is, install block, docs links; remove "personal-use prototype" framing) | 1 hour | me |
| T2.3 | Homebrew tap formula (optional) | half day | me |

**Total Tier 2: ~1 day + 5 min for the tag push.**

### Tier 3 — Hardening (defer to v0.3)

| # | Audit | Item | Effort |
|---|---|---|---|
| T3.1 | WARNING #9 | Streaming bitmap reader (chunk-on-demand instead of loading 250 MB for 8 TB volumes) | 1-2 days |
| T3.2 | WARNING #11 | Pre-baked Docker image `ntfstool-test:latest` with `ntfs-3g` pre-installed | 1-2 hours |
| T3.3 | (mine) | `cp -r --resume` (skip files already present with size match) | 1 day |
| T3.4 | (mine) | Per-leaf free-space pre-check in `cp -r` (estimate inserts-per-leaf, warn) | half day |
| T3.5 | (mine) | Better error message hints across older subcommands (Info, SetDirty) | 2 hours |

### Tier 4 — Out of scope for v0.2 (explicit defers)

- `$LogFile` journaling — separate ~1-2 week effort.
- Daemon mode + setuid helper — security-sensitive design.
- Menu-bar app browse/copy — requires FSKit mount validation.
- Windows `chkdsk /f` validation — your manual test once T1.1+T1.2 land.

## Execution plan

### Session 1 (today, if you greenlight) — Tier 0

One PR / commit per logical group. Estimated 5 hours.

1. T0.7 — LICENSE file (5 min). You confirm Apache 2.0 vs MIT vs BSD-3.
2. T0.1 — `setDirty(true)` at start of every write command (30 min).
3. T0.2 — `BlockDevice.synchronize()` + fsync before final `setDirty(false)` (30 min).
4. T0.5 — `flock(LOCK_EX)` on `openingFileForUpdateAt` (30 min).
5. T0.3 — `rm -r` safety: refuse root + require `--force` for recursive (1 hour).
6. T0.4 — `--recnum` flag; bare args = paths (1 hour). **Behavior change** — any
   shell scripts you have that pass numbers as recnums will need updating.
7. T0.6 — `verify` default = full $MFT (30 min).
8. T2.2 — README rewrite (1 hour).
9. Tests + commit + push (15 min).

**Output:** safe-to-use CLI on the operations it currently supports, with a license.

### Session 2 — T1.1 (MFT $BITMAP allocator), 1-2 days

The $MFT record itself (record 0) has a `$BITMAP` attribute that tracks which
MFT slots are in use. It's the canonical NTFS way. Read it via existing
`Bitmap` class with cluster→bit mapping adapted to record-size units. Find
first free bit; mark allocated; persist.

Adds tests for: (a) allocator handles MFT slots > 2048, (b) freed slots are
reused, (c) the $BITMAP grows as needed (or document a cap).

### Session 3+ — T1.2 (leaf split), 2-3 days

Detailed sub-plan in the previous version (see git history of this file).
Briefly: instrument every parent-record write with a re-read-and-validate
check; isolate exactly which write produces the malformed bytes; fix it.

After T1.2 lands, T1.3 (size refresh for LARGE_INDEX parents) comes essentially
for free using the same descent code.

### Session 4 — T1.4 (mtime/atime), 1 day

Mostly mechanical: thread a "modification time" parameter through `writeFile` /
`write` / `truncate`; update `$STANDARD_INFORMATION` body before each MFT
rewrite; update the parent's $I30 entry's $FILE_NAME mtime in the same pass.

### Session 5 — T2.1 release (half day) + T3.x as time permits

GitHub Actions workflow: on tag push, build release `ntfsctl`, attach to a
release. README updated with `curl | tar` install. You push the v0.2.0 tag.

## What I need from you before starting

1. **License pick** (blocks T0.7): MIT / Apache 2.0 / BSD-3 / "your call".
   Recommendation: Apache 2.0 (patent grant matters because NTFS is Microsoft's territory).
2. **Greenlight for behavior change in T0.4** — the bare-argument-means-path
   change will break any scripts that pass numbers expecting recnum behavior.
   Your `scripts/copy-s21fe-to-mypassport.sh` doesn't use recnums (it uses
   paths), so it's fine. Custom scripts: you'll need `--recnum N` instead of `N`.
3. **Confirmation to start Session 1 now** (Tier 0, ~5 hours in-session).

## Top 3 hostile-expert questions the plan now answers

From the audit's "What Would Convince a Hostile Expert":

- *"Show me the `setDirty(true)` call before the first metadata write."* → T0.1.
- *"Copy 60 files into a fresh directory."* → T1.2 (with T1.2-fallback if needed).
- *"Run `ntfsctl create` on a drive with 3000+ files."* → T1.1.

When all three land, the verdict line in the audit ("Write: Not ready for general
use") flips to "Ready for general use on the documented v0.2 scope."

## Risk register

- **T1.1 ($BITMAP allocator)** could surface latent bugs in non-resident $BITMAP
  handling on volumes where $MFT's $DATA itself is heavily fragmented. Mitigation:
  add `verify` checks that walk $MFT's $BITMAP and cross-validate against the
  MFT IN_USE flags.
- **T1.2 (leaf split)** has a known-hard bug. Stop-loss + fallback documented above.
- **T0.4 (--recnum flag)** is a backward-incompatible CLI change. Mitigation: bump
  the version to 0.2.0 in `ntfsctl.swift`'s `CommandConfiguration`; document in
  CHANGELOG; emit a one-line deprecation hint if a bare numeric argument is
  passed (treat as path but warn for one release cycle).
- **T1.4 (mtime updates)** could create subtle issues if Windows expects very
  specific timestamp semantics for system files. Mitigation: only touch
  timestamps on user files (recnum >= 16), not system records.

That's the plan, audit-aware. Ready to start Session 1 once you confirm license
+ T0.4 behavior-change greenlight.
