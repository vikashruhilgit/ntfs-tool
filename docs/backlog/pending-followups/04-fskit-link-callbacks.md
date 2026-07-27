# 04 — FSKit hard-link callback (`createLink`)

## Problem
The FSKit extension is code-complete for the main read/write path, but the **hard-link** callback
still refuses with `EROFS`. Verified in `Extensions/NTFSFileSystem/Sources/NTFSVolume.swift`:

- `createLink` (declared :383) → `reply(nil, posixError(EROFS))` at :389 — **open**
- `createSymbolicLink` (declared :373) → `reply(nil, nil, posixError(EROFS))` at :380 — open, but
  a deliberate non-goal (see below)

Finder surfaces this as "operation not permitted" when hard-linking on a mounted volume.
`docs/STATUS.md` medium-impact follow-up #8 tracks it.

> **Correction (2026-07-27).** An earlier draft of this document also listed **`renameItem`** as
> `EROFS`-blocked and made "wire up rename" scope item 1. That was wrong, and the error is worth
> recording because it is the failure mode this repo keeps paying for: `renameItem` was listed
> from its declaration line (:431) without its body being read. It is in fact **fully
> implemented** — it validates with `EBADF` / `ENOTDIR` / `EINVAL` guards and proceeds to real
> rename logic, never returning `EROFS`. `docs/STATUS.md` follow-up #8 names all three callbacks
> together, so trusting that grouping instead of the source produced a requirement to build
> something that already exists. Caught by the PR #54 automated review.

## Goal
Wire the FSKit `createLink` callback through to NTFSCore so Finder-initiated hard-linking works
on a mounted volume, with correct errno mapping instead of a blanket `EROFS`.

## Scope
1. **`createLink` (hard link).** Add a second `$FILE_NAME` attribute referencing the same base
   MFT record, insert the new `$I30` entry in the destination directory, and increment the
   record's hard-link count. Deleting one name must decrement rather than free the record while
   another name remains.
2. **Error mapping.** Failures must map to correct POSIX errno values, not a blanket `EROFS` —
   e.g. `EEXIST` for an occupied destination, `EXDEV` for a cross-volume attempt, `ENOENT` for a
   missing source. A silent success on a failed mutation is the failure mode to avoid.
3. **Read-only mounts still refuse.** When the volume is mounted read-only the callbacks must
   still return `EROFS`; the change is for writable mounts only.

## Non-goals
- **`createSymbolicLink` stays `EROFS`.** NTFS symlinks require reparse-point support, which
  does not exist in NTFSCore and is a substantially larger piece of work. Out of scope here —
  but the refusal must be accompanied by a code comment naming reparse points as the blocker, so
  it is a recorded decision rather than an unexplained stub.
- No FSKit mount-UX validation on hardware (that is the separate, manual
  "only you can do" item in `docs/STATUS.md`).
- No new NTFSCore capability — this requirement wires up existing operations.

## Acceptance criteria
- `createLink` produces a second name for the same MFT record; both paths read identical
  content; deleting one leaves the other readable and the record allocated.
- Error cases return correct errnos: `EEXIST`, `EXDEV`, `ENOENT` — asserted individually.
- A read-only mount still returns `EROFS` from `createLink`.
- `createSymbolicLink` still returns `EROFS`, with the reparse-point blocker documented in a
  comment at the refusal site.
- `verify --deep` is clean after a hard-link create/delete cycle.
- The extension builds clean; existing tests pass.

## Outcomes Rubric
- Hard links work, share content, and refcount correctly on delete
- Errno mapping is specific and individually asserted, never a blanket EROFS
- Read-only mounts still refuse; symlink refusal is documented, not silent
- `verify --deep` clean after the hard-link cycle; extension builds clean
