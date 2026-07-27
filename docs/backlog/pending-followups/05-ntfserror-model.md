# 05 — Structured `NTFSError` model

## Problem
`NTFSError` is a flat enum whose cases carry free-form strings — e.g.
`corruptOnDisk("rewriteEntireAttribute: target type 0x000000A0 not found")`. Consequences visible
in the project's own history:

- **Callers cannot branch on meaning.** The v0.5 leaf-split fix had to catch overflow by calling
  an `isOverflowDescription` predicate that *pattern-matches the message string*. That is a
  parser over prose: rewording a message silently breaks a catch site, and `docs/STATUS.md`
  records that exactly this class of gap left two call sites uncaught.
- **Users get internal detail with no action.** `corruptOnDisk: rewriteEntireAttribute: target
  type 0x000000A0 not found` tells a user nothing about what to do. `docs/STATUS.md` low-impact
  follow-up #12 asks for actionable messages; substantial follow-up #15 asks for the model.

## Goal
Replace the string-described flat enum with a structured error carrying machine-readable
classification, so callers branch on data instead of prose and users get an actionable message.

## Scope
1. **Structured model.** Each error carries at minimum: a stable machine-readable `kind`, a
   `severity`, an optional `suggestedAction` (e.g. "run `chkdsk /f` on Windows"), and structured
   context (attribute type, record number, LCN) as typed fields rather than interpolated text.
2. **Eliminate string-matching control flow — the load-bearing item.** Every site that
   currently branches on message content, `isOverflowDescription` foremost, must branch on the
   structured `kind`. A repo-wide check must show no remaining control-flow dependency on error
   message text.
3. **Migrate all throw sites** to construct structured errors. Human-readable rendering moves to
   a description layer derived from the structure, so messages stay consistent by construction.
4. **Actionable user-facing rendering.** The CLI presents severity and suggested action; the
   internal detail remains available for diagnostics but must not be the whole of what a user
   sees.
5. **Preserve existing behavior.** Every currently-caught condition must still be caught. The
   migration is representational — no change to which operations succeed or fail.

## Non-goals
- No new error *conditions* — only restructuring how existing ones are represented.
- No localization.
- No changes to NTFS on-disk behavior or recovery semantics.
- No `$LogFile` / crash-recovery work (follow-ups #5 and #16), even though better errors would
  support it later.

## Acceptance criteria
- `NTFSError` carries structured `kind` / `severity` / `suggestedAction` / typed context.
- **No control flow anywhere depends on error message text** — `isOverflowDescription` and any
  equivalent are gone, replaced by `kind` checks; demonstrated by a repo-wide search in the PR.
- The migration-overflow catch paths still catch: the existing leaf-split and migration
  regression tests pass unchanged, including the cascade-exhausted and height-grow paths that
  `docs/STATUS.md` records as historically uncaught.
- A test asserts that **rewording a human-readable message does not change any catch
  behavior** — the specific regression this requirement exists to prevent.
- CLI output for a representative corruption error shows severity and a suggested action.
- The full NTFSCore + ntfsctl suites pass with no reduction in count; CLI release build is clean.

## Outcomes Rubric
- Structured error model with kind/severity/action/typed context replaces the flat enum
- Zero remaining string-matched control flow, proven by repo-wide search
- All historically-fragile catch sites still catch, proven by the existing regression suites
- A message-rewording test proves catch behavior is decoupled from prose
- User-facing errors are actionable; full suites green and release build clean
