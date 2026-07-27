# 04 — FSKit hard-link and rename callbacks

## Problem
The FSKit extension is code-complete for the main read/write path, but several item-management
callbacks still refuse with `EROFS`. Verified at
`Extensions/NTFSFileSystem/Sources/NTFSVolume.swift`:

- `createSymbolicLink` (declared :373) → `reply(nil, nil, posixError(EROFS))` at :380
- `createLink` (declared :383) → `reply(nil, posixError(EROFS))` at :389
- `renameItem` (declared :431)

Finder surfaces these as "operation not permitted" on a mounted volume even though the
equivalent operations already work through the CLI (`ntfsctl mv` landed in v0.7.2, including the
`$I30` insert-before-remove atomic rename and the case-only-rename data-loss guard).
`docs/STATUS.md` medium-impact follow-up #8 tracks this.

## Goal
Wire the FSKit rename and hard-link callbacks through to the NTFSCore operations that already
implement them, so Finder-initiated rename and hard-link work on a mounted volume.

## Scope
1. **`renameItem`.** Route to the existing NTFSCore rename path. Must preserve the guarantees
   the CLI already has and that are already covered by NTFSCore tests: insert-before-remove
   ordering so the source is never lost on a mid-operation abort, `$FILE_NAME` parent-reference
   update, and the case-only-rename / self-move guard.
2. **`createLink` (hard link).** Add a second `$FILE_NAME` attribute referencing the same base
   MFT record, insert the new `$I30` entry in the destination directory, and increment the
   record's hard-link count. Deleting one name must decrement rather than free the record while
   another name remains.
3. **Error mapping.** Failures must map to correct POSIX errno values, not a blanket `EROFS` —
   e.g. `EEXIST` for an occupied destination, `EXDEV` for a cross-volume attempt, `ENOENT` for a
   missing source. A silent success on a failed mutation is the failure mode to avoid.
4. **Read-only mounts still refuse.** When the volume is mounted read-only the callbacks must
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
- `renameItem` renames on a writable mount, preserving the insert-before-remove ordering; an
  aborted rename leaves the source intact (fault-injection test).
- A case-only rename does not destroy the source (the existing CLI guard is honoured via FSKit).
- `createLink` produces a second name for the same MFT record; both paths read identical
  content; deleting one leaves the other readable and the record allocated.
- Error cases return correct errnos: `EEXIST`, `EXDEV`, `ENOENT` — asserted individually.
- A read-only mount still returns `EROFS` from all three callbacks.
- `createSymbolicLink` still returns `EROFS`, with the reparse-point blocker documented in a
  comment at the refusal site.
- `verify --deep` is clean after a rename and after a hard-link create/delete cycle.
- The extension builds clean; existing tests pass.

## Outcomes Rubric
- Rename works via FSKit with source-preservation and case-only guards intact
- Hard links work, share content, and refcount correctly on delete
- Errno mapping is specific and individually asserted, never a blanket EROFS
- Read-only mounts still refuse; symlink refusal is documented, not silent
- `verify --deep` clean after both operations; extension builds clean
