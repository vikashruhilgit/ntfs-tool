# 01 — `ntfsctl cp --resume`

## Problem
A multi-GB `cp -rT` onto NTFS over USB has no resume. If the copy aborts — flaky cable, power
loss, an `unsupportedFeature` throw — the only recovery is to restart from file zero. The
22,419-file / 39.60 GiB phone-backup corpus documented in `docs/STATUS.md` takes hours, so a
late failure costs the entire run. `docs/STATUS.md` high-impact follow-up #8 sizes this at ~1 day.

**Verified open (2026-07-27):** no `resume` symbol exists in
`Tools/ntfsctl/Sources/ntfsctl/Cp.swift`.

## Goal
`ntfsctl cp --resume` skips source files already present and intact at the destination, so an
interrupted copy can be re-run and completes only the remaining work.

## Scope
1. **`--resume` flag on `cp`.** Default match predicate: destination entry exists AND its size
   equals the source size. A name-only match is NOT sufficient (a truncated file from an aborted
   write would be wrongly skipped).
2. **Optional `--verify-checksum`.** Upgrades the predicate to SHA-256 of the destination content
   compared against the source. Slower; opt-in only. Must stream (reuse the existing streaming
   `cat` read path) rather than loading whole files.
3. **Interaction with the existing conflict policy.** `cp` already has `-n` (skip) and the
   `--move` / `DestinationPlan` machinery. `--resume` must compose predictably with them and the
   precedence must be documented in `docs/CLI.md`. Define and test the `--resume -n` combination
   explicitly rather than leaving it emergent.
4. **`--dry-run` support.** Report what would be skipped vs copied, with a resumed-count summary,
   without writing.
5. **Progress accounting.** The existing progress output must reflect skipped files so the
   totals still add up on a resumed run.

## Non-goals
- No partial-file resume (byte-offset continuation inside a single large file). Whole-file
  granularity only; a partially-written file is re-copied in full.
- No persistent manifest or state file — resumption is derived from the destination volume's
  actual contents, so there is nothing to become stale or corrupt.
- No change to default `cp` behavior when `--resume` is absent.

## Acceptance criteria
- `cp --resume` re-run over a completed copy performs zero writes and reports all files skipped.
- `cp --resume` after an aborted copy completes only the missing files; a `verify --deep` on the
  result is clean (0 orphans / 0 dangling / 0 double-allocated).
- A destination file with a matching name but a **different size** is re-copied, not skipped.
- `--verify-checksum` detects and re-copies a same-name, same-size but content-corrupted
  destination file.
- `--resume --dry-run` writes nothing and its predicted skip/copy split matches what the real
  run then does.
- The `--resume` × `-n` precedence is documented in `docs/CLI.md` and covered by a test.
- Existing `cp` tests still pass; no behavior change without the flag.

## Outcomes Rubric
- `--resume` skips intact files and copies missing ones, proven on an abort-then-resume fixture
- Size-mismatch and checksum-mismatch cases both re-copy rather than silently skip
- `--dry-run` prediction matches actual execution
- Flag interactions documented in `docs/CLI.md` and tested
- No regression in the existing `cp` / `mv` suites
