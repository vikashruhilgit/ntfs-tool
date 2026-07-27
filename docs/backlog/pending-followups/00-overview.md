# 00 — Pending follow-ups: overview & sequencing

Derived from `docs/STATUS.md` §"What's pending — engineering follow-ups" on 2026-07-27,
**with every item verified against the actual source** before being written up here.

## Why this folder exists

`docs/STATUS.md` tracks pending work as a prose list with `~~strikethrough~~` for done items.
That list has **drifted from the code** — two items listed as pending are already implemented
(see §"Stale entries found" below). Requirements here are the verified-open subset, each sized
for a single PR.

## Verified-open items (this folder)

| # | Item | STATUS ref | Evidence it is open | Cross-subtask dep |
|---|------|-----------|---------------------|-------------------|
| 01 | `cp --resume` | high-impact #8 | No `resume` symbol in `Tools/ntfsctl/Sources/ntfsctl/Cp.swift` | moderate |
| 02 | Streaming `$Bitmap` reader | high-impact #9 | `Bitmap.swift:12` — `public var bytes: Data` holds the whole bitmap | **strong** |
| 03 | `ntfsctl tree` + `find` | low-impact #10, #11 | ✅ **DONE** (was: neither in the `subcommands:` list, `ntfsctl.swift:17`). Landed as one shared `NTFSCore.DirectoryWalker` + two thin consumers. | **strong** |
| 04 | FSKit `createLink` (hard link) | medium-impact #8 | `NTFSVolume.swift:389` returns `posixError(EROFS)`. NOTE: `renameItem` is NOT blocked — already implemented; see 04's correction note | low |
| 05 | `NTFSError` richer model | substantial #15 | Flat enum with string descriptions in `Errors.swift` | broad//refactor |

## Stale entries found — STATUS.md needs correcting

These are listed as **pending** in `docs/STATUS.md` but are **already implemented**. They are
deliberately NOT written up as requirements; the fix is a doc correction, not code.

1. **Medium-impact #7 — "`$UpCase`-aware filename collation"**, claimed to still use
   `localizedCaseInsensitiveCompare`. It does not: `IndexBuilder.swift:109-120` implements the
   NTFS `COLLATION_FILE_NAME` comparator via `$UpCase`, and the only surviving mention of
   `localizedCaseInsensitiveCompare` is a comment explaining the order is *not* that. STATUS.md's
   own header paragraph even describes this as the v0.7.3 root-cause fix — the follow-up list was
   never updated to match.
2. **Low-impact #9 — "Better `ntfsctl verify`… currently sweeps only records 0..63"**.
   `Verify.swift` walks the full MFT (`maxRecords` / `mftLogicalRecords`) and carries 17
   references to the `deep` audit mode, including orphan and `$Bitmap` mismatch detection.

**Action:** strike both in `docs/STATUS.md`. Tracked as a doc task, not a requirement here.

## Sequencing

- **03 first** if these are used as an evaluation corpus — it has the cleanest
  producer→consumer subtask shape (shared walker, two consumers).
- **02 before 05** — the streaming-bitmap change touches allocator and audit call sites, and
  landing the error-model refactor first would force a rebase of every one of them.
- **01 and 04 are independent** and can run in any order.

## Non-goals

- No changes to `docs/STATUS.md` prose from within these requirements (the stale-entry fix is a
  separate doc task, so it does not entangle with feature work).
- No `$LogFile` journal work (medium #5) or atomic-transaction work (#16) — both are
  multi-week and out of scope for single-PR requirements.
