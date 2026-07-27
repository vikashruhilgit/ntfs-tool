# 03 — `ntfsctl tree` and `ntfsctl find` (shared recursive walker)

## Problem
`ntfsctl` can list a single directory (`list`) but has no recursive traversal. Inspecting a
copied backup means running `list` by hand at every level, and there is no way to locate a file
by name across a volume. `docs/STATUS.md` low-impact follow-ups #10 and #11 request `tree` and a
recursive `find` respectively.

Both need the same thing — a recursive `$I30` walk with cycle safety and depth control — so
implementing them separately would duplicate it.

**Verified open (2026-07-27):** the `subcommands:` list at
`Tools/ntfsctl/Sources/ntfsctl/ntfsctl.swift:17` contains neither `tree` nor `find`.

## Goal
One shared recursive directory walker in NTFSCore, consumed by two new thin CLI subcommands:
`ntfsctl tree` (render) and `ntfsctl find` (match).

## Scope
1. **Shared walker (the producer).** A recursive `$I30` traversal in NTFSCore exposing an
   ordered, streaming sequence of `(path, entry, depth)`. Requirements:
   - **Cycle and revisit safety** — track visited MFT record numbers; a directory whose `$I30`
     references an ancestor must not loop forever.
   - **Depth bound** — caller-supplied max depth, honoured before descending.
   - **Streaming, not accumulating** — must not build the whole tree in memory, so it works on
     the 22,419-file corpus.
   - **Error containment** — an unreadable subdirectory yields a recorded error for that node
     and traversal continues, rather than aborting the entire walk.
2. **`ntfsctl tree` (consumer A).** Renders `/usr/bin/tree`-style output over the walker.
   Supports `--depth N`, and a trailing summary of directory and file counts.
3. **`ntfsctl find` (consumer B).** Matches entries by name pattern (glob) over the walker.
   Supports `--depth N` and `--type f|d`. Prints full paths.
4. **Both consumers must use the shared walker.** Neither may re-implement traversal. This is
   the load-bearing structural constraint of this requirement.

## Non-goals
- No content search (`grep`-like matching inside files) — name matching only.
- No `-exec`-style actions; `find` prints paths and nothing more.
- No changes to the existing `list` subcommand.
- No sorting/collation changes — the walker yields `$I30` order, which is already NTFS
  `COLLATION_FILE_NAME` order.

## Acceptance criteria
- A single walker implementation exists in NTFSCore and is the only traversal code; `tree` and
  `find` both call it (verifiable by inspection — no duplicated descent logic).
- `tree --depth N` output stops at depth N and its counts match an independent `list` walk of
  the same fixture.
- `find` locates a known deeply-nested file by glob and reports the correct full path; `--type`
  filters correctly.
- A directory cycle fixture terminates rather than hanging or exhausting memory.
- An unreadable subdirectory is reported as an error for that node while the rest of the walk
  still completes.
- Walking a large fixture does not accumulate the full tree in memory.
- Existing tests still pass; the two new subcommands appear in `ntfsctl --help` and in
  `docs/CLI.md`.

## Outcomes Rubric
- One shared walker, consumed by both commands, with no duplicated traversal logic
- `tree` renders correctly and honours `--depth`
- `find` matches by glob and `--type`, printing correct full paths
- Cycle safety, depth bounding, and per-node error containment all proven by tests
- Streaming behavior verified (no whole-tree accumulation)
