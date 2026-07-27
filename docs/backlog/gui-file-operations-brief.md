# Backlog Brief — In-App File Operations (copy / cut / delete) for NTFSMountManager

> Source doc for `/automate`. Each `##` item below is one Queue entry — PR-sized, independently
> reviewable, ordered by dependency. Context the implementer needs is inline; do not assume
> conversation history.

## Background (read first, not a queue item)

- Repo: `ntfs-tool`. NTFSCore (`Packages/NTFSCore`) is a pure-Swift NTFS read/write engine with
  `Volume.createFile / deleteFile / write / rename / truncate / readFileSlice / enumerateDirectory`
  (all async, typed `NTFSError`, ~226 green tests).
- The menu-bar GUI (`Apps/NTFSMountManager/Sources`) is volume-level only: mount/eject, verify,
  repair, format, reveal-in-Finder, activity log (`ActivityLog.swift`, `ActivityView.swift`,
  `VolumeDashboardView.swift`, `MainWindowView.swift`). There is **no file browser and no per-file
  copy/cut/delete UI** — per-file ops are currently delegated to Finder
  (`FirstRunSheet.swift:30`).
- Goal: add a lightweight in-app file browser with copy / cut (move) / delete / rename, backed by
  NTFSCore directly. Primary use case: operating on **unmounted** NTFS volumes (raw device access);
  when a volume is mounted, file ops must route through the mount point (FileManager) instead of the
  raw device — never both.
- Reusable UI components live in `Packages/NTFSUIKit`. Follow existing conventions: SwiftUI,
  async/await, no `fatalError`, activity-log every destructive action, confirm-gate destructive
  actions (see `runFormatLogged` in `VolumeDashboardView.swift` for the pattern).
- Constraint: raw-device access requires the same privileges the Verify/Repair paths already use —
  reuse `DiskArbitrationService` / existing device-open plumbing, don't invent a new privilege path.
- Non-goals for this effort: symlinks/hardlinks, compressed/encrypted files, in-place file editing,
  Finder drag-and-drop integration, undo.

## 1. FileBrowserModel: read-only directory listing backed by NTFSCore

Add an observable model (`Apps/NTFSMountManager/Sources/FileBrowserModel.swift`, or in NTFSUIKit if
it stays UI-free) that, given a selected NTFS volume, opens it via NTFSCore (unmounted → raw device
read-only session) or via FileManager (mounted → mount point), and exposes:
directory entries (name, size, kind, modified date), current path, navigate-into-dir, navigate-up,
refresh. Typed errors surfaced as user-readable state, no crashes on dirty/odd volumes.
Acceptance: unit tests against the existing `.img` fixtures in
`Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/` list root and subdirectories correctly; mounted
path covered by a FileManager-backed test over a temp directory.

## 2. FileBrowserView: browsing UI wired into the dashboard

New `FileBrowserView.swift` presenting the model from item 1: column or list layout consistent with
the existing dashboard style (`VolumeDashboardView.swift`, NTFSUIKit components), breadcrumb or
back navigation, empty/error/loading states, entry point from the volume dashboard ("Browse
Files…" button) and sidebar. Read-only in this item — no mutations. Regenerate the xcodeproj for
new sources (see commit `b2968d8` for precedent).
Acceptance: app builds; browsing a fixture-backed or mounted volume shows correct entries;
selection state works.

## 3. Delete with confirm gate and activity logging

Context-menu (`.contextMenu`) and toolbar Delete on files and empty/non-empty directories.
Non-mounted path → `Volume.deleteFile` (recursive delete implemented in the model, bottom-up, with
progress for large trees); mounted path → `FileManager.trashItem`/`removeItem`. Confirm dialog
matching the Format pattern; every delete logged to `ActivityLog` with path and outcome; failures
surface the `NTFSError` message.
Acceptance: unit tests for recursive delete on a fixture image (entries gone, `verify` still
clean); UI shows confirm before any delete.

## 4. Copy out (NTFS → Mac) and copy in (Mac → NTFS)

Context-menu "Copy to…" (export via `NSSavePanel`/folder picker, reading through
`readFileSlice`-based streaming — drain autorelease pools at IO seams per the known
large-transfer OOM issue) and "Copy Here from…" (import via `NSOpenPanel`, `Volume.createFile` +
chunked `write`). Copy-in is only offered when the volume is writable (unmounted raw session with
write support, or mounted read-write). Progress reporting for multi-MB transfers; cancellation;
activity-logged.
Acceptance: round-trip test — import a file onto a fixture image, export it back, byte-identical;
`verify` clean afterwards.

## 5. Cut/paste (move) and rename

In-volume move via `Volume.rename` (cross-directory) with a cut → paste interaction and inline
rename (context menu + return key). Mounted path uses `FileManager.moveItem`. Name-collision
handling: prompt to replace or cancel; replace uses the delete-then-rename order the FSKit
extension already uses (`NTFSVolume.renameItem`). Activity-logged.
Acceptance: unit tests for cross-directory move and rename-over-existing on a fixture image with
post-op `verify` clean; UI cut state visually indicated and cleared on paste/escape.

## 6. Keyboard shortcuts, menu bar items, and FirstRunSheet copy update

⌘C/⌘X/⌘V/⌘⌫/return bound in the browser; matching entries under a "File Operations" section in the
app's Edit/context menus; update `FirstRunSheet.swift` wording so it no longer claims file
management is Finder-only. Ensure shortcuts don't leak outside the browser view's focus.
Acceptance: shortcuts act only when the browser has focus; sheet copy reflects the new capability.

## 7. Safety hardening pass on the write path from the GUI

Adversarial review of items 3–5: verify the raw-device write session is never opened while the same
volume is mounted (guard in the model + test), that a failed mid-operation write leaves the volume
`verify`-clean or dirty-flagged for Repair, and that all destructive paths are confirm-gated and
logged. Add integration tests under `Tests/Integration/` exercising delete/copy/move sequences on a
generated image followed by `ntfsctl verify`.
Acceptance: new integration tests green via `swift test`; no path allows raw writes to a mounted
volume.
