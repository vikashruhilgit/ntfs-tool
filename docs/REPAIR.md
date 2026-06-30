# Write validation, Format & Repair — manual procedures

This document covers the parts of write-validation and format/repair that **cannot
run in a headless CI / sandboxed environment** because they require real hardware
(a USB stick), the live FSKit system extension, a Linux box (or Docker) running
`ntfs-3g`/`ntfsfix`, and/or a real Windows machine running `chkdsk /f`.

What IS automated in-repo (and runs in CI):

- `Packages/NTFSCore` — `MkntfsTests` formats an image and asserts
  `auditAllDataRunlistsAgainstBitmap().isClean` (the strongest local format
  oracle), plus `FormatEmitTests` materializes a formatted image for external
  oracles.
- `Packages/NTFSUIKit` — `FormatRepairLoaderTests` covers the GUI loader's
  format/repair state machine via injected providers.

What is documented here (manual / hardware):

1. The live write-through round-trip validated by Linux `ntfs-3g` + `ntfsfix`.
2. The Finder → eject → Windows `chkdsk /f` smoke procedure.
3. The Format and Repair actions on real volumes.

---

## 1. Live write-through round-trip (rubric item 1)

> **Status: PARTIAL in this repo.** The in-repo oracle (`MkntfsTests` +
> `FormatEmitTests` + `scripts/format-oracle.sh` + `scripts/ntfs-oracle.sh`)
> proves correctness against the real `ntfs-3g` driver on a disk image. The
> *live-extension* round-trip below additionally requires the FSKit extension
> mounted on real hardware and is performed by hand.

### 1a. Image-level oracle (Docker, no hardware)

Validates the formatter's on-disk product against the authoritative `ntfs-3g`:

```bash
scripts/format-oracle.sh 64      # emit a 64 MiB NTFS image, ntfsfix -n it
```

Validates the write-through (`cp`) path against `ntfs-3g`:

```bash
scripts/ntfs-oracle.sh           # format with real mkntfs, cp with ntfsctl, read back byte-exact
```

Both need Docker (for `ntfs-3g`). They do **not** run in a sandbox with no Docker.

### 1b. Live FSKit extension round-trip (real USB stick required)

1. Activate the extension (`systemextensionsctl developer on`, then approve in
   System Settings) and plug in a spare NTFS USB stick.
2. Mount it read-write through the menu-bar app.
3. In Finder, create a known tree (e.g. `cp -R ~/some-tree /Volumes/STICK/test`).
4. **Eject** from the app (flushes pending writes).
5. Move the stick to a Linux box (or `docker run -v` the raw device) and run:
   ```bash
   ntfsfix -n /dev/sdX1            # must mount + report clean
   ```
   then read the files back and diff against the source — contents and metadata
   (sizes, timestamps) must match.

A clean `ntfsfix -n` plus byte-exact read-back == the volume the live extension
wrote is correct.

---

## 2. Finder → eject → Windows `chkdsk /f` smoke (rubric item 2)

The end-user smoke test on a real Windows machine:

1. On the Mac, with the extension active and an NTFS USB stick mounted
   read-write, copy a handful of files into it via **Finder** (drag-drop or
   `cp`). Include a nested folder and a large (>100 MB) file.
2. Rename one file and delete another, in Finder.
3. **Eject** the volume from the menu-bar app (or Finder). Wait for it to
   disappear.
4. Plug the stick into a Windows PC. Open an elevated Command Prompt and run:
   ```
   chkdsk /f X:
   ```
   (replace `X:` with the stick's drive letter).
5. **Pass criterion:** `chkdsk` reports **zero errors** ("Windows has scanned
   the file system and found no problems") and does not fix or delete anything.
6. Open the files in Windows and confirm contents are intact.

---

## 3. Format & Repair on real volumes (rubric items 3, 4)

### Format as NTFS

In the volume dashboard's **Danger Zone**, **Format as NTFS…**:

1. The device must be **unmounted** (eject first).
2. The confirmation dialog names the device, e.g.
   *"Erase STICK (/dev/disk6s1)?"*. Confirm with the destructive button.
3. The app calls `NTFSCore.Volume.formatNTFS(device:deviceSizeBytes:label:…)`,
   then `synchronize()` + `releaseAdvisoryLock()`.
4. **Pass criterion:** the freshly formatted volume mounts read-write through the
   extension afterward, and `ntfsfix -n` / `chkdsk /f` report it clean (see §1a).

### Repair (honest)

In the **Danger Zone**, **Repair…**:

- The app opens the device, calls `Volume.isDirty()` and
  `Volume.auditAllDataRunlistsAgainstBitmap(maxRecords: 0)`.
- **Clean + not dirty** → reports "No problems found — volume is clean."
- **Dirty + clean audit** → clears the `$Volume` dirty flag via
  `setDirty(false)` and reports "Cleared the dirty flag."
- **Audit not clean** (free-but-referenced / out-of-range / double-allocated
  clusters, or unreadable records) → reports the problems and advises
  **Windows `chkdsk /F`**. The app does **not** modify the volume in this case.

> **There is no in-place corruption repair in NTFSCore.** "Repair" detects and
> can clear a dirty flag; it never claims to fix structural corruption. For real
> corruption, use Windows `chkdsk /F` (or `ntfsfix` on Linux for limited fixes).
