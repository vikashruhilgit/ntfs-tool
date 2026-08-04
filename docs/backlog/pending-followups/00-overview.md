# 00 — Pending follow-ups: overview & sequencing

Derived from `docs/STATUS.md` §"What's pending — engineering follow-ups" on 2026-07-27,
**with every item verified against the actual source** before being written up here.
Re-verified against the source on 2026-08-04 — see §"Status as of 2026-08-04".

## Why this folder exists

`docs/STATUS.md` tracks pending work as a prose list with `~~strikethrough~~` for done items.
That prose list is easy to drift from the code, so the requirements here are the verified-open
subset, each sized for a single PR, each carrying the grep/line evidence that it is open.

## Verified-open items (this folder)

| # | Item | STATUS ref | Evidence it is open (re-checked 2026-08-04) | Cross-subtask dep |
|---|------|-----------|---------------------|-------------------|
| 01 | `cp --resume` | high-impact #8 | No `resume` symbol in `Tools/ntfsctl/Sources/ntfsctl/Cp.swift` | moderate |
| 02 | Streaming `$Bitmap` reader | high-impact #9 | `Bitmap.swift:12` — `public var bytes: Data` holds the whole bitmap | **strong** |
| ~~03~~ | ~~`ntfsctl tree` + `find`~~ | low-impact #10, #11 | ✅ **Landed 2026-07-27** — both are in the `subcommands:` list (`ntfsctl.swift:22`); `Tree.swift` / `Find.swift` share `NTFSCore.DirectoryWalker`. Requirement 03 is kept for provenance only | — |
| 04 | FSKit `createLink` (hard link) | medium-impact #8 | `NTFSVolume.swift:383-390` returns `posixError(EROFS)`. NOTE: `renameItem` is NOT blocked — already implemented; see 04's correction note | low |
| 05 | `NTFSError` richer model | substantial #15 | Flat enum with string descriptions in `Errors.swift` — no severity / suggested-action fields | broad//refactor |

## Status as of 2026-08-04

The two stale `docs/STATUS.md` entries this file previously flagged have **been corrected in
STATUS.md** and need no further action:

1. **Medium-impact #7 — `$UpCase`-aware filename collation** is struck through as done (v0.7.3).
   `IndexBuilder.swift` implements the NTFS `COLLATION_FILE_NAME` comparator via `$UpCase`; the
   only surviving `localizedCaseInsensitiveCompare` mention is the comment at
   `IndexBuilder.swift:120` explaining the order is deliberately *not* that.
2. **Low-impact #9 — "Better `ntfsctl verify`"** is struck through as largely done. `Verify.swift`
   walks the full MFT (`maxRecords` / `mftLogicalRecords`); the "sweeps only records 0..63"
   description is gone.

Item 03 (`tree` + `find`) shipped on 2026-07-27 and is struck through in STATUS.md as well.
**Three requirements remain open: 01, 02, 05 — plus 04.**

## Sequencing

- **02 before 05** — the streaming-bitmap change touches allocator and audit call sites, and
  landing the error-model refactor first would force a rebase of every one of them.
- **01 and 04 are independent** and can run in any order. 01 has the highest user impact of the
  remaining set (multi-GB copies over flaky USB).

## Non-goals

- No changes to `docs/STATUS.md` prose from within these requirements (the stale-entry fix is a
  separate doc task, so it does not entangle with feature work).
- No `$LogFile` journal work (medium #5) or atomic-transaction work (#16) — both are
  multi-week and out of scope for single-PR requirements.
