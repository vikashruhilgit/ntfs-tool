# 02 — Streaming `$Bitmap` reader

## Problem
`Bitmap` holds the entire volume cluster bitmap in memory: `Bitmap.swift:12` declares
`public var bytes: Data`, populated whole at open. `$Bitmap` is one bit per cluster, so an 8 TB
volume at 4 KiB clusters needs ~250 MB of resident RAM before a single file is read. This scales
linearly with volume size and is the main obstacle to operating on large drives.
`docs/STATUS.md` high-impact follow-up #9 sizes this at ~1-2 days and defers it to v0.4.

**Verified open (2026-07-27):** `Bitmap.swift:12` still stores the full `Data` blob.

## Goal
Load `$Bitmap` in bounded chunks on demand, so peak memory is independent of volume size, with
no change to allocation behavior or on-disk results.

## Scope
1. **Chunked backing store.** Replace the whole-blob `bytes` with a bounded chunk cache keyed by
   cluster range, reading through `$Bitmap`'s runlist. Cache size must be a named constant, not
   a magic literal.
2. **Preserve the existing dirty-range tracking.** `docs/STATUS.md` records that bitmap
   dirty-range tracking delivered a ~400-500× per-file speedup on USB. That optimization must
   survive: dirty ranges are flushed per chunk, and a chunk may not be evicted while dirty
   without being written back first.
3. **Update all consumers.** At minimum the allocator (`findFreeRun`, the next-fit
   `_allocHint` rolling hint, and `allocateIndexClusters(near:)`'s index-locality lane) and the
   audit path (`RunlistBitmapAudit`). Each call site must be reviewed for assumptions about
   random access to a fully-resident buffer — a wrap-around scan that was free over a `Data`
   blob becomes a chunk-thrash risk.
4. **No behavioral change.** Allocation decisions must be byte-identical to the current
   implementation for the same inputs. This is a memory-representation change only.
5. **Memory ceiling proven, not asserted.** A test must demonstrate bounded residency on a
   volume large enough that the whole-bitmap approach would exceed the cap.

## Non-goals
- No change to the on-disk `$Bitmap` format.
- No change to allocation *strategy* (next-fit, index-locality lane, chunk targeting) — only to
  how bitmap bytes are held in memory.
- No `$MFT.$BITMAP` streaming (a separate, smaller structure).

## Acceptance criteria
- Peak bitmap residency is bounded by the configured cache size regardless of volume size,
  demonstrated by a test that would fail under the whole-blob implementation.
- Allocation results are unchanged: an existing fixture copy produces an identical cluster
  layout before and after (compare allocated runlists, not just success).
- Dirty-range flushing still works — a chunk evicted while dirty is written back, proven by an
  eviction-under-pressure test; no free-but-referenced or double-allocated clusters appear in a
  `verify --deep` after a write-heavy run.
- The full existing NTFSCore suite passes with no reduction in count.
- No measurable regression on the per-file write path (the dirty-range speedup is retained).

## Outcomes Rubric
- Bitmap memory is bounded and proven by a test that fails pre-change
- Allocation output is byte-identical to the current implementation on a shared fixture
- Dirty-range writeback survives eviction, with a `verify --deep` clean result
- Every consumer call site reviewed and updated for chunked access
- Full existing suite green, per-file write performance not regressed
